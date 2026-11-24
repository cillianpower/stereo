import Foundation
import os
import StereoModel
import StereoStore

/// Keeps pinned albums, playlists and tracks downloaded for offline playback.
///
/// State lives in the store (`pin`, `pinTrack`, `download` tables), so it survives relaunches
/// and the UI can observe it directly. The manager runs at most `maxConcurrent` transfers,
/// retries failures with backoff, and deletes files no pin needs any more.
public actor DownloadManager {
    public struct Progress: Sendable, Equatable {
        public var trackID: ItemID
        public var state: DownloadState
        public var bytes: Int64
        public var totalBytes: Int64?
    }

    public nonisolated let directory: URL
    private let store: LibraryStore
    private let transport: DownloadTransport
    private let maxConcurrent: Int
    private let retryDelays: [Duration]
    private let log = Logger(subsystem: "app.stereo", category: "downloads")

    private var source: DownloadSource?
    private var active: [ItemID: Task<Void, Never>] = [:]
    private var retryTimer: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<Progress>.Continuation] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastProgressWrite: [ItemID: ContinuousClock.Instant] = [:]
    private var started = false

    /// - Parameters:
    ///   - directory: where finished files live (App Support/Stereo/Downloads). Excluded from backup.
    ///   - retryDelays: wait before each retry; a download fails for good after `retryDelays.count` retries.
    public init(
        source: DownloadSource?,
        store: LibraryStore,
        directory: URL,
        transport: DownloadTransport,
        maxConcurrent: Int = 3,
        retryDelays: [Duration] = [.seconds(5), .seconds(30), .seconds(120)]
    ) {
        self.source = source
        self.store = store
        self.directory = directory
        self.transport = transport
        self.maxConcurrent = maxConcurrent
        self.retryDelays = retryDelays
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    /// Re-queues transfers cut off by the last quit and starts the queue. Safe to call repeatedly.
    public func start() async {
        if !started {
            started = true
            if let urlTransport = transport as? URLSessionDownloadTransport {
                urlTransport.onOrphanCompletion = { [weak self] tag, result in
                    Task { await self?.adoptOrphan(tag: tag, result: result) }
                }
            }
            let stillRunning = await transport.activeTags()
            try? store.resetInterruptedDownloads(except: stillRunning)
        }
        kick()
    }

    /// Swap the library (reconnect, sign-out). nil pauses new transfers.
    public func setSource(_ source: DownloadSource?) {
        self.source = source
        if source != nil { kick() }
    }

    // MARK: Pinning

    public func pin(album id: ItemID, quality: StreamQuality) async throws {
        guard let source else { throw DownloadError.noSource }
        let detail = try await source.album(id)
        try? store.upsert(detail)   // keep the album browsable offline
        let pin = Pin(owner: .album(id), name: detail.album.name, subtitle: detail.album.artist,
                      coverArtID: detail.album.coverArtID, quality: DownloadQuality.key(quality))
        try save(pin, tracks: detail.tracks, quality: quality)
    }

    public func pin(playlist id: ItemID, quality: StreamQuality) async throws {
        guard let source else { throw DownloadError.noSource }
        let detail = try await source.playlist(id)
        let pin = Pin(owner: .playlist(id), name: detail.playlist.name, subtitle: "\(detail.tracks.count) songs",
                      coverArtID: detail.playlist.coverArtID, quality: DownloadQuality.key(quality))
        try save(pin, tracks: detail.tracks, quality: quality)
    }

    public func pin(track: Track, quality: StreamQuality) throws {
        let pin = Pin(owner: .track(track.id), name: track.title, subtitle: track.artist,
                      coverArtID: track.coverArtID, quality: DownloadQuality.key(quality))
        try save(pin, tracks: [track], quality: quality)
    }

    public func unpin(_ owner: PinOwner) throws {
        let orphans = try store.removePin(owner)
        discard(orphans)
        kick()
    }

    /// Re-reads every pinned album and playlist so tracks added on the server get downloaded
    /// and removed ones get deleted. Call after a library sync. Unreachable pins are skipped.
    public func refreshPins() async {
        guard let source, let pins = try? store.pins() else { return }
        for pin in pins {
            let quality = DownloadQuality.quality(fromKey: pin.quality)
            do {
                switch pin.owner {
                case .album(let id):
                    let detail = try await source.album(id)
                    try? store.upsert(detail)
                    var updated = pin
                    updated.name = detail.album.name
                    try save(updated, tracks: detail.tracks, quality: quality, kick: false)
                case .playlist(let id):
                    let detail = try await source.playlist(id)
                    var updated = pin
                    updated.name = detail.playlist.name
                    updated.subtitle = "\(detail.tracks.count) songs"
                    try save(updated, tracks: detail.tracks, quality: quality, kick: false)
                case .track:
                    continue
                }
            } catch {
                log.info("refresh skipped \(pin.name): \(error.localizedDescription)")
            }
        }
        kick()
    }

    private func save(_ pin: Pin, tracks: [Track], quality: StreamQuality, kick shouldKick: Bool = true) throws {
        let pinned = tracks.map { PinnedTrack(trackID: $0.id, relativePath: DownloadQuality.relativePath(for: $0, quality: quality)) }
        let orphans = try store.savePin(pin, tracks: pinned)
        discard(orphans)
        if shouldKick { kick() }
    }

    /// Cancels and deletes downloads no pin needs any more.
    private func discard(_ entries: [DownloadEntry]) {
        for entry in entries {
            active[entry.trackID]?.cancel()
            try? FileManager.default.removeItem(at: directory.appending(path: entry.relativePath))
            emit(Progress(trackID: entry.trackID, state: .queued, bytes: 0, totalBytes: nil))
        }
    }

    public func retryFailed() {
        try? store.retryFailedDownloads()
        kick()
    }

    /// Removes every pin and downloaded file.
    public func deleteAll() {
        for task in active.values { task.cancel() }
        active.removeAll()
        let paths = (try? store.deleteAllDownloads()) ?? []
        for path in paths { try? FileManager.default.removeItem(at: directory.appending(path: path)) }
        // Anything left over (partial moves, files from older builds).
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in leftovers { try? FileManager.default.removeItem(at: url) }
        notifyIdleIfNeeded()
    }

    // MARK: Lookup

    /// The finished download for a track, if there is one on disk.
    public nonisolated func localFile(for trackID: ItemID) -> URL? {
        guard let relative = try? store.completedDownloadPath(trackID) else { return nil }
        let url = directory.appending(path: relative)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    /// Plug into `LibraryTrackResolver(pinned:)`.
    public nonisolated var pinnedLookup: @Sendable (ItemID) async -> URL? {
        { [weak self] id in self?.localFile(for: id) }
    }

    /// Bytes of finished downloads.
    public nonisolated func totalBytes() -> Int64 {
        (try? store.downloadStats().bytes) ?? 0
    }

    // MARK: Progress

    /// Per-track progress events. Each call returns an independent stream.
    public func progressUpdates() -> AsyncStream<Progress> {
        let (stream, continuation) = AsyncStream.makeStream(of: Progress.self, bufferingPolicy: .bufferingNewest(100))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    private func emit(_ progress: Progress) {
        for continuation in subscribers.values { continuation.yield(progress) }
    }

    /// Returns once nothing is downloading or waiting to retry.
    public func waitUntilIdle() async {
        if isIdle { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private var isIdle: Bool {
        active.isEmpty && ((try? store.downloadEntries(state: .queued).isEmpty) ?? true)
    }

    private func notifyIdleIfNeeded() {
        guard isIdle, !idleWaiters.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for w in waiters { w.resume() }
    }

    // MARK: Queue

    private func kick() {
        if source != nil {
            while active.count < maxConcurrent,
                  let next = try? store.nextQueuedDownload(excluding: Set(active.keys)) {
                let id = next.trackID
                active[id] = Task { await self.run(next) }
            }
        }
        scheduleRetryTimer()
        notifyIdleIfNeeded()
    }

    private func scheduleRetryTimer() {
        retryTimer?.cancel()
        retryTimer = nil
        guard source != nil, let due = try? store.earliestRetry() else { return }
        let wait = max(0, due.timeIntervalSinceNow)
        retryTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait) + .milliseconds(5))
            guard !Task.isCancelled else { return }
            await self?.kick()
        }
    }

    private func run(_ entry: DownloadEntry) async {
        let id = entry.trackID
        defer {
            active[id] = nil
            lastProgressWrite[id] = nil
            kick()
        }
        guard let source else { return }
        try? store.updateDownload(id, .started)
        emit(Progress(trackID: id, state: .downloading, bytes: 0, totalBytes: nil))

        do {
            let quality = DownloadQuality.quality(fromKey: entry.quality)
            let request: URLRequest = switch quality {
            case .original: try await source.downloadRequest(for: id)
            case .transcoded: try await source.streamRequest(for: id, quality: quality, offset: nil)
            }
            let temp = try await transport.download(request, tag: id.description) { [weak self] bytes, total in
                Task { await self?.reportProgress(id, bytes: bytes, total: total) }
            }
            try Task.checkCancellation()
            try finish(entry, file: temp)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError {
                return   // unpinned or deleted mid-transfer; its row is already gone
            }
            fail(entry, error: error)
        }
    }

    private func finish(_ entry: DownloadEntry, file temp: URL) throws {
        let dest = directory.appending(path: entry.relativePath)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
        // Unpinned while the last bytes arrived: don't leave an untracked file behind.
        guard (try? store.downloadEntry(entry.trackID)) != nil else {
            try? FileManager.default.removeItem(at: dest)
            return
        }
        let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        try store.updateDownload(entry.trackID, .finished(bytes: size))
        emit(Progress(trackID: entry.trackID, state: .done, bytes: size, totalBytes: size))
    }

    private func fail(_ entry: DownloadEntry, error: Error) {
        let attempts = entry.attempts + 1
        let retryAfter: Date? = attempts <= retryDelays.count
            ? Date().addingTimeInterval(Self.seconds(retryDelays[attempts - 1]))
            : nil
        log.error("download \(entry.trackID) failed (attempt \(attempts)): \(error.localizedDescription)")
        try? store.updateDownload(entry.trackID, .failed(message: error.localizedDescription, attempts: attempts, retryAfter: retryAfter))
        emit(Progress(trackID: entry.trackID, state: retryAfter == nil ? .failed : .queued, bytes: 0, totalBytes: nil))
    }

    private func reportProgress(_ id: ItemID, bytes: Int64, total: Int64?) {
        guard active[id] != nil else { return }
        let now = ContinuousClock.now
        if let last = lastProgressWrite[id], now - last < .milliseconds(400) { return }
        lastProgressWrite[id] = now
        try? store.updateDownload(id, .progress(bytes: bytes, total: total))
        emit(Progress(trackID: id, state: .downloading, bytes: bytes, totalBytes: total))
    }

    /// A background transfer that finished while the app wasn't waiting for it.
    private func adoptOrphan(tag: String, result: Result<URL, Error>) {
        guard let id = ItemID(string: tag), let entry = try? store.downloadEntry(id), active[id] == nil else {
            if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
            return
        }
        switch result {
        case .success(let url):
            do { try finish(entry, file: url) } catch { fail(entry, error: error) }
        case .failure(let error):
            fail(entry, error: error)
        }
        kick()
    }

    static func seconds(_ d: Duration) -> TimeInterval {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
