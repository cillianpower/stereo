import Foundation
import Observation
import os
import TunerModel

/// The app's single player: owns the queue and drives the gapless engine for library tracks and
/// most radio, with AVPlayer for HLS stations (or any station the engine can't decode).
/// UI, Now Playing and the remote module all observe this.
@MainActor
@Observable
public final class PlayerController {
    public enum Status: Equatable, Sendable { case idle, loading, playing, paused, buffering }

    // MARK: Observable state
    public private(set) var queue = PlayQueue()
    public private(set) var nowPlaying: PlayableItem?
    public private(set) var status: Status = .idle
    /// Seconds into the current track; updated about 4 times a second while playing.
    public private(set) var position: TimeInterval = 0
    public private(set) var streamTitle: StreamTitle?
    public private(set) var lastError: String?
    /// Library queue set aside while a station plays.
    public private(set) var parkedQueue: PlayQueue?

    public var replayGain = ReplayGainSettings() {
        didSet { /* applies from the next track */ }
    }
    public var volume: Float = 1 {
        didSet { engine.volume = volume; radio.volume = volume }
    }

    public var isPlaying: Bool { status == .playing || status == .buffering }
    public var duration: TimeInterval? {
        if case .track(let t) = nowPlaying, let d = t.duration { return Double(d.components.seconds) }
        return nil
    }

    // MARK: Dependencies
    @ObservationIgnored private let engine: PlaybackEngine
    /// The engine, when it can share its PCM (ShazamKit, visualisers).
    public var audioTap: AudioTapHost? { engine as? AudioTapHost }
    /// True while the current station plays through the engine rather than AVPlayer.
    @ObservationIgnored private var stationOnEngine = false
    @ObservationIgnored private let radio: RadioPlayer
    @ObservationIgnored public var resolver: TrackResolver?
    @ObservationIgnored public var library: LibrarySource?
    /// Called when a station starts, e.g. to record a click with Radio Browser.
    @ObservationIgnored public var onStationStarted: ((Station) -> Void)?
    /// Called when the library queue runs out. Return tracks to keep playing (auto-continue /
    /// smart shuffle), or an empty array to stop.
    @ObservationIgnored public var onQueueExhausted: ((PlayQueue) async -> [Track])?

    @ObservationIgnored private let log = Logger(subsystem: "app.tuner", category: "player")
    @ObservationIgnored private var playToken = 0
    @ObservationIgnored private var engineIDs: [String: Track] = [:]
    @ObservationIgnored private var scheduledNextID: String?
    @ObservationIgnored private var scrobbled = false
    @ObservationIgnored private var positionTask: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var pendingScrobbles: [(ItemID, Date)] = []
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?

    public init(engine: PlaybackEngine = AudioEnginePlayer(), radio: RadioPlayer = RadioPlayer()) {
        self.engine = engine
        self.radio = radio
        radio.onEvent = { [weak self] in self?.handleRadio($0) }
        let events = engine.events
        eventsTask = Task { [weak self] in
            for await event in events { self?.handleEngine(event) }
        }
    }

    // MARK: Library playback

    public func play(_ tracks: [Track], startAt index: Int = 0, from context: QueueContext? = nil, shuffled: Bool = false) {
        guard !tracks.isEmpty else { return }
        stopRadio(clearParked: true)
        queue.replace(with: tracks, startAt: index, source: context, shuffled: shuffled)
        startCurrent()
    }

    public func playNext(_ tracks: [Track]) {
        if nowPlaying == nil { play(tracks); return }
        queue.playNext(tracks)
        refreshNext()
    }

    public func addToQueue(_ tracks: [Track]) {
        if nowPlaying == nil { play(tracks); return }
        queue.addToQueue(tracks)
        refreshNext()
    }

    public func removeFromUpNext(at offsets: IndexSet) { queue.removeFromUpNext(at: offsets); refreshNext() }
    public func moveUpNext(from: IndexSet, to: Int) { queue.moveUpNext(from: from, to: to); refreshNext() }

    public func jump(to track: Track) {
        queue.jump(toContextTrack: track.id)
        startCurrent()
    }

    public func togglePlayPause() { isPlaying ? pause() : resume() }

    public func pause() {
        switch nowPlaying {
        case .station: stationOnEngine ? engine.pause() : radio.pause()
        case .track: engine.pause()
        case nil: return
        }
        status = .paused
    }

    public func resume() {
        switch nowPlaying {
        case .station: stationOnEngine ? engine.resume() : radio.resume()
        case .track: engine.resume()
        case nil:
            if let parked = parkedQueue { queue = parked; parkedQueue = nil; startCurrent() }
        }
    }

    public func next() {
        guard case .track = nowPlaying else { return }
        if queue.advance(userInitiated: true) != nil { startCurrent() } else { finish() }
    }

    /// Restarts the track if more than 3 s in, otherwise goes to the previous one.
    public func previous() {
        guard case .track = nowPlaying else { return }
        if position > 3 { seek(to: 0); return }
        queue.previous()
        startCurrent()
    }

    public func seek(to seconds: TimeInterval) {
        guard case .track = nowPlaying else { return }
        position = seconds
        engine.seek(to: seconds)
    }

    public func setShuffle(_ on: Bool) { queue.setShuffle(on); refreshNext() }

    public func setRepeat(_ mode: RepeatMode) {
        queue.repeatMode = mode
        refreshNext()
    }

    /// Loads a queue paused at an exact position and returns once the engine has the track —
    /// used as the target side of a handoff, so nothing is heard until `resume()`.
    public func prepare(_ tracks: [Track], startAt index: Int, position: TimeInterval, upNext: [Track] = [],
                        shuffled: Bool = false, repeatMode: RepeatMode = .off, context: QueueContext? = nil) async throws {
        stopRadio(clearParked: true)
        queue.replace(with: tracks, startAt: index, source: context, shuffled: shuffled)
        queue.repeatMode = repeatMode
        if !upNext.isEmpty { queue.addToQueue(upNext) }
        try await loadCurrent(at: position, autoplay: false)
    }

    public func cycleRepeat() {
        switch queue.repeatMode {
        case .off: queue.repeatMode = .all
        case .all: queue.repeatMode = .one
        case .one: queue.repeatMode = .off
        }
        refreshNext()
    }

    /// Restores a saved queue (e.g. "Continue from iPhone") without starting playback.
    public func restore(_ saved: SavedPlayQueue, autoplay: Bool) {
        let index = saved.current.flatMap { id in saved.tracks.firstIndex { $0.id == id } } ?? 0
        queue.replace(with: saved.tracks, startAt: index)
        let seconds = Double(saved.position.components.seconds) + Double(saved.position.components.attoseconds) / 1e18
        startCurrent(at: seconds, autoplay: autoplay)
    }

    // MARK: Radio

    public func play(_ station: Station) {
        if case .track = nowPlaying { parkedQueue = queue }
        radio.stop()
        playToken += 1
        nowPlaying = .station(station)
        streamTitle = nil
        position = 0
        status = .loading
        lastError = nil
        stopPositionUpdates()
        if station.isHLS {
            stationOnEngine = false
            engine.stop()
            radio.play(station)
        } else {
            stationOnEngine = true
            var request = URLRequest(url: station.streamURL)
            request.setValue("Tuner", forHTTPHeaderField: "User-Agent")
            engine.play(EngineItem(id: "station:\(station.id)#\(playToken)",
                                   source: .stream(StreamSpec(request: request, typeHint: station.codec, isLive: true))), at: 0)
        }
        onStationStarted?(station)
    }

    /// The engine couldn't decode this station (e.g. Ogg): let AVPlayer try.
    private func fallBackToAVPlayer(_ station: Station) {
        log.info("station falling back to AVPlayer: \(station.name)")
        stationOnEngine = false
        engine.stop()
        radio.play(station)
    }

    public func stop() {
        stopRadio(clearParked: false)
        engine.stop()
        nowPlaying = nil
        status = .idle
        stopPositionUpdates()
    }

    private func stopRadio(clearParked: Bool) {
        if case .station = nowPlaying {
            radio.stop()
            if stationOnEngine { engine.stop() }
            stationOnEngine = false
            streamTitle = nil
        }
        if clearParked { parkedQueue = nil }
    }

    // MARK: Internals

    private func startCurrent(at offset: TimeInterval = 0, autoplay: Bool = true) {
        Task {
            do {
                try await loadCurrent(at: offset, autoplay: autoplay)
            } catch is CancellationError {
                // superseded by a newer play request
            } catch {
                log.error("resolve failed: \(error.localizedDescription)")
                lastError = error.localizedDescription
                // Skip unplayable tracks rather than stopping the queue.
                if queue.advance(userInitiated: true) != nil { startCurrent() } else { finish() }
            }
        }
    }

    /// Resolves the current track and hands it to the engine (playing, or loaded paused).
    private func loadCurrent(at offset: TimeInterval, autoplay: Bool) async throws {
        guard let track = queue.current else { finish(); return }
        playToken += 1
        let token = playToken
        nowPlaying = .track(track)
        position = offset
        status = .loading
        scrobbled = false
        scheduledNextID = nil
        lastError = nil

        let item = try await engineItem(for: track)
        guard token == playToken else { throw CancellationError() }
        if autoplay {
            engine.play(item, at: offset)
        } else {
            engine.load(item, at: offset)
            status = .paused
        }
        startPositionUpdates()
        if autoplay { report(.nowPlaying(track.id)) }
        refreshNext()
        schedulePrefetch()
    }

    /// Resolves and hands the engine the next track so the transition is gapless.
    private func refreshNext() {
        guard case .track = nowPlaying else { return }
        let token = playToken
        guard let next = queue.peekNext else {
            engine.setNext(nil)
            return
        }
        Task {
            guard let item = try? await engineItem(for: next), token == playToken else { return }
            scheduledNextID = item.id
            engine.setNext(item)
        }
    }

    @ObservationIgnored private var engineSerial = 0

    private func engineItem(for track: Track) async throws -> EngineItem {
        guard let resolver else { throw URLError(.resourceUnavailable) }
        let source = try await resolver.playbackSource(for: track)
        let albumContext: Bool
        if case .album(let id, _) = queue.contextSource, !queue.isShuffled, track.albumID == id { albumContext = true }
        else { albumContext = false }
        let gain = GainCalculator.linearGain(for: track.replayGain, settings: replayGain, albumContext: albumContext)
        // Unique per play, so repeat-one and duplicate tracks still produce distinct segments.
        engineSerial += 1
        let id = "\(track.id)#\(engineSerial)"
        engineIDs[id] = track
        return EngineItem(id: id, source: source, gain: gain)
    }

    private func handleEngine(_ event: EngineEvent) {
        switch nowPlaying {
        case .station(let station) where stationOnEngine:
            switch event {
            case .started, .playingChanged(true), .buffering(false): status = .playing
            case .buffering(true): status = .buffering
            case .playingChanged(false): if status != .loading { status = .paused }
            case .streamMetadata(_, let title): streamTitle = StreamTitle(raw: title)
            case .failed(let id, _):
                guard id.hasSuffix("#\(playToken)") else { return }
                fallBackToAVPlayer(station)
            case .ended:
                // A live stream ending means the connection dropped: reconnect once.
                play(station)
            case .advanced:
                break
            }
        case .track:
            switch event {
            case .started:
                status = .playing
            case .advanced(let id):
                // Gapless transition: move the queue to match what is now audible.
                guard let track = engineIDs[id] else { return }
                if queue.peekNext?.id == track.id { queue.advance() }
                nowPlaying = .track(track)
                position = 0
                scrobbled = false
                report(.nowPlaying(track.id))
                engineIDs = engineIDs.filter { $0.key == id }
                refreshNext()
                schedulePrefetch()
            case .ended:
                if queue.advance() != nil { startCurrent() } else { finish() }
            case .failed(_, let message):
                lastError = message
            case .playingChanged(let playing):
                if playing { status = .playing } else if status != .loading, nowPlaying != nil { status = .paused }
            case .buffering(let buffering):
                if buffering { status = .buffering } else if status == .buffering { status = .playing }
            case .streamMetadata:
                break
            }
        default:
            break
        }
    }

    /// Fetches the next track into the cache a little after the current one starts, so the
    /// gapless hand-off reads a local file even on slow networks.
    private func schedulePrefetch() {
        prefetchTask?.cancel()
        guard let next = queue.peekNext, let resolver else { return }
        prefetchTask = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await resolver.prefetch(next)
        }
    }

    private func handleRadio(_ event: RadioPlayer.Event) {
        guard case .station = nowPlaying else { return }
        switch event {
        case .playing: status = .playing
        case .buffering: status = .buffering
        case .paused: if status != .loading { status = .paused }
        case .title(let raw): streamTitle = StreamTitle(raw: raw)
        case .failed(let message): lastError = message; status = .idle
        }
    }

    private func finish() {
        if let hook = onQueueExhausted, let last = queue.context.last {
            let snapshot = queue
            let token = playToken
            Task {
                let more = await hook(snapshot).filter { $0.id != last.id }
                guard token == playToken, !more.isEmpty else { stopAtEnd(); return }
                queue.replace(with: more, startAt: 0, source: snapshot.contextSource)
                startCurrent()
            }
            return
        }
        stopAtEnd()
    }

    private func stopAtEnd() {
        engine.stop()
        status = .idle
        position = 0
        stopPositionUpdates()
    }

    // MARK: Position + scrobbling

    private func startPositionUpdates() {
        guard positionTask == nil else { return }
        positionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.updatePosition()
            }
        }
    }

    private func stopPositionUpdates() {
        positionTask?.cancel()
        positionTask = nil
    }

    private func updatePosition() {
        guard case .track(let track) = nowPlaying, status == .playing else { return }
        position = engine.currentTime
        // A play counts after half the track or 4 minutes, whichever comes first.
        if !scrobbled, let d = duration, d > 30, position >= min(d / 2, 240) {
            scrobbled = true
            report(.played(track.id, at: Date()))
        }
    }

    private func report(_ event: PlaybackEvent) {
        guard let library else { return }
        Task {
            do {
                try await library.report(event)
                await flushPendingScrobbles()
            } catch {
                if case .played(let id, let date) = event { pendingScrobbles.append((id, date)) }
            }
        }
    }

    /// Sends scrobbles that failed while offline, with their original timestamps.
    public func flushPendingScrobbles() async {
        guard let library, !pendingScrobbles.isEmpty else { return }
        let pending = pendingScrobbles
        pendingScrobbles = []
        for (id, date) in pending {
            do { try await library.report(.played(id, at: date)) }
            catch { pendingScrobbles.append((id, date)) }
        }
    }
}
