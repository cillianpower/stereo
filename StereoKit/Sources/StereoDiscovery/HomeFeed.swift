import Foundation
import os
import StereoModel
import StereoStore

public struct HomeShelf: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case recentlyPlayed, forYou, weeklyJams, weeklyExploration, favoriteStations, rediscover, heavyRotation, newInLibrary
    }
    public enum Content: Hashable, Sendable {
        case albums([Album])
        case tracks([Track])
        case stations([Station])
    }

    public var kind: Kind
    public var title: String
    public var subtitle: String?
    public var content: Content
    public var id: String { kind.rawValue }

    public var isEmpty: Bool {
        switch content {
        case .albums(let a): a.isEmpty
        case .tracks(let t): t.isEmpty
        case .stations(let s): s.isEmpty
        }
    }
}

/// Builds the Home screen's shelves.
///
/// Local shelves come straight from the index and are always fresh. Server shelves (heavy rotation)
/// are cached for 30 minutes, and ListenBrainz shelves for 6 hours in memory and in the store, so
/// "For You" shows instantly on launch and offline.
public actor HomeFeed {
    public struct Config: Sendable {
        public var serverTTL: TimeInterval = 30 * 60
        public var listenBrainzTTL: TimeInterval = 6 * 3600
        public var shelfSize = 20
        public init() {}
    }

    private let store: LibraryStore
    private let library: LibrarySource?
    private var listenBrainz: ListenBrainzClient?
    private var listenBrainzUser: String?
    private let config: Config
    private let log = Logger(subsystem: "app.stereo", category: "home")
    private let now: @Sendable () -> Date

    private var heavyRotation: (Date, [Album])?
    private var lbShelves: (Date, [HomeShelf])?

    static let lbCacheKey = "discovery.forYou.v1"

    public init(store: LibraryStore, library: LibrarySource?, listenBrainz: ListenBrainzClient?, user: String?,
                config: Config = Config(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.library = library
        self.listenBrainz = listenBrainz
        self.listenBrainzUser = user
        self.config = config
        self.now = now
        if let cached = Self.loadCachedLB(store: store) { lbShelves = cached }
    }

    public func setListenBrainz(_ client: ListenBrainzClient?, user: String?) {
        listenBrainz = client
        listenBrainzUser = user
        lbShelves = nil
        try? store.setSyncValue(nil, for: Self.lbCacheKey)
    }

    /// Shelves in display order, empty ones dropped. `force` ignores caches (pull to refresh).
    public func shelves(force: Bool = false) async -> [HomeShelf] {
        let n = config.shelfSize
        var result: [HomeShelf] = []

        let recent = (try? store.albums(sortedBy: .recentlyPlayed, limit: n)) ?? []
        result.append(HomeShelf(kind: .recentlyPlayed, title: "Recently Played", content: .albums(recent)))

        result += await listenBrainzShelves(force: force)

        let stations = (try? store.favoriteStations()) ?? []
        result.append(HomeShelf(kind: .favoriteStations, title: "Your Stations", content: .stations(stations)))

        let rediscover = (try? store.rediscoverAlbums(limit: n)) ?? []
        result.append(HomeShelf(kind: .rediscover, title: "Rediscover", subtitle: "Favourites you haven't played in a while",
                                content: .albums(rediscover)))

        result.append(HomeShelf(kind: .heavyRotation, title: "Heavy Rotation", content: .albums(await heavyRotationAlbums(force: force))))

        let added = (try? store.albums(sortedBy: .recentlyAdded, limit: n)) ?? []
        result.append(HomeShelf(kind: .newInLibrary, title: "New in Your Library", content: .albums(added)))

        return result.filter { !$0.isEmpty }
    }

    private func heavyRotationAlbums(force: Bool) async -> [Album] {
        if !force, let (at, albums) = heavyRotation, now().timeIntervalSince(at) < config.serverTTL { return albums }
        guard let library, let page = try? await library.albums(.frequent, page: PageRequest(size: config.shelfSize)) else {
            return heavyRotation?.1 ?? []
        }
        heavyRotation = (now(), page.items)
        return page.items
    }

    // MARK: ListenBrainz

    private func listenBrainzShelves(force: Bool) async -> [HomeShelf] {
        guard let client = listenBrainz, let user = listenBrainzUser else { return [] }
        if !force, let (at, shelves) = lbShelves, now().timeIntervalSince(at) < config.listenBrainzTTL { return shelves }

        let matcher = LibraryMatcher(store: store)
        var shelves: [HomeShelf] = []
        var forYou: [Track] = []
        var failed = false

        // Weekly Jams / Exploration: the newest playlist of each kind, matched to the library.
        do {
            let playlists = try await client.createdForPlaylists(user: user)
            for kind in [LBPlaylistSummary.Kind.weeklyJams, .weeklyExploration] {
                guard let latest = playlists.filter({ $0.kind == kind }).max(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) })
                else { continue }
                let tracks = matcher.match(try await client.playlistRecordings(latest.id))
                let title = kind == .weeklyJams ? "Weekly Jams" : "Weekly Exploration"
                shelves.append(HomeShelf(kind: kind == .weeklyJams ? .weeklyJams : .weeklyExploration, title: title,
                                         subtitle: "From ListenBrainz, in your library", content: .tracks(tracks)))
            }
        } catch {
            failed = true
            log.error("createdfor failed: \(error.localizedDescription)")
        }

        // Collaborative-filtering recommendations → recordings → local tracks.
        do {
            let recs = try await client.recommendations(user: user, count: 200)
            let mbids = recs.map(\.recordingMBID)
            let direct = (try? store.tracks(musicBrainzIDs: mbids)) ?? [:]
            forYou = mbids.compactMap { direct[$0.lowercased()] }
            if forYou.count < config.shelfSize {
                // Fuzzy-match the rest by artist + title.
                let missing = mbids.filter { direct[$0.lowercased()] == nil }.prefix(100)
                let recordings = try await client.lookupRecordings(Array(missing))
                forYou += matcher.match(recordings).filter { t in !forYou.contains { $0.id == t.id } }
            }
        } catch {
            failed = true
            log.error("recommendations failed: \(error.localizedDescription)")
        }
        shelves.insert(HomeShelf(kind: .forYou, title: "For You", subtitle: "Recommended by ListenBrainz",
                                 content: .tracks(Array(forYou.prefix(config.shelfSize)))), at: 0)

        let nonEmpty = shelves.filter { !$0.isEmpty }
        // Cache real answers (including "nothing yet"); after a failure keep the old cache and retry next time.
        if !failed || !nonEmpty.isEmpty {
            lbShelves = (now(), nonEmpty)
            Self.saveCachedLB(nonEmpty, at: now(), store: store)
        }
        return nonEmpty.isEmpty ? (lbShelves?.1 ?? []) : nonEmpty
    }

    // MARK: Persistence (track IDs only; tracks re-read from the index)

    private struct CachedShelf: Codable { let kind: String; let title: String; let subtitle: String?; let trackIDs: [String] }
    private struct CachedFeed: Codable { let at: Date; let shelves: [CachedShelf] }

    private static func saveCachedLB(_ shelves: [HomeShelf], at: Date, store: LibraryStore) {
        let cached = shelves.compactMap { shelf -> CachedShelf? in
            guard case .tracks(let tracks) = shelf.content else { return nil }
            return CachedShelf(kind: shelf.kind.rawValue, title: shelf.title, subtitle: shelf.subtitle, trackIDs: tracks.map(\.id.description))
        }
        guard let data = try? JSONEncoder().encode(CachedFeed(at: at, shelves: cached)) else { return }
        try? store.setSyncValue(String(decoding: data, as: UTF8.self), for: lbCacheKey)
    }

    private static func loadCachedLB(store: LibraryStore) -> (Date, [HomeShelf])? {
        guard let raw = try? store.syncValue(lbCacheKey), let feed = try? JSONDecoder().decode(CachedFeed.self, from: Data(raw.utf8)) else { return nil }
        let shelves = feed.shelves.compactMap { c -> HomeShelf? in
            guard let kind = HomeShelf.Kind(rawValue: c.kind) else { return nil }
            let tracks = (try? store.tracks(ids: c.trackIDs.compactMap(ItemID.init(string:)))) ?? []
            return HomeShelf(kind: kind, title: c.title, subtitle: c.subtitle, content: .tracks(tracks))
        }
        return (feed.at, shelves.filter { !$0.isEmpty })
    }
}
