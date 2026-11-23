import Foundation
import GRDB
import TunerModel

extension LibraryStore {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    private func decode(_ records: [StationRecord]) -> [Station] {
        records.compactMap { try? Self.decoder.decode(Station.self, from: $0.payload) }
    }

    private func existing(_ db: Database, _ station: Station) throws -> StationRecord? {
        try StationRecord.fetchOne(db, key: station.id)
    }

    private func save(_ db: Database, _ station: Station, mutate: (inout StationRecord) -> Void) throws {
        let now = Date()
        var record = try existing(db, station) ?? StationRecord(
            id: station.id, payload: Data(), isFavorite: false,
            isCustom: { if case .custom = station.origin { return true } else { return false } }(),
            sortIndex: 0, addedAt: now, lastPlayedAt: nil, modifiedAt: now
        )
        record.payload = try Self.encoder.encode(station)
        record.modifiedAt = now
        mutate(&record)
        try record.upsert(db)
    }

    public func setFavorite(_ favorite: Bool, station: Station) throws {
        try db.write { db in
            let maxIndex = try Double.fetchOne(db, sql: "SELECT MAX(sortIndex) FROM station WHERE isFavorite") ?? 0
            try save(db, station) { record in
                if favorite && !record.isFavorite { record.sortIndex = maxIndex + 1 }
                record.isFavorite = favorite
            }
        }
    }

    public func isFavorite(_ station: Station) throws -> Bool {
        try db.read { db in try existing(db, station)?.isFavorite ?? false }
    }

    public func favoriteStations() throws -> [Station] {
        try db.read { db in
            decode(try StationRecord.filter(Column("isFavorite") == true).order(Column("sortIndex")).fetchAll(db))
        }
    }

    /// Every station known locally: favorites in their saved order, then the rest, most recent first.
    public func savedStations() throws -> [Station] {
        try db.read { db in
            decode(try StationRecord.fetchAll(db, sql: """
                SELECT * FROM station
                ORDER BY isFavorite DESC, CASE WHEN isFavorite THEN sortIndex END, lastPlayedAt DESC
                """))
        }
    }

    public func observeFavoriteStations() -> AsyncStream<[Station]> {
        observe { [self] db in
            decode(try StationRecord.filter(Column("isFavorite") == true).order(Column("sortIndex")).fetchAll(db))
        }
    }

    public func moveFavorite(_ station: Station, between before: Station?, and after: Station?) throws {
        try db.write { db in
            let lo = try before.flatMap { try existing(db, $0)?.sortIndex } ?? 0
            let hi = try after.flatMap { try existing(db, $0)?.sortIndex } ?? (lo + 2)
            try save(db, station) { $0.sortIndex = (lo + hi) / 2 }
        }
    }

    public func saveCustomStation(_ station: Station) throws {
        try db.write { db in try save(db, station) { $0.isCustom = true; $0.isFavorite = true } }
    }

    public func customStations() throws -> [Station] {
        try db.read { db in decode(try StationRecord.filter(Column("isCustom") == true).order(Column("addedAt")).fetchAll(db)) }
    }

    public func deleteStation(_ station: Station) throws {
        _ = try db.write { db in try StationRecord.deleteOne(db, key: station.id) }
    }

    public func markPlayed(_ station: Station) throws {
        try db.write { db in try save(db, station) { $0.lastPlayedAt = Date() } }
    }

    public func recentStations(limit: Int = 20) throws -> [Station] {
        try db.read { db in
            decode(try StationRecord.filter(Column("lastPlayedAt") != nil).order(Column("lastPlayedAt").desc).limit(limit).fetchAll(db))
        }
    }

    public func observeRecentStations(limit: Int = 20) -> AsyncStream<[Station]> {
        observe { [self] db in
            decode(try StationRecord.filter(Column("lastPlayedAt") != nil).order(Column("lastPlayedAt").desc).limit(limit).fetchAll(db))
        }
    }

    // MARK: Identified songs

    public func addIdentified(_ song: IdentifiedSong) throws {
        try db.write { db in try song.insert(db) }
    }

    public func identifiedSongs(limit: Int = 100) throws -> [IdentifiedSong] {
        try db.read { db in try IdentifiedSong.order(Column("identifiedAt").desc).limit(limit).fetchAll(db) }
    }
}
