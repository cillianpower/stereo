import Foundation
import GRDB
import StereoModel

/// Read-only queries used by StereoDiscovery. No schema changes.
extension LibraryStore {
    /// Local tracks keyed by lowercased recording MBID.
    public func tracks(musicBrainzIDs mbids: [String]) throws -> [String: Track] {
        guard !mbids.isEmpty else { return [:] }
        let wanted = mbids.map { $0.lowercased() }
        return try db.read { db in
            var result: [String: Track] = [:]
            // SQLite caps bound parameters; chunk to stay well under it.
            for start in stride(from: 0, to: wanted.count, by: 500) {
                let chunk = Array(wanted[start..<min(start + 500, wanted.count)])
                let rows = try TrackRecord.filter(chunk.contains(Column("musicBrainzID").lowercased)).fetchAll(db)
                for row in rows {
                    if let t = row.model, let key = t.musicBrainzID?.lowercased() { result[key] = t }
                }
            }
            return result
        }
    }

    /// Candidate tracks whose title shares every word of `title` (FTS prefix match), for fuzzy matching.
    public func trackCandidates(title: String, limit: Int = 20) throws -> [Track] {
        guard let pattern = FTS5Pattern(matchingAllTokensIn: title) else { return [] }
        return try db.read { db in
            try TrackRecord.fetchAll(db, sql: """
                SELECT track.* FROM track JOIN trackFTS ON trackFTS.rowid = track.rowid
                WHERE trackFTS MATCH ? ORDER BY bm25(trackFTS, 5.0, 1.0, 0.5) LIMIT ?
                """, arguments: [pattern, limit]).compactMap(\.model)
        }
    }

    /// Tracks by an artist name (case-insensitive), most-played first, for "similar artist" fallbacks.
    public func tracks(byArtistName name: String, limit: Int = 50) throws -> [Track] {
        try db.read { db in
            try TrackRecord.fetchAll(db, sql: """
                SELECT * FROM track WHERE artist = ? COLLATE NOCASE
                ORDER BY COALESCE(playCount, 0) DESC, RANDOM() LIMIT ?
                """, arguments: [name, limit]).compactMap(\.model)
        }
    }

    /// Tracks in a genre, random order. Last-resort offline continuation.
    public func tracks(inGenre genre: String, limit: Int = 50) throws -> [Track] {
        try db.read { db in
            try TrackRecord.fetchAll(db, sql: """
                SELECT * FROM track WHERE genre = ? COLLATE NOCASE ORDER BY RANDOM() LIMIT ?
                """, arguments: [genre, limit]).compactMap(\.model)
        }
    }

    public func tracks(ids: [ItemID]) throws -> [Track] {
        guard !ids.isEmpty else { return [] }
        let keys = ids.map(\.description)
        return try db.read { db in
            let byID = Dictionary(try TrackRecord.filter(keys: keys).fetchAll(db).compactMap { r in r.model.map { (r.id, $0) } },
                                  uniquingKeysWith: { a, _ in a })
            return keys.compactMap { byID[$0] }
        }
    }
}
