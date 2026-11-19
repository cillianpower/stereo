import CryptoKit
import Foundation
import TunerModel

/// Turns a track into a local file the engine can play.
public protocol TrackResolver: Sendable {
    func localFile(for track: Track) async throws -> URL
    /// Starts fetching in the background so a later `localFile` returns instantly.
    func prefetch(_ track: Track) async
}

/// LRU cache of audio files on disk. Files are touched on every use; the oldest go first.
public actor TrackCache {
    public let directory: URL
    public var limitBytes: Int64

    public init(directory: URL, limitBytes: Int64 = 5 * 1024 * 1024 * 1024) {
        self.directory = directory
        self.limitBytes = limitBytes
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    static func fileName(for key: String, ext: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(digest).\(ext)"
    }

    public func file(for key: String, ext: String) -> URL? {
        let url = directory.appending(path: Self.fileName(for: key, ext: ext))
        guard FileManager.default.fileExists(atPath: url.path()) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path())
        return url
    }

    /// Moves a finished download into the cache and evicts old files if over the limit.
    public func store(_ temporary: URL, key: String, ext: String) throws -> URL {
        let dest = directory.appending(path: Self.fileName(for: key, ext: ext))
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temporary, to: dest)
        evict(keeping: dest)
        return dest
    }

    public func totalBytes() -> Int64 {
        entries().reduce(0) { $0 + $1.size }
    }

    public func clear() {
        for entry in entries() { try? FileManager.default.removeItem(at: entry.url) }
    }

    private func entries() -> [(url: URL, size: Int64, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
        }
    }

    private func evict(keeping keep: URL) {
        var all = entries().sorted { $0.date < $1.date }
        var total = all.reduce(0) { $0 + $1.size }
        while total > limitBytes, let oldest = all.first {
            all.removeFirst()
            if oldest.url.standardizedFileURL == keep.standardizedFileURL { continue }
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
        }
    }
}

/// Resolution order: pinned download, then cache, then download from the library into the cache.
public actor LibraryTrackResolver: TrackResolver {
    public typealias QualityProvider = @Sendable () -> StreamQuality
    public typealias PinnedLookup = @Sendable (ItemID) async -> URL?

    private let library: LibrarySource
    private let cache: TrackCache
    private let session: URLSession
    private let quality: QualityProvider
    private let pinned: PinnedLookup
    private var inFlight: [String: Task<URL, Error>] = [:]

    public init(library: LibrarySource, cache: TrackCache, session: URLSession = .shared,
                quality: @escaping QualityProvider, pinned: @escaping PinnedLookup = { _ in nil }) {
        self.library = library
        self.cache = cache
        self.session = session
        self.quality = quality
        self.pinned = pinned
    }

    nonisolated static func cacheKey(track: Track, quality: StreamQuality) -> (key: String, ext: String) {
        switch quality {
        case .original:
            return ("\(track.id)|original", track.format.codec ?? "audio")
        case .transcoded(let format, let rate):
            // Navidrome sends AAC transcodes as raw ADTS, so the extension must say so.
            return ("\(track.id)|\(format)@\(rate)", format)
        }
    }

    public func localFile(for track: Track) async throws -> URL {
        if let url = await pinned(track.id) { return url }
        let q = quality()
        let (key, ext) = Self.cacheKey(track: track, quality: q)
        if let url = await cache.file(for: key, ext: ext) { return url }
        if let task = inFlight[key] { return try await task.value }

        let task = Task { [library, cache, session] () throws -> URL in
            let request = try await library.streamRequest(for: track.id, quality: q, offset: nil)
            let (tmp, response) = try await session.download(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            return try await cache.store(tmp, key: key, ext: ext)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    public func prefetch(_ track: Track) async {
        _ = try? await localFile(for: track)
    }
}
