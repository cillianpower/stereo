import Foundation
import GRDB
import StereoModel

// Database rows. IDs are stored as `ItemID.description` ("source:raw").

struct AlbumRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "album"
    var id: String
    var name: String
    var artist: String?
    var artistID: String?
    var year: Int?
    var genre: String?
    var songCount: Int?
    var durationSeconds: Int?
    var coverArtID: String?
    var created: Date?
    var starred: Date?
    var playCount: Int?
    var lastPlayed: Date?
    var syncedAt: Date

    init(_ a: Album, syncedAt: Date = Date()) {
        id = a.id.description; name = a.name; artist = a.artist; artistID = a.artistID?.description
        year = a.year; genre = a.genre; songCount = a.songCount
        durationSeconds = a.duration.map { Int($0.components.seconds) }; coverArtID = a.coverArtID
        created = a.created; starred = a.starred; playCount = a.playCount; lastPlayed = a.lastPlayed
        self.syncedAt = syncedAt
    }

    var model: Album? {
        guard let id = ItemID(string: id) else { return nil }
        return Album(id: id, name: name, artist: artist, artistID: artistID.flatMap(ItemID.init(string:)), year: year,
                     genre: genre, songCount: songCount, duration: durationSeconds.map { .seconds($0) },
                     coverArtID: coverArtID, created: created, starred: starred, playCount: playCount, lastPlayed: lastPlayed)
    }
}

struct ArtistRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "artist"
    var id: String
    var name: String
    var albumCount: Int?
    var coverArtID: String?
    var starred: Date?

    init(_ a: Artist) {
        id = a.id.description; name = a.name; albumCount = a.albumCount; coverArtID = a.coverArtID; starred = a.starred
    }

    var model: Artist? {
        guard let id = ItemID(string: id) else { return nil }
        return Artist(id: id, name: name, albumCount: albumCount, coverArtID: coverArtID, starred: starred)
    }
}

struct TrackRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "track"
    var id: String
    var title: String
    var artist: String?
    var artistID: String?
    var album: String?
    var albumID: String?
    var trackNumber: Int?
    var discNumber: Int?
    var year: Int?
    var genre: String?
    var durationSeconds: Int?
    var coverArtID: String?
    var codec: String?
    var bitRate: Int?
    var sampleRate: Int?
    var bitDepth: Int?
    var channels: Int?
    var rgTrackGain: Double?
    var rgTrackPeak: Double?
    var rgAlbumGain: Double?
    var rgAlbumPeak: Double?
    var starred: Date?
    var rating: Int?
    var playCount: Int?
    var musicBrainzID: String?

    init(_ t: Track) {
        id = t.id.description; title = t.title; artist = t.artist; artistID = t.artistID?.description
        album = t.album; albumID = t.albumID?.description; trackNumber = t.trackNumber; discNumber = t.discNumber
        year = t.year; genre = t.genre; durationSeconds = t.duration.map { Int($0.components.seconds) }
        coverArtID = t.coverArtID; codec = t.format.codec; bitRate = t.format.bitRate; sampleRate = t.format.sampleRate
        bitDepth = t.format.bitDepth; channels = t.format.channels
        rgTrackGain = t.replayGain.trackGain; rgTrackPeak = t.replayGain.trackPeak
        rgAlbumGain = t.replayGain.albumGain; rgAlbumPeak = t.replayGain.albumPeak
        starred = t.starred; rating = t.rating; playCount = t.playCount; musicBrainzID = t.musicBrainzID
    }

    var model: Track? {
        guard let id = ItemID(string: id) else { return nil }
        return Track(
            id: id, title: title, artist: artist, artistID: artistID.flatMap(ItemID.init(string:)), album: album,
            albumID: albumID.flatMap(ItemID.init(string:)), trackNumber: trackNumber, discNumber: discNumber, year: year,
            genre: genre, duration: durationSeconds.map { .seconds($0) }, coverArtID: coverArtID,
            format: AudioFormat(codec: codec, bitRate: bitRate, sampleRate: sampleRate, bitDepth: bitDepth, channels: channels),
            replayGain: ReplayGain(trackGain: rgTrackGain, trackPeak: rgTrackPeak, albumGain: rgAlbumGain, albumPeak: rgAlbumPeak),
            starred: starred, rating: rating, playCount: playCount, musicBrainzID: musicBrainzID
        )
    }
}

struct PlaylistRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "playlist"
    var id: String
    var name: String
    var comment: String?
    var songCount: Int?
    var durationSeconds: Int?
    var coverArtID: String?
    var changed: Date?

    init(_ p: Playlist) {
        id = p.id.description; name = p.name; comment = p.comment; songCount = p.songCount
        durationSeconds = p.duration.map { Int($0.components.seconds) }; coverArtID = p.coverArtID; changed = p.changed
    }

    var model: Playlist? {
        guard let id = ItemID(string: id) else { return nil }
        return Playlist(id: id, name: name, comment: comment, songCount: songCount,
                        duration: durationSeconds.map { .seconds($0) }, coverArtID: coverArtID, changed: changed)
    }
}

/// Saved stations: favorites, custom URLs and recents. Synced to iCloud later (CKSyncEngine).
struct StationRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "station"
    var id: String
    var payload: Data          // JSON-encoded `Station`
    var isFavorite: Bool
    var isCustom: Bool
    var sortIndex: Double
    var addedAt: Date
    var lastPlayedAt: Date?
    var modifiedAt: Date
}

public struct IdentifiedSong: Codable, Hashable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "identifiedSong"
    public var id: UUID
    public var title: String
    public var artist: String?
    public var artworkURL: URL?
    public var stationName: String?
    public var identifiedAt: Date
    public var libraryTrackID: String?

    public init(id: UUID = UUID(), title: String, artist: String?, artworkURL: URL?, stationName: String?,
                identifiedAt: Date = Date(), libraryTrackID: ItemID? = nil) {
        self.id = id; self.title = title; self.artist = artist; self.artworkURL = artworkURL
        self.stationName = stationName; self.identifiedAt = identifiedAt; self.libraryTrackID = libraryTrackID?.description
    }
}
