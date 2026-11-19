import Foundation
import GRDB
import TunerModel

/// Local SQLite mirror of the library index plus app-owned state (stations, identified songs).
/// The server stays the source of truth for music; this is a cache and the offline index.
public final class LibraryStore: Sendable {
    let db: any DatabaseWriter

    /// On-disk store (WAL mode, many concurrent readers).
    public convenience init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        try self.init(writer: DatabasePool(path: path, configuration: config))
    }

    /// In-memory store for tests and previews.
    public static func inMemory() throws -> LibraryStore {
        try LibraryStore(writer: DatabaseQueue())
    }

    init(writer: any DatabaseWriter) throws {
        db = writer
        try Self.migrator.migrate(writer)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        #if DEBUG
        m.eraseDatabaseOnSchemaChange = true
        #endif

        m.registerMigration("v1") { db in
            try db.create(table: "artist") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull().collate(.localizedCaseInsensitiveCompare)
                t.column("albumCount", .integer)
                t.column("coverArtID", .text)
                t.column("starred", .datetime)
            }
            try db.create(table: "album") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull().collate(.localizedCaseInsensitiveCompare)
                t.column("artist", .text).collate(.localizedCaseInsensitiveCompare)
                t.column("artistID", .text).indexed()
                t.column("year", .integer)
                t.column("genre", .text)
                t.column("songCount", .integer)
                t.column("durationSeconds", .integer)
                t.column("coverArtID", .text)
                t.column("created", .datetime).indexed()
                t.column("starred", .datetime)
                t.column("playCount", .integer)
                t.column("lastPlayed", .datetime).indexed()
                t.column("syncedAt", .datetime).notNull()
            }
            try db.create(table: "track") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("artist", .text)
                t.column("artistID", .text)
                t.column("album", .text)
                t.column("albumID", .text).indexed().references("album", onDelete: .cascade)
                t.column("trackNumber", .integer)
                t.column("discNumber", .integer)
                t.column("year", .integer)
                t.column("genre", .text)
                t.column("durationSeconds", .integer)
                t.column("coverArtID", .text)
                t.column("codec", .text)
                t.column("bitRate", .integer)
                t.column("sampleRate", .integer)
                t.column("bitDepth", .integer)
                t.column("channels", .integer)
                t.column("rgTrackGain", .double)
                t.column("rgTrackPeak", .double)
                t.column("rgAlbumGain", .double)
                t.column("rgAlbumPeak", .double)
                t.column("starred", .datetime)
                t.column("rating", .integer)
                t.column("playCount", .integer)
                t.column("musicBrainzID", .text)
            }
            try db.create(table: "playlist") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("comment", .text)
                t.column("songCount", .integer)
                t.column("durationSeconds", .integer)
                t.column("coverArtID", .text)
                t.column("changed", .datetime)
            }
            try db.create(virtualTable: "trackFTS", using: FTS5()) { t in
                t.synchronize(withTable: "track")
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("title"); t.column("artist"); t.column("album")
            }
            try db.create(virtualTable: "albumFTS", using: FTS5()) { t in
                t.synchronize(withTable: "album")
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("name"); t.column("artist")
            }
            try db.create(virtualTable: "artistFTS", using: FTS5()) { t in
                t.synchronize(withTable: "artist")
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("name")
            }
            try db.create(table: "station") { t in
                t.primaryKey("id", .text)
                t.column("payload", .blob).notNull()
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("isCustom", .boolean).notNull().defaults(to: false)
                t.column("sortIndex", .double).notNull().defaults(to: 0)
                t.column("addedAt", .datetime).notNull()
                t.column("lastPlayedAt", .datetime)
                t.column("modifiedAt", .datetime).notNull()
            }
            try db.create(table: "identifiedSong") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("artist", .text)
                t.column("artworkURL", .text)
                t.column("stationName", .text)
                t.column("identifiedAt", .datetime).notNull().indexed()
                t.column("libraryTrackID", .text)
            }
            try db.create(table: "syncState") { t in
                t.primaryKey("key", .text)
                t.column("value", .text)
            }
        }
        registerDownloadMigrations(&m)
        return m
    }

    // MARK: Writes

    public func upsert(albums: [Album], syncedAt: Date = Date()) throws {
        try db.write { db in
            for album in albums { try AlbumRecord(album, syncedAt: syncedAt).upsert(db) }
        }
    }

    /// Stores an album and replaces its track list.
    public func upsert(_ detail: AlbumDetail, syncedAt: Date = Date()) throws {
        try db.write { db in
            try AlbumRecord(detail.album, syncedAt: syncedAt).upsert(db)
            let keep = detail.tracks.map(\.id.description)
            try TrackRecord.filter(Column("albumID") == detail.album.id.description && !keep.contains(Column("id"))).deleteAll(db)
            for track in detail.tracks {
                var record = TrackRecord(track)
                record.albumID = detail.album.id.description
                try record.upsert(db)
            }
        }
    }

    public func replaceArtists(_ artists: [Artist]) throws {
        try db.write { db in
            let keep = artists.map(\.id.description)
            try ArtistRecord.filter(!keep.contains(Column("id"))).deleteAll(db)
            for artist in artists { try ArtistRecord(artist).upsert(db) }
        }
    }

    public func replacePlaylists(_ playlists: [Playlist]) throws {
        try db.write { db in
            let keep = playlists.map(\.id.description)
            try PlaylistRecord.filter(!keep.contains(Column("id"))).deleteAll(db)
            for p in playlists { try PlaylistRecord(p).upsert(db) }
        }
    }

    /// Deletes albums (and, by cascade, their tracks) not seen since `date`. Used after a full walk.
    @discardableResult
    public func removeAlbums(syncedBefore date: Date) throws -> Int {
        try db.write { db in try AlbumRecord.filter(Column("syncedAt") < date).deleteAll(db) }
    }

    public func setStarred(_ starred: Date?, track id: ItemID) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE track SET starred = ? WHERE id = ?", arguments: [starred, id.description])
        }
    }

    public func setStarred(_ starred: Date?, album id: ItemID) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE album SET starred = ? WHERE id = ?", arguments: [starred, id.description])
        }
    }

    // MARK: Reads

    public enum AlbumSort: Sendable { case name, artist, recentlyAdded, recentlyPlayed, year }

    public func albums(sortedBy sort: AlbumSort = .name, limit: Int? = nil) throws -> [Album] {
        try db.read { db in try Self.albumRequest(sort: sort, limit: limit).fetchAll(db).compactMap(\.model) }
    }

    static func albumRequest(sort: AlbumSort, limit: Int?) -> QueryInterfaceRequest<AlbumRecord> {
        var request: QueryInterfaceRequest<AlbumRecord>
        switch sort {
        case .name: request = AlbumRecord.order(Column("name"))
        case .artist: request = AlbumRecord.order(Column("artist"), Column("year"), Column("name"))
        case .recentlyAdded: request = AlbumRecord.order(Column("created").desc)
        case .recentlyPlayed: request = AlbumRecord.filter(Column("lastPlayed") != nil).order(Column("lastPlayed").desc)
        case .year: request = AlbumRecord.order(Column("year").desc, Column("name"))
        }
        if let limit { request = request.limit(limit) }
        return request
    }

    public func album(_ id: ItemID) throws -> AlbumDetail? {
        try db.read { db in
            guard let album = try AlbumRecord.fetchOne(db, key: id.description)?.model else { return nil }
            let tracks = try TrackRecord
                .filter(Column("albumID") == id.description)
                .order(Column("discNumber"), Column("trackNumber"), Column("title"))
                .fetchAll(db).compactMap(\.model)
            return AlbumDetail(album: album, tracks: tracks)
        }
    }

    public func albums(byArtist artistID: ItemID) throws -> [Album] {
        try db.read { db in
            try AlbumRecord.filter(Column("artistID") == artistID.description).order(Column("year").desc)
                .fetchAll(db).compactMap(\.model)
        }
    }

    public func artists() throws -> [Artist] {
        try db.read { db in try ArtistRecord.order(Column("name")).fetchAll(db).compactMap(\.model) }
    }

    public func playlists() throws -> [Playlist] {
        try db.read { db in try PlaylistRecord.order(Column("name")).fetchAll(db).compactMap(\.model) }
    }

    public func starredTracks() throws -> [Track] {
        try db.read { db in
            try TrackRecord.filter(Column("starred") != nil).order(Column("starred").desc).fetchAll(db).compactMap(\.model)
        }
    }

    /// Albums played a lot but not in `days` days — the "Rediscover" shelf.
    public func rediscoverAlbums(notPlayedInDays days: Int = 90, minPlays: Int = 5, limit: Int = 20) throws -> [Album] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        return try db.read { db in
            try AlbumRecord
                .filter(Column("playCount") >= minPlays && Column("lastPlayed") < cutoff)
                .order(Column("playCount").desc)
                .limit(limit)
                .fetchAll(db).compactMap(\.model)
        }
    }

    public func counts() throws -> (albums: Int, tracks: Int, artists: Int) {
        try db.read { db in
            (try AlbumRecord.fetchCount(db), try TrackRecord.fetchCount(db), try ArtistRecord.fetchCount(db))
        }
    }

    /// Instant offline search with prefix matching ("boa can" finds "Boards of Canada").
    public func search(_ query: String, limit: Int = 25) throws -> SearchResults {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return SearchResults() }
        return try db.read { db in
            let artists = try ArtistRecord.fetchAll(db, sql: """
                SELECT artist.* FROM artist JOIN artistFTS ON artistFTS.rowid = artist.rowid
                WHERE artistFTS MATCH ? ORDER BY bm25(artistFTS) LIMIT ?
                """, arguments: [pattern, limit])
            let albums = try AlbumRecord.fetchAll(db, sql: """
                SELECT album.* FROM album JOIN albumFTS ON albumFTS.rowid = album.rowid
                WHERE albumFTS MATCH ? ORDER BY bm25(albumFTS) LIMIT ?
                """, arguments: [pattern, limit])
            let tracks = try TrackRecord.fetchAll(db, sql: """
                SELECT track.* FROM track JOIN trackFTS ON trackFTS.rowid = track.rowid
                WHERE trackFTS MATCH ? ORDER BY bm25(trackFTS, 3.0, 1.0, 1.0) LIMIT ?
                """, arguments: [pattern, limit])
            return SearchResults(artists: artists.compactMap(\.model), albums: albums.compactMap(\.model),
                                 tracks: tracks.compactMap(\.model))
        }
    }

    /// Best local match for a radio "Artist - Title", for "In your library".
    public func findTrack(artist: String?, title: String) throws -> Track? {
        let text = [artist, title].compactMap { $0 }.joined(separator: " ")
        return try search(text, limit: 5).tracks.first { track in
            track.title.localizedCaseInsensitiveContains(title) || title.localizedCaseInsensitiveContains(track.title)
        }
    }

    // MARK: Observation (drives SwiftUI)

    public func observeAlbums(sortedBy sort: AlbumSort = .name, limit: Int? = nil) -> AsyncStream<[Album]> {
        observe { db in try Self.albumRequest(sort: sort, limit: limit).fetchAll(db).compactMap(\.model) }
    }

    public func observeArtists() -> AsyncStream<[Artist]> {
        observe { db in try ArtistRecord.order(Column("name")).fetchAll(db).compactMap(\.model) }
    }

    public func observePlaylists() -> AsyncStream<[Playlist]> {
        observe { db in try PlaylistRecord.order(Column("name")).fetchAll(db).compactMap(\.model) }
    }

    func observe<T: Sendable>(_ fetch: @escaping @Sendable (Database) throws -> T) -> AsyncStream<T> {
        let observation = ValueObservation.tracking(fetch)
        let db = self.db
        return AsyncStream { continuation in
            let cancellable = observation.start(in: db, scheduling: .async(onQueue: .main)) { _ in
                continuation.finish()
            } onChange: { value in
                continuation.yield(value)
            }
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    // MARK: Sync bookkeeping

    public func syncValue(_ key: String) throws -> String? {
        try db.read { db in try String.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [key]) }
    }

    public func setSyncValue(_ value: String?, for key: String) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO syncState (key, value) VALUES (?, ?)", arguments: [key, value])
        }
    }
}
