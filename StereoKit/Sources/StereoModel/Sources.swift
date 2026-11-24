import Foundation

public struct LibraryCapabilities: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let syncedLyrics   = LibraryCapabilities(rawValue: 1 << 0)
    public static let similarSongs   = LibraryCapabilities(rawValue: 1 << 1)
    public static let playQueue      = LibraryCapabilities(rawValue: 1 << 2)
    public static let jukebox        = LibraryCapabilities(rawValue: 1 << 3)
    public static let transcoding    = LibraryCapabilities(rawValue: 1 << 4)
    public static let transcodeOffset = LibraryCapabilities(rawValue: 1 << 5)
    public static let apiKeyAuth     = LibraryCapabilities(rawValue: 1 << 6)
    public static let formPost       = LibraryCapabilities(rawValue: 1 << 7)
}

public enum AlbumListKind: String, Codable, Sendable, CaseIterable {
    case alphabeticalByName, alphabeticalByArtist, newest, recent, frequent, random, starred, highest
}

public struct PageRequest: Hashable, Sendable {
    public var offset: Int
    public var size: Int
    public init(offset: Int = 0, size: Int = 50) { self.offset = offset; self.size = size }
    public var next: PageRequest { .init(offset: offset + size, size: size) }
}

public struct Page<Element: Sendable>: Sendable {
    public var items: [Element]
    public var request: PageRequest
    public init(items: [Element], request: PageRequest) { self.items = items; self.request = request }
    /// A short page means there is nothing after it.
    public var hasMore: Bool { items.count >= request.size }
}

public enum StreamQuality: Hashable, Codable, Sendable {
    case original
    case transcoded(format: String, maxBitRate: Int)

    public static let defaultCellular = StreamQuality.transcoded(format: "aac", maxBitRate: 256)
}

public enum StarTarget: Hashable, Sendable {
    case track(ItemID), album(ItemID), artist(ItemID)
}

public enum PlaybackEvent: Sendable {
    case nowPlaying(ItemID)
    case played(ItemID, at: Date)
}

/// A music library such as a Navidrome server. Future: Jellyfin, local files.
public protocol LibrarySource: Sendable {
    var id: SourceID { get }
    func capabilities() async throws -> LibraryCapabilities
    func albums(_ list: AlbumListKind, page: PageRequest) async throws -> Page<Album>
    func album(_ id: ItemID) async throws -> AlbumDetail
    func artists() async throws -> [Artist]
    func artist(_ id: ItemID) async throws -> ArtistDetail
    func playlists() async throws -> [Playlist]
    func playlist(_ id: ItemID) async throws -> PlaylistDetail
    func search(_ query: String, limit: Int) async throws -> SearchResults
    func streamRequest(for track: ItemID, quality: StreamQuality, offset: Duration?) async throws -> URLRequest
    func coverArtURL(_ coverArtID: String, size: Int) async throws -> URL
    func lyrics(for track: Track) async throws -> Lyrics?
    func similar(to track: ItemID, count: Int) async throws -> [Track]
    func setStarred(_ starred: Bool, _ target: StarTarget) async throws
    func report(_ event: PlaybackEvent) async throws
    func savePlayQueue(_ tracks: [ItemID], current: ItemID?, position: Duration) async throws
    func loadPlayQueue() async throws -> SavedPlayQueue?
}

public struct SavedPlayQueue: Sendable {
    public var tracks: [Track]
    public var current: ItemID?
    public var position: Duration
    public var changed: Date?
    public var changedBy: String?
    public init(tracks: [Track], current: ItemID?, position: Duration, changed: Date?, changedBy: String?) {
        self.tracks = tracks; self.current = current; self.position = position; self.changed = changed; self.changedBy = changedBy
    }
}

public struct StationQuery: Hashable, Sendable {
    public enum Order: String, Sendable { case name, votes, clickcount, bitrate, random }

    public var name: String?
    public var tags: [String]
    public var countryCode: String?
    public var language: String?
    public var codec: String?
    public var bitrateMin: Int?
    public var bitrateMax: Int?
    public var order: Order?
    public var reverse: Bool
    public var limit: Int

    public init(name: String? = nil, tags: [String] = [], countryCode: String? = nil, language: String? = nil,
                codec: String? = nil, bitrateMin: Int? = nil, bitrateMax: Int? = nil,
                order: Order? = nil, reverse: Bool = false, limit: Int = 100) {
        self.name = name; self.tags = tags; self.countryCode = countryCode; self.language = language
        self.codec = codec; self.bitrateMin = bitrateMin; self.bitrateMax = bitrateMax
        self.order = order; self.reverse = reverse; self.limit = limit
    }
}

public protocol StationSource: Sendable {
    func search(_ query: StationQuery) async throws -> [Station]
}
