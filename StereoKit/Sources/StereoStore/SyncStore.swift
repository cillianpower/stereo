import Foundation
import GRDB
import StereoModel

// Change tracking for app-owned state that syncs to iCloud (or, later, a self-hosted service).
//
// SQLite triggers record every local insert/update/delete of `station` and `identifiedSong` rows
// into `syncPendingChange`, so feature code (StationStore etc.) needs no sync awareness at all.
// Changes applied *from* the remote run with the `applyingRemote` flag set, which the triggers
// skip, so they are never echoed back. A pending `delete` row doubles as the tombstone until the
// remote confirms it.

/// Which kind of synced row a record is.
public enum SyncRecordType: String, Codable, Sendable, CaseIterable {
    case station = "Station"
    case identifiedSong = "IdentifiedSong"

    var prefix: String {
        switch self {
        case .station: "st-"
        case .identifiedSong: "id-"
        }
    }
}

/// Stable remote name for a synced row, e.g. `st-rb:961e…` or `id-5f0c…`.
public struct SyncRecordName: Hashable, Codable, Sendable, CustomStringConvertible {
    public let type: SyncRecordType
    /// The row's local key: station ID, or the identified song's UUID as 32 lowercase hex digits.
    public let localID: String

    public init(type: SyncRecordType, localID: String) {
        self.type = type
        self.localID = localID
    }

    public init?(_ string: String) {
        guard let type = SyncRecordType.allCases.first(where: { string.hasPrefix($0.prefix) }) else { return nil }
        let id = String(string.dropFirst(type.prefix.count))
        guard !id.isEmpty else { return nil }
        self.init(type: type, localID: id)
    }

    public var description: String { type.prefix + localID }

    public static func station(_ id: String) -> SyncRecordName { .init(type: .station, localID: id) }
    public static func identifiedSong(_ id: UUID) -> SyncRecordName { .init(type: .identifiedSong, localID: hex(id)) }

    static func hex(_ id: UUID) -> String { id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    static func uuid(fromHex hex: String) -> UUID? {
        guard hex.count == 32 else { return nil }
        var s = hex
        for i in [8, 13, 18, 23] { s.insert("-", at: s.index(s.startIndex, offsetBy: i)) }
        return UUID(uuidString: s)
    }
}

public struct PendingSyncChange: Hashable, Sendable {
    public enum Kind: String, Sendable { case save, delete }
    public var name: SyncRecordName
    public var kind: Kind
    /// When the local change happened. For deletes this is the tombstone time.
    public var changedAt: Date
}

/// Everything about a station row that syncs.
public struct SyncedStation: Hashable, Sendable {
    public var station: Station
    public var isFavorite: Bool
    public var isCustom: Bool
    public var sortIndex: Double
    public var addedAt: Date
    public var lastPlayedAt: Date?
    public var modifiedAt: Date

    public init(station: Station, isFavorite: Bool, isCustom: Bool, sortIndex: Double,
                addedAt: Date, lastPlayedAt: Date?, modifiedAt: Date) {
        self.station = station; self.isFavorite = isFavorite; self.isCustom = isCustom
        self.sortIndex = sortIndex; self.addedAt = addedAt; self.lastPlayedAt = lastPlayedAt
        self.modifiedAt = modifiedAt
    }

    public var name: SyncRecordName { .station(station.id) }
}

/// A synced row, as the remote sees it.
public enum SyncItem: Hashable, Sendable {
    case station(SyncedStation)
    case identifiedSong(IdentifiedSong)

    public var name: SyncRecordName {
        switch self {
        case .station(let s): s.name
        case .identifiedSong(let song): .identifiedSong(song.id)
        }
    }

    /// The timestamp last-writer-wins compares.
    public var modifiedAt: Date {
        switch self {
        case .station(let s): s.modifiedAt
        case .identifiedSong(let song): song.identifiedAt   // identified songs never change after creation
        }
    }
}

/// What happened when a remote save was offered to the local store.
public enum MergeOutcome: Equatable, Sendable {
    /// Remote was newer (or new): written locally.
    case appliedRemote
    /// Local copy is newer: kept, and it stays pending so it goes up.
    case keptLocal
    /// A newer local delete beats this save; the delete stays pending.
    case keptLocalDelete
}

extension LibraryStore {
    static func registerSyncMigrations(_ m: inout DatabaseMigrator) {
        m.registerMigration("v2-sync") { db in
            try db.create(table: "syncPendingChange") { t in
                t.primaryKey("recordName", .text)
                t.column("kind", .text).notNull()            // save | delete
                t.column("changedAt", .datetime).notNull()
            }
            // Opaque per-record server metadata (CloudKit system fields: change tag etc.).
            try db.create(table: "syncRecordMeta") { t in
                t.primaryKey("recordName", .text)
                t.column("systemFields", .blob).notNull()
            }
            // Engine state blobs and the `applyingRemote` flag.
            try db.create(table: "syncControl") { t in
                t.primaryKey("key", .text)
                t.column("value", .blob)
            }

            let notApplyingRemote = "NOT EXISTS (SELECT 1 FROM syncControl WHERE key = 'applyingRemote')"
            let now = "strftime('%Y-%m-%d %H:%M:%f', 'now')"
            // UUIDs are stored as 16-byte blobs by GRDB; name records by their lowercase hex.
            func songName(_ row: String) -> String {
                "'id-' || CASE typeof(\(row).id) WHEN 'blob' THEN lower(hex(\(row).id)) ELSE lower(replace(\(row).id, '-', '')) END"
            }
            let triggers: [(table: String, event: String, row: String, kind: String, name: String)] = [
                ("station", "INSERT", "NEW", "save", "'st-' || NEW.id"),
                ("station", "UPDATE", "NEW", "save", "'st-' || NEW.id"),
                ("station", "DELETE", "OLD", "delete", "'st-' || OLD.id"),
                ("identifiedSong", "INSERT", "NEW", "save", songName("NEW")),
                ("identifiedSong", "UPDATE", "NEW", "save", songName("NEW")),
                ("identifiedSong", "DELETE", "OLD", "delete", songName("OLD")),
            ]
            // DELETE + INSERT rather than INSERT OR REPLACE: inside a trigger, SQLite applies the
            // *outer* statement's conflict policy (ABORT for GRDB upserts), which would fail.
            for t in triggers {
                try db.execute(sql: """
                    CREATE TRIGGER sync_\(t.table)_\(t.event.lowercased())
                    AFTER \(t.event) ON \(t.table)
                    WHEN \(notApplyingRemote)
                    BEGIN
                        DELETE FROM syncPendingChange WHERE recordName = \(t.name);
                        INSERT INTO syncPendingChange (recordName, kind, changedAt)
                        VALUES (\(t.name), '\(t.kind)', \(now));
                    END
                    """)
            }
        }
    }

    // MARK: Pending changes

    public func pendingSyncChanges() throws -> [PendingSyncChange] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT recordName, kind, changedAt FROM syncPendingChange ORDER BY changedAt").compactMap { row in
                guard let name = SyncRecordName(row["recordName"] as String),
                      let kind = PendingSyncChange.Kind(rawValue: row["kind"]) else { return nil }
                return PendingSyncChange(name: name, kind: kind, changedAt: row["changedAt"])
            }
        }
    }

    /// Emits the pending count whenever it changes (local edits enqueue, confirmations dequeue).
    public func observePendingSyncCount() -> AsyncStream<Int> {
        observe { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncPendingChange") ?? 0 }
    }

    /// The remote confirmed these. Only clears the row if it wasn't changed again since `before`.
    public func clearPendingSync(_ names: [SyncRecordName], changedNoLaterThan before: Date? = nil) throws {
        guard !names.isEmpty else { return }
        try db.write { db in
            for name in names {
                if let before {
                    try db.execute(sql: "DELETE FROM syncPendingChange WHERE recordName = ? AND changedAt <= ?",
                                   arguments: [name.description, before])
                } else {
                    try db.execute(sql: "DELETE FROM syncPendingChange WHERE recordName = ?", arguments: [name.description])
                }
            }
        }
    }

    /// Re-queues a record, e.g. after a conflict was resolved in favour of the local copy.
    public func markPendingSync(_ name: SyncRecordName, kind: PendingSyncChange.Kind = .save) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO syncPendingChange (recordName, kind, changedAt) VALUES (?, ?, ?)",
                           arguments: [name.description, kind.rawValue, Date()])
        }
    }

    /// Queues every synced row, e.g. after signing in to a different iCloud account.
    public func enqueueAllForSync() throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO syncPendingChange (recordName, kind, changedAt)
                SELECT 'st-' || id, 'save', modifiedAt FROM station
                """)
            try db.execute(sql: """
                INSERT OR REPLACE INTO syncPendingChange (recordName, kind, changedAt)
                SELECT 'id-' || CASE typeof(id) WHEN 'blob' THEN lower(hex(id)) ELSE lower(replace(id, '-', '')) END,
                       'save', identifiedAt FROM identifiedSong
                """)
        }
    }

    // MARK: Reading local rows for upload

    public func syncItem(named name: SyncRecordName) throws -> SyncItem? {
        try db.read { db in try Self.syncItem(db, name) }
    }

    static func syncItem(_ db: Database, _ name: SyncRecordName) throws -> SyncItem? {
        switch name.type {
        case .station:
            guard let r = try StationRecord.fetchOne(db, key: name.localID),
                  let station = try? JSONDecoder().decode(Station.self, from: r.payload) else { return nil }
            return .station(SyncedStation(station: station, isFavorite: r.isFavorite, isCustom: r.isCustom,
                                          sortIndex: r.sortIndex, addedAt: r.addedAt, lastPlayedAt: r.lastPlayedAt,
                                          modifiedAt: r.modifiedAt))
        case .identifiedSong:
            guard let uuid = SyncRecordName.uuid(fromHex: name.localID) else { return nil }
            return try IdentifiedSong.fetchOne(db, key: uuid).map { .identifiedSong($0) }
        }
    }

    // MARK: Applying remote changes

    /// Offers a remote save to the local store with last-writer-wins on `modifiedAt`.
    /// Ties go to the remote, so every device converges on the server's copy.
    @discardableResult
    public func applyRemoteSave(_ item: SyncItem) throws -> MergeOutcome {
        try db.write { db in
            let pending = try Self.pending(db, item.name)
            if let pending, pending.kind == .delete, pending.changedAt > item.modifiedAt {
                return .keptLocalDelete
            }
            if pending?.kind == .save, let local = try Self.syncItem(db, item.name), local.modifiedAt > item.modifiedAt {
                return .keptLocal
            }
            try Self.whileApplyingRemote(db) {
                switch item {
                case .station(let s):
                    try StationRecord(
                        id: s.station.id, payload: try JSONEncoder().encode(s.station), isFavorite: s.isFavorite,
                        isCustom: s.isCustom, sortIndex: s.sortIndex, addedAt: s.addedAt,
                        lastPlayedAt: s.lastPlayedAt, modifiedAt: s.modifiedAt
                    ).upsert(db)
                case .identifiedSong(let song):
                    try song.upsert(db)
                }
            }
            try db.execute(sql: "DELETE FROM syncPendingChange WHERE recordName = ?", arguments: [item.name.description])
            return .appliedRemote
        }
    }

    /// Applies a remote delete. CloudKit deletions carry no timestamp, so a local *pending save*
    /// wins (the record goes back up); otherwise the row is removed.
    @discardableResult
    public func applyRemoteDelete(_ name: SyncRecordName) throws -> MergeOutcome {
        try db.write { db in
            if let pending = try Self.pending(db, name), pending.kind == .save { return .keptLocal }
            try Self.whileApplyingRemote(db) {
                switch name.type {
                case .station:
                    try db.execute(sql: "DELETE FROM station WHERE id = ?", arguments: [name.localID])
                case .identifiedSong:
                    if let uuid = SyncRecordName.uuid(fromHex: name.localID) { _ = try IdentifiedSong.deleteOne(db, key: uuid) }
                }
            }
            try db.execute(sql: "DELETE FROM syncPendingChange WHERE recordName = ?", arguments: [name.description])
            try db.execute(sql: "DELETE FROM syncRecordMeta WHERE recordName = ?", arguments: [name.description])
            return .appliedRemote
        }
    }

    private static func pending(_ db: Database, _ name: SyncRecordName) throws -> PendingSyncChange? {
        guard let row = try Row.fetchOne(db, sql: "SELECT kind, changedAt FROM syncPendingChange WHERE recordName = ?",
                                         arguments: [name.description]),
              let kind = PendingSyncChange.Kind(rawValue: row["kind"]) else { return nil }
        return PendingSyncChange(name: name, kind: kind, changedAt: row["changedAt"])
    }

    private static func whileApplyingRemote(_ db: Database, _ body: () throws -> Void) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO syncControl (key, value) VALUES ('applyingRemote', X'01')")
        defer { try? db.execute(sql: "DELETE FROM syncControl WHERE key = 'applyingRemote'") }
        try body()
    }

    // MARK: Server metadata + engine state

    public func syncSystemFields(_ name: SyncRecordName) throws -> Data? {
        try db.read { db in
            try Data.fetchOne(db, sql: "SELECT systemFields FROM syncRecordMeta WHERE recordName = ?", arguments: [name.description])
        }
    }

    public func setSyncSystemFields(_ data: Data?, for name: SyncRecordName) throws {
        try db.write { db in
            if let data {
                try db.execute(sql: "INSERT OR REPLACE INTO syncRecordMeta (recordName, systemFields) VALUES (?, ?)",
                               arguments: [name.description, data])
            } else {
                try db.execute(sql: "DELETE FROM syncRecordMeta WHERE recordName = ?", arguments: [name.description])
            }
        }
    }

    public func syncBlob(_ key: String) throws -> Data? {
        try db.read { db in try Data.fetchOne(db, sql: "SELECT value FROM syncControl WHERE key = ?", arguments: [key]) }
    }

    public func setSyncBlob(_ data: Data?, for key: String) throws {
        try db.write { db in
            if let data {
                try db.execute(sql: "INSERT OR REPLACE INTO syncControl (key, value) VALUES (?, ?)", arguments: [key, data])
            } else {
                try db.execute(sql: "DELETE FROM syncControl WHERE key = ?", arguments: [key])
            }
        }
    }

    /// Forgets all server metadata (account switched or remote zone deleted). Local rows stay.
    public func resetSyncMetadata(reenqueueAll: Bool) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM syncRecordMeta")
            try db.execute(sql: "DELETE FROM syncControl WHERE key != 'applyingRemote'")
            try db.execute(sql: "DELETE FROM syncPendingChange")
        }
        if reenqueueAll { try enqueueAllForSync() }
    }
}
