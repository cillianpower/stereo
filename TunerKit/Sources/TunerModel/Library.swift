import Foundation

public struct ReplayGain: Hashable, Codable, Sendable {
    public var trackGain: Double?
    public var trackPeak: Double?
    public var albumGain: Double?
    public var albumPeak: Double?

    public init(trackGain: Double? = nil, trackPeak: Double? = nil, albumGain: Double? = nil, albumPeak: Double? = nil) {
        self.trackGain = trackGain
        self.trackPeak = trackPeak
        self.albumGain = albumGain
        self.albumPeak = albumPeak
    }

    public var isEmpty: Bool { trackGain == nil && albumGain == nil }
}

/// Technical description of an audio file, for lossless badges.
public struct AudioFormat: Hashable, Codable, Sendable {
    public var codec: String?          // "flac", "mp3", "aac", "alac", "opus"
    public var bitRate: Int?           // kbps
    public var sampleRate: Int?        // Hz
    public var bitDepth: Int?
    public var channels: Int?

    public init(codec: String? = nil, bitRate: Int? = nil, sampleRate: Int? = nil, bitDepth: Int? = nil, channels: Int? = nil) {
        self.codec = codec
        self.bitRate = bitRate
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
    }

    public var isLossless: Bool {
        guard let codec = codec?.lowercased() else { return false }
        return ["flac", "alac", "wav", "aiff", "ape", "wv"].contains(codec)
    }

    /// True for anything above CD quality (more than 16-bit or more than 48 kHz).
    public var isHiRes: Bool {
        isLossless && ((bitDepth ?? 0) > 16 || (sampleRate ?? 0) > 48_000)
    }
}

public struct Track: Identifiable, Hashable, Codable, Sendable {
    public var id: ItemID
    public var title: String
    public var artist: String?
    public var artistID: ItemID?
    public var album: String?
    public var albumID: ItemID?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var year: Int?
    public var genre: String?
    public var duration: Duration?
    public var coverArtID: String?
    public var format: AudioFormat
    public var replayGain: ReplayGain
    public var starred: Date?
    public var rating: Int?
    public var playCount: Int?
    public var musicBrainzID: String?

    public init(
        id: ItemID, title: String, artist: String? = nil, artistID: ItemID? = nil,
        album: String? = nil, albumID: ItemID? = nil, trackNumber: Int? = nil, discNumber: Int? = nil,
        year: Int? = nil, genre: String? = nil, duration: Duration? = nil, coverArtID: String? = nil,
        format: AudioFormat = .init(), replayGain: ReplayGain = .init(), starred: Date? = nil,
        rating: Int? = nil, playCount: Int? = nil, musicBrainzID: String? = nil
    ) {
        self.id = id; self.title = title; self.artist = artist; self.artistID = artistID
        self.album = album; self.albumID = albumID; self.trackNumber = trackNumber; self.discNumber = discNumber
        self.year = year; self.genre = genre; self.duration = duration; self.coverArtID = coverArtID
        self.format = format; self.replayGain = replayGain; self.starred = starred
        self.rating = rating; self.playCount = playCount; self.musicBrainzID = musicBrainzID
    }
}

public struct Album: Identifiable, Hashable, Codable, Sendable {
    public var id: ItemID
    public var name: String
    public var artist: String?
    public var artistID: ItemID?
    public var year: Int?
    public var genre: String?
    public var songCount: Int?
    public var duration: Duration?
    public var coverArtID: String?
    public var created: Date?
    public var starred: Date?
    public var playCount: Int?
    public var lastPlayed: Date?
    /// Server-side modification marker used for delta sync.
    public var changed: Date?

    public init(
        id: ItemID, name: String, artist: String? = nil, artistID: ItemID? = nil, year: Int? = nil,
        genre: String? = nil, songCount: Int? = nil, duration: Duration? = nil, coverArtID: String? = nil,
        created: Date? = nil, starred: Date? = nil, playCount: Int? = nil, lastPlayed: Date? = nil, changed: Date? = nil
    ) {
        self.id = id; self.name = name; self.artist = artist; self.artistID = artistID; self.year = year
        self.genre = genre; self.songCount = songCount; self.duration = duration; self.coverArtID = coverArtID
        self.created = created; self.starred = starred; self.playCount = playCount; self.lastPlayed = lastPlayed
        self.changed = changed
    }
}

public struct AlbumDetail: Hashable, Codable, Sendable {
    public var album: Album
    public var tracks: [Track]
    public init(album: Album, tracks: [Track]) { self.album = album; self.tracks = tracks }
}

public struct Artist: Identifiable, Hashable, Codable, Sendable {
    public var id: ItemID
    public var name: String
    public var albumCount: Int?
    public var coverArtID: String?
    public var starred: Date?

    public init(id: ItemID, name: String, albumCount: Int? = nil, coverArtID: String? = nil, starred: Date? = nil) {
        self.id = id; self.name = name; self.albumCount = albumCount; self.coverArtID = coverArtID; self.starred = starred
    }
}

public struct ArtistDetail: Hashable, Codable, Sendable {
    public var artist: Artist
    public var albums: [Album]
    public init(artist: Artist, albums: [Album]) { self.artist = artist; self.albums = albums }
}

public struct Playlist: Identifiable, Hashable, Codable, Sendable {
    public var id: ItemID
    public var name: String
    public var comment: String?
    public var songCount: Int?
    public var duration: Duration?
    public var coverArtID: String?
    public var changed: Date?

    public init(id: ItemID, name: String, comment: String? = nil, songCount: Int? = nil,
                duration: Duration? = nil, coverArtID: String? = nil, changed: Date? = nil) {
        self.id = id; self.name = name; self.comment = comment; self.songCount = songCount
        self.duration = duration; self.coverArtID = coverArtID; self.changed = changed
    }
}

public struct PlaylistDetail: Hashable, Codable, Sendable {
    public var playlist: Playlist
    public var tracks: [Track]
    public init(playlist: Playlist, tracks: [Track]) { self.playlist = playlist; self.tracks = tracks }
}

public struct SearchResults: Hashable, Codable, Sendable {
    public var artists: [Artist]
    public var albums: [Album]
    public var tracks: [Track]
    public init(artists: [Artist] = [], albums: [Album] = [], tracks: [Track] = []) {
        self.artists = artists; self.albums = albums; self.tracks = tracks
    }
    public var isEmpty: Bool { artists.isEmpty && albums.isEmpty && tracks.isEmpty }
}

public struct Lyrics: Hashable, Codable, Sendable {
    public struct Line: Hashable, Codable, Sendable {
        public var start: Duration?
        public var text: String
        public init(start: Duration?, text: String) { self.start = start; self.text = text }
    }
    public var lines: [Line]
    public var isSynced: Bool
    public init(lines: [Line], isSynced: Bool) { self.lines = lines; self.isSynced = isSynced }

    /// Index of the line active at `position`, for synced lyrics.
    public func activeLineIndex(at position: Duration) -> Int? {
        guard isSynced else { return nil }
        var result: Int?
        for (i, line) in lines.enumerated() {
            guard let start = line.start else { continue }
            if start <= position { result = i } else { break }
        }
        return result
    }
}
