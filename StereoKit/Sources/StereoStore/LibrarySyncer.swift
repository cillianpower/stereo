import Foundation
import os
import StereoModel

/// Mirrors a `LibrarySource` into the local store.
///
/// - Full sync: walk every album (500 per page), fetch details 8 at a time, then delete anything not seen.
/// - Delta sync: newest + recently played lists, refetching only albums that are new or changed.
public actor LibrarySyncer {
    public struct Progress: Sendable, Equatable {
        public var albumsDone: Int
        public var albumsTotal: Int?
        public var phase: String
    }

    private let source: LibrarySource
    private let store: LibraryStore
    private let log = Logger(subsystem: "app.stereo", category: "sync")
    private var running: Task<Void, Error>?

    public static let fullSyncInterval: TimeInterval = 7 * 86_400
    private let pageSize = 500
    private let concurrency = 8

    public init(source: LibrarySource, store: LibraryStore) {
        self.source = source
        self.store = store
    }

    private var lastFullKey: String { "lastFullSync:\(source.id)" }

    public func needsFullSync() -> Bool {
        guard let raw = try? store.syncValue(lastFullKey), let t = Double(raw) else { return true }
        return Date().timeIntervalSince1970 - t > Self.fullSyncInterval
    }

    /// Runs a full sync if one is due, otherwise a delta. Concurrent calls join the running sync.
    public func sync(force full: Bool = false, progress: (@Sendable (Progress) -> Void)? = nil) async throws {
        if let running { return try await running.value }
        let doFull = full || needsFullSync()
        let task = Task { doFull ? try await fullSync(progress: progress) : try await deltaSync(progress: progress) }
        running = task
        defer { running = nil }
        try await task.value
    }

    func fullSync(progress: (@Sendable (Progress) -> Void)?) async throws {
        let started = Date()
        log.info("full sync started")
        progress?(Progress(albumsDone: 0, albumsTotal: nil, phase: "Artists"))
        try store.replaceArtists(try await source.artists())
        try store.replacePlaylists(try await source.playlists())

        var page = PageRequest(offset: 0, size: pageSize)
        var allAlbums: [Album] = []
        while true {
            let result = try await source.albums(.alphabeticalByName, page: page)
            allAlbums += result.items
            // Index the album list immediately so browsing works before details finish.
            try store.upsert(albums: result.items, syncedAt: started)
            progress?(Progress(albumsDone: 0, albumsTotal: nil, phase: "Albums (\(allAlbums.count))"))
            guard result.hasMore else { break }
            page = page.next
        }

        try await fetchDetails(for: allAlbums, syncedAt: started, progress: progress)
        let removed = try store.removeAlbums(syncedBefore: started)
        try store.setSyncValue(String(Date().timeIntervalSince1970), for: lastFullKey)
        log.info("full sync done: \(allAlbums.count) albums, \(removed) removed")
    }

    func deltaSync(progress: (@Sendable (Progress) -> Void)?) async throws {
        let now = Date()
        // New albums: walk "newest" until we hit albums we already have.
        var changed: [Album] = []
        var page = PageRequest(offset: 0, size: 100)
        let known = Set(try store.albums().map(\.id))
        while true {
            let result = try await source.albums(.newest, page: page)
            let fresh = result.items.filter { !known.contains($0.id) }
            changed += fresh
            if fresh.count < result.items.count || !result.hasMore { break }
            page = page.next
        }
        // Recently played albums carry updated play counts and last-played dates.
        let recent = try await source.albums(.recent, page: PageRequest(offset: 0, size: 100)).items
        try store.upsert(albums: recent, syncedAt: now)
        try store.upsert(albums: changed, syncedAt: now)
        try store.replacePlaylists(try await source.playlists())
        if !changed.isEmpty {
            try store.replaceArtists(try await source.artists())
            try await fetchDetails(for: changed, syncedAt: now, progress: progress)
        }
        log.info("delta sync: \(changed.count) new albums")
    }

    private func fetchDetails(for albums: [Album], syncedAt: Date, progress: (@Sendable (Progress) -> Void)?) async throws {
        let total = albums.count
        var done = 0
        var iterator = albums.makeIterator()
        try await withThrowingTaskGroup(of: AlbumDetail?.self) { group in
            let source = self.source
            func addNext() -> Bool {
                guard let album = iterator.next() else { return false }
                group.addTask { try? await source.album(album.id) }
                return true
            }
            for _ in 0..<concurrency { if !addNext() { break } }
            while let detail = try await group.next() {
                if let detail { try store.upsert(detail, syncedAt: syncedAt) }
                done += 1
                if done % 25 == 0 || done == total {
                    progress?(Progress(albumsDone: done, albumsTotal: total, phase: "Tracks"))
                }
                _ = addNext()
            }
        }
    }
}
