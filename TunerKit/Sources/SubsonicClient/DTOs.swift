import Foundation

// Wire types for the OpenSubsonic JSON API. Everything optional is genuinely optional across servers.

struct Envelope<Body: Decodable>: Decodable {
    let response: Body

    enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}

struct ResponseStatus: Decodable {
    struct ErrorBody: Decodable { let code: Int; let message: String? }
    let status: String
    let version: String?
    let type: String?
    let serverVersion: String?
    let openSubsonic: Bool?
    let error: ErrorBody?
}

struct ReplayGainDTO: Decodable {
    let trackGain: Double?
    let albumGain: Double?
    let trackPeak: Double?
    let albumPeak: Double?
    let baseGain: Double?
}

struct SongDTO: Decodable {
    let id: String
    let title: String
    let album: String?
    let albumId: String?
    let artist: String?
    let artistId: String?
    let track: Int?
    let discNumber: Int?
    let year: Int?
    let genre: String?
    let coverArt: String?
    let suffix: String?
    let contentType: String?
    let duration: Int?
    let bitRate: Int?
    let samplingRate: Int?
    let bitDepth: Int?
    let channelCount: Int?
    let starred: Date?
    let userRating: Int?
    let playCount: Int?
    let musicBrainzId: String?
    let replayGain: ReplayGainDTO?
}

struct AlbumDTO: Decodable {
    let id: String
    let name: String?
    let title: String?       // some servers use `title` in album lists
    let artist: String?
    let artistId: String?
    let year: Int?
    let genre: String?
    let songCount: Int?
    let duration: Int?
    let coverArt: String?
    let created: Date?
    let starred: Date?
    let playCount: Int?
    let played: Date?
    let song: [SongDTO]?
}

struct ArtistDTO: Decodable {
    let id: String
    let name: String
    let albumCount: Int?
    let coverArt: String?
    let starred: Date?
    let album: [AlbumDTO]?
}

struct PlaylistDTO: Decodable {
    let id: String
    let name: String
    let comment: String?
    let songCount: Int?
    let duration: Int?
    let coverArt: String?
    let changed: Date?
    let entry: [SongDTO]?
}

struct ExtensionDTO: Decodable {
    let name: String
    let versions: [Int]
}

struct StructuredLyricsDTO: Decodable {
    struct Line: Decodable { let start: Int?; let value: String }
    let lang: String?
    let synced: Bool
    let offset: Int?
    let line: [Line]?
}

struct PlainLyricsDTO: Decodable {
    let artist: String?
    let title: String?
    let value: String?
}

struct PlayQueueDTO: Decodable {
    let current: String?
    let position: Int?
    let changed: Date?
    let changedBy: String?
    let entry: [SongDTO]?
}

// MARK: Response bodies

struct PingBody: Decodable {}

struct AlbumList2Body: Decodable {
    struct List: Decodable { let album: [AlbumDTO]? }
    let albumList2: List
}

struct AlbumBody: Decodable { let album: AlbumDTO }

struct ArtistsBody: Decodable {
    struct Index: Decodable { let name: String; let artist: [ArtistDTO]? }
    struct Artists: Decodable { let index: [Index]? }
    let artists: Artists
}

struct ArtistBody: Decodable { let artist: ArtistDTO }

struct Search3Body: Decodable {
    struct Result: Decodable {
        let artist: [ArtistDTO]?
        let album: [AlbumDTO]?
        let song: [SongDTO]?
    }
    let searchResult3: Result
}

struct PlaylistsBody: Decodable {
    struct Playlists: Decodable { let playlist: [PlaylistDTO]? }
    let playlists: Playlists
}

struct PlaylistBody: Decodable { let playlist: PlaylistDTO }

struct ExtensionsBody: Decodable { let openSubsonicExtensions: [ExtensionDTO]? }

struct LyricsListBody: Decodable {
    struct List: Decodable { let structuredLyrics: [StructuredLyricsDTO]? }
    let lyricsList: List
}

struct LyricsBody: Decodable { let lyrics: PlainLyricsDTO? }

struct SimilarSongs2Body: Decodable {
    struct List: Decodable { let song: [SongDTO]? }
    let similarSongs2: List
}

struct TopSongsBody: Decodable {
    struct List: Decodable { let song: [SongDTO]? }
    let topSongs: List
}

struct PlayQueueBody: Decodable { let playQueue: PlayQueueDTO? }

// MARK: Dates

enum SubsonicDate {
    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ string: String) -> Date? {
        fractional.date(from: string) ?? plain.date(from: string)
    }
}

extension JSONDecoder {
    static let subsonic: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = SubsonicDate.parse(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(s)")
            }
            return date
        }
        return d
    }()
}
