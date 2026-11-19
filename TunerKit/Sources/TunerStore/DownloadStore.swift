import Foundation
import GRDB
import TunerModel

// MARK: Public types

/// Something the user pinned for offline listening.
public enum PinOwner: Hashable, Sendable {
    case album(ItemID)
    case playlist(ItemID)
    case track(ItemID)

    public var kind: String {
        switch self {
        case .album: "album"
        case .playlist: "playlist"
        case .track: "track"
        }
    }

    public var itemID: ItemID {
        switch self {
        case .album(let id), .playlist(let id), .track(let id): id
        }
    }

    init?(kind: String, id: String) {
        guard let itemID = ItemID(string: id) else { return nil }
        switch kind {
        case "album": self = .album(itemID)
        case "playlist": self = .playlist(itemID)
        case "track": self = .track(itemID)
        default: return nil
        }
    }
}

public struct Pin: Hashable, Sendable, Identifiable {
    public var owner: PinOwner
    public var name: String
    public var subtitle: String?
    public var coverArtID: String?
    /// Storage key of the quality, e.g. "original" or "aac@256" (see `DownloadQuality`).
    public var quality: String
    public var pinnedAt: Date

    public var id: String { "\(owner.kind):\(owner.itemID)" }

    public init(owner: PinOwner, name: String, subtitle: String? = nil, coverArtID: String? = nil,
                quality: String, pinnedAt: Date = Date()) {
        self.owner = owner; self.name = name; self.subtitle = subtitle; self.coverArtID = coverArtID
        self.quality = quality; self.pinnedAt = pinnedAt
    }
}

public enum DownloadState: String, Codable, Sendable { case queued, downloading, done, failed }

public struct DownloadEntry: Hashable, Sendable {
    public var trackID: ItemID
    public var owner: PinOwner
    public var state: DownloadState
    public var bytes: Int64
    public var totalBytes: Int64?
    /// Path relative to the downloads directory.
    public var relativePath: String
    public var quality: String
    public var error: String?
    public var attempts: Int
    public var retryAfter: Date?
}

/// A track to keep downloaded for a pin, with the file name it will be stored under.
public struct PinnedTrack: Hashable, Sendable {
    public var trackID: ItemID
    public var relativePath: String
    public init(trackID: ItemID, relativePath: String) { self.trackID = trackID; self.relativePath = relativePath }
}

/// Aggregate state of one pin, for progress rings and badges.
public struct PinProgress: Hashable, Sendable {
    public var total: Int
    public var done: Int
    public var failed: Int
    public var downloading: Int
    public var bytes: Int64

    public var fraction: Double { total == 0 ? 1 : Double(done) / Double(total) }
    public var isComplete: Bool { done == total }
}

public enum DownloadUpdate: Sendable {
    case started
    case progress(bytes: Int64, total: Int64?)
    case finished(bytes: Int64)
    /// `retryAfter` non-nil → back to `queued` until then; nil → permanently `failed`.
    case failed(message: String, attempts: Int, retryAfter: Date?)
}

// MARK: Records

struct PinRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pin"
    var ownerKind: String
    var ownerID: String
    var name: String
    var subtitle: String?
    var coverArtID: String?
    var quality: String
    var pinnedAt: Date

    var model: Pin? {
        guard let owner = PinOwner(kind: ownerKind, id: ownerID) else { return nil }
        return Pin(owner: owner, name: name, subtitle: subtitle, coverArtID: coverArtID, quality: quality, pinnedAt: pinnedAt)
    }
}

struct PinTrackRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pinTrack"
    var ownerKind: String
    var ownerID: String
    var trackID: String
    var position: Int
}

struct DownloadRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "download"
    var trackID: String
    var ownerKind: String
    var ownerID: String
    var state: String
    var bytes: Int64
    var totalBytes: Int64?
    var relativePath: String
    var quality: String
    var error: String?
    var attempts: Int
    var retryAfter: Date?
    var updatedAt: Date

    var model: DownloadEntry? {
        guard let id = ItemID(string: trackID), let owner = PinOwner(kind: ownerKind, id: ownerID) else { return nil }
        return DownloadEntry(trackID: id, owner: owner, state: DownloadState(rawValue: state) ?? .queued, bytes: bytes,
                             totalBytes: totalBytes, relativePath: relativePath, quality: quality, error: error,
                             attempts: attempts, retryAfter: retryAfter)
    }
}

// MARK: Migration

extension LibraryStore {
    static func registerDownloadMigrations(_ m: inout DatabaseMigrator) {
        m.registerMigration("v2-downloads") { db in
            try db.create(table: "pin") { t in
                t.column("ownerKind", .text).notNull()
                t.column("ownerID", .text).notNull()
                t.column("name", .text).notNull()
                t.column("subtitle", .text)
                t.column("coverArtID", .text)
                t.column("quality", .text).notNull()
                t.column("pinnedAt", .datetime).notNull()
                t.primaryKey(["ownerKind", "ownerID"])
            }
            try db.create(table: "pinTrack") { t in
                t.column("ownerKind", .text).notNull()
                t.column("ownerID", .text).notNull()
                t.column("trackID", .text).notNull().indexed()
                t.column("position", .integer).notNull()
                t.primaryKey(["ownerKind", "ownerID", "trackID"])
            }
            try db.create(table: "download") { t in
                t.primaryKey("trackID", .text)
                t.column("ownerKind", .text).notNull()
                t.column("ownerID", .text).notNull()
                t.column("state", .text).notNull().indexed()
                t.column("bytes", .integer).notNull().defaults(to: 0)
                t.column("totalBytes", .integer)
                t.column("relativePath", .text).notNull()
                t.column("quality", .text).notNull()
                t.column("error", .text)
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("retryAfter", .datetime)
                t.column("updatedAt", .datetime).notNull()
            }
        }
    }
}

// MARK: Queries

extension LibraryStore {
    /// Creates or refreshes a pin with its current track list. New tracks are queued; tracks no
    /// longer in the list lose this owner. Returns downloads that no pin needs any more, so the
    /// caller can delete their files.
    @discardableResult
    public func savePin(_ pin: Pin, tracks: [PinnedTrack]) throws -> [DownloadEntry] {
        try db.write { db in
            let kind = pin.owner.kind, oid = pin.owner.itemID.description
            var record = PinRecord(ownerKind: kind, ownerID: oid, name: pin.name, subtitle: pin.subtitle,
                                   coverArtID: pin.coverArtID, quality: pin.quality, pinnedAt: pin.pinnedAt)
            if let existing = try PinRecord.fetchOne(db, key: ["ownerKind": kind, "ownerID": oid]) {
                record.pinnedAt = existing.pinnedAt
                record.quality = existing.quality
            }
            try record.upsert(db)

            let existing = try PinTrackRecord.filter(Column("ownerKind") == kind && Column("ownerID") == oid).fetchAll(db)
            let wanted = Set(tracks.map(\.trackID.description))
            let removed = existing.map(\.trackID).filter { !wanted.contains($0) }
            try PinTrackRecord
                .filter(Column("ownerKind") == kind && Column("ownerID") == oid && removed.contains(Column("trackID")))
                .deleteAll(db)

            let now = Date()
            for (position, track) in tracks.enumerated() {
                let tid = track.trackID.description
                try PinTrackRecord(ownerKind: kind, ownerID: oid, trackID: tid, position: position).upsert(db)
                if try DownloadRecord.fetchOne(db, key: tid) == nil {
                    try DownloadRecord(trackID: tid, ownerKind: kind, ownerID: oid, state: DownloadState.queued.rawValue,
                                       bytes: 0, totalBytes: nil, relativePath: track.relativePath, quality: record.quality,
                                       error: nil, attempts: 0, retryAfter: nil, updatedAt: now).insert(db)
                }
            }
            return try Self.deleteOrphans(db, candidates: removed)
        }
    }

    /// Removes a pin. Returns downloads that no other pin needs (their files should be deleted).
    @discardableResult
    public func removePin(_ owner: PinOwner) throws -> [DownloadEntry] {
        try db.write { db in
            let kind = owner.kind, oid = owner.itemID.description
            let tracks = try PinTrackRecord.filter(Column("ownerKind") == kind && Column("ownerID") == oid).fetchAll(db).map(\.trackID)
            try PinTrackRecord.filter(Column("ownerKind") == kind && Column("ownerID") == oid).deleteAll(db)
            _ = try PinRecord.deleteOne(db, key: ["ownerKind": kind, "ownerID": oid])
            return try Self.deleteOrphans(db, candidates: tracks)
        }
    }

    private static func deleteOrphans(_ db: Database, candidates: [String]) throws -> [DownloadEntry] {
        var orphans: [DownloadEntry] = []
        for tid in candidates {
            let stillOwned = try PinTrackRecord.filter(Column("trackID") == tid).fetchCount(db) > 0
            guard !stillOwned, let record = try DownloadRecord.fetchOne(db, key: tid) else { continue }
            try record.delete(db)
            if let model = record.model { orphans.append(model) }
        }
        return orphans
    }

    public func pins() throws -> [Pin] {
        try db.read { db in try PinRecord.order(Column("pinnedAt").desc).fetchAll(db).compactMap(\.model) }
    }

    public func observePins() -> AsyncStream<[Pin]> {
        observe { db in try PinRecord.order(Column("pinnedAt").desc).fetchAll(db).compactMap(\.model) }
    }

    public func pin(for owner: PinOwner) throws -> Pin? {
        try db.read { db in
            try PinRecord.fetchOne(db, key: ["ownerKind": owner.kind, "ownerID": owner.itemID.description])?.model
        }
    }

    public func pinnedTrackIDs(_ owner: PinOwner) throws -> [ItemID] {
        try db.read { db in
            try PinTrackRecord.filter(Column("ownerKind") == owner.kind && Column("ownerID") == owner.itemID.description)
                .order(Column("position")).fetchAll(db).compactMap { ItemID(string: $0.trackID) }
        }
    }

    /// Next download to start: queued, not already active, and not waiting out a retry delay.
    public func nextQueuedDownload(excluding active: Set<ItemID>, now: Date = Date()) throws -> DownloadEntry? {
        let excluded = active.map(\.description)
        return try db.read { db in
            try DownloadRecord
                .filter(Column("state") == DownloadState.queued.rawValue && !excluded.contains(Column("trackID")))
                .filter(Column("retryAfter") == nil || Column("retryAfter") <= now)
                .order(Column("updatedAt"), Column("trackID"))
                .fetchOne(db)?.model
        }
    }

    /// When the soonest delayed retry becomes due, if any.
    public func earliestRetry() throws -> Date? {
        try db.read { db in
            try Date.fetchOne(db, sql: "SELECT MIN(retryAfter) FROM download WHERE state = ? AND retryAfter IS NOT NULL",
                              arguments: [DownloadState.queued.rawValue])
        }
    }

    public func downloadEntry(_ trackID: ItemID) throws -> DownloadEntry? {
        try db.read { db in try DownloadRecord.fetchOne(db, key: trackID.description)?.model }
    }

    public func downloadEntries(state: DownloadState? = nil) throws -> [DownloadEntry] {
        try db.read { db in
            var request = DownloadRecord.all()
            if let state { request = request.filter(Column("state") == state.rawValue) }
            return try request.order(Column("updatedAt")).fetchAll(db).compactMap(\.model)
        }
    }

    /// Relative path of a finished download, for the playback resolver.
    public func completedDownloadPath(_ trackID: ItemID) throws -> String? {
        try db.read { db in
            try String.fetchOne(db, sql: "SELECT relativePath FROM download WHERE trackID = ? AND state = ?",
                                arguments: [trackID.description, DownloadState.done.rawValue])
        }
    }

    public func updateDownload(_ trackID: ItemID, _ update: DownloadUpdate) throws {
        try db.write { db in
            guard var record = try DownloadRecord.fetchOne(db, key: trackID.description) else { return }
            switch update {
            case .started:
                record.state = DownloadState.downloading.rawValue
                record.error = nil
                record.retryAfter = nil
            case .progress(let bytes, let total):
                record.bytes = bytes
                record.totalBytes = total
            case .finished(let bytes):
                record.state = DownloadState.done.rawValue
                record.bytes = bytes
                record.totalBytes = bytes
                record.error = nil
                record.retryAfter = nil
            case .failed(let message, let attempts, let retryAfter):
                record.state = (retryAfter == nil ? DownloadState.failed : .queued).rawValue
                record.error = message
                record.attempts = attempts
                record.retryAfter = retryAfter
                record.bytes = 0
            }
            record.updatedAt = Date()
            try record.update(db)
        }
    }

    /// Downloads cut off by the app quitting go back to the queue, except those whose transfer
    /// is still running in a background session (`stillRunning` holds their track IDs).
    public func resetInterruptedDownloads(except stillRunning: Set<String> = []) throws {
        _ = try db.write { db in
            try DownloadRecord
                .filter(Column("state") == DownloadState.downloading.rawValue && !stillRunning.contains(Column("trackID")))
                .updateAll(db, Column("state").set(to: DownloadState.queued.rawValue), Column("bytes").set(to: 0))
        }
    }

    /// Re-queues permanently failed downloads with a fresh retry budget.
    public func retryFailedDownloads() throws {
        try db.write { db in
            try db.execute(sql: "UPDATE download SET state = ?, attempts = 0, retryAfter = NULL, error = NULL WHERE state = ?",
                           arguments: [DownloadState.queued.rawValue, DownloadState.failed.rawValue])
        }
    }

    private static let progressSQL = """
        SELECT COUNT(*) AS total,
               COALESCE(SUM(d.state = 'done'), 0) AS done,
               COALESCE(SUM(d.state = 'failed'), 0) AS failed,
               COALESCE(SUM(d.state = 'downloading'), 0) AS downloading,
               COALESCE(SUM(d.bytes), 0) AS bytes
        FROM pinTrack p JOIN download d ON d.trackID = p.trackID
        WHERE p.ownerKind = ? AND p.ownerID = ?
        """

    private static func progress(_ db: Database, _ owner: PinOwner) throws -> PinProgress? {
        let args: StatementArguments = [owner.kind, owner.itemID.description]
        guard try PinRecord.fetchOne(db, key: ["ownerKind": owner.kind, "ownerID": owner.itemID.description]) != nil,
              let row = try Row.fetchOne(db, sql: progressSQL, arguments: args) else { return nil }
        return PinProgress(total: row["total"], done: row["done"], failed: row["failed"],
                           downloading: row["downloading"], bytes: row["bytes"])
    }

    /// nil when the owner isn't pinned.
    public func pinProgress(_ owner: PinOwner) throws -> PinProgress? {
        try db.read { db in try Self.progress(db, owner) }
    }

    public func observePinProgress(_ owner: PinOwner) -> AsyncStream<PinProgress?> {
        observe { db in try Self.progress(db, owner) }
    }

    public struct DownloadStats: Hashable, Sendable {
        public var files: Int
        public var bytes: Int64
        public var pending: Int
        public var failed: Int
    }

    private static func stats(_ db: Database) throws -> DownloadStats {
        let row = try Row.fetchOne(db, sql: """
            SELECT COALESCE(SUM(state = 'done'), 0) AS files,
                   COALESCE(SUM(CASE WHEN state = 'done' THEN bytes ELSE 0 END), 0) AS bytes,
                   COALESCE(SUM(state IN ('queued', 'downloading')), 0) AS pending,
                   COALESCE(SUM(state = 'failed'), 0) AS failed
            FROM download
            """)!
        return DownloadStats(files: row["files"], bytes: row["bytes"], pending: row["pending"], failed: row["failed"])
    }

    public func downloadStats() throws -> DownloadStats { try db.read { db in try Self.stats(db) } }
    public func observeDownloadStats() -> AsyncStream<DownloadStats> { observe { db in try Self.stats(db) } }

    /// Clears every pin and download row. Returns the relative paths whose files should be deleted.
    @discardableResult
    public func deleteAllDownloads() throws -> [String] {
        try db.write { db in
            let paths = try String.fetchAll(db, sql: "SELECT relativePath FROM download")
            try DownloadRecord.deleteAll(db)
            try PinTrackRecord.deleteAll(db)
            try PinRecord.deleteAll(db)
            return paths
        }
    }

    // `tracks(ids:)` (order-preserving, offline) lives in DiscoveryQueries.swift.
}
