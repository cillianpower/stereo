import CloudKit
import Foundation
import os
import StereoStore

/// The CloudKit-independent heart of sync: decides what to upload and how to merge what comes
/// back. `CloudKitAppStateSync` forwards `CKSyncEngine` callbacks here; tests drive it directly
/// with hand-built `CKRecord`s and `CKError`s, no iCloud needed.
public final class SyncCoordinator: Sendable {
    public enum AccountChange: Sendable { case signIn, signOut, switchAccounts }
    public enum ZoneDeletionReason: Sendable { case deleted, purged, encryptedDataReset }

    public struct SendResult: Equatable, Sendable {
        /// Records to queue again (conflict resolved in our favour, stale change tag, missing zone).
        public var resend: [SyncRecordName] = []
        /// The zone has to be (re)created before anything else can be saved.
        public var needsZone = false
        /// Errors worth surfacing (quota, permissions). Transient ones are retried by the engine.
        public var failures: [String] = []
    }

    public let store: LibraryStore
    public let zoneID: CKRecordZone.ID
    private let log = Logger(subsystem: "app.stereo", category: "sync")
    /// When each record was last handed to the engine, so a confirmation only clears a pending
    /// change that wasn't edited again while the upload was in flight.
    private let builtAt = OSAllocatedUnfairLock<[SyncRecordName: Date]>(initialState: [:])

    public init(store: LibraryStore, zoneID: CKRecordZone.ID = RecordCodec.defaultZoneID) {
        self.store = store
        self.zoneID = zoneID
    }

    // MARK: Outgoing

    public struct PendingRecord: Hashable, Sendable {
        public var recordID: CKRecord.ID
        public var isDelete: Bool
    }

    public func pendingRecords() throws -> [PendingRecord] {
        try store.pendingSyncChanges().map {
            PendingRecord(recordID: RecordCodec.recordID(for: $0.name, zoneID: zoneID), isDelete: $0.kind == .delete)
        }
    }

    /// The record to upload for a pending save, or nil if the row no longer exists locally
    /// (the caller then drops the pending save).
    public func recordToSend(_ recordID: CKRecord.ID, now: Date = Date()) throws -> CKRecord? {
        guard let name = RecordCodec.name(of: recordID) else { return nil }
        guard let item = try store.syncItem(named: name) else {
            try store.clearPendingSync([name])
            return nil
        }
        builtAt.withLock { $0[name] = now }
        return RecordCodec.record(for: item, zoneID: zoneID, systemFields: try store.syncSystemFields(name))
    }

    public func handleSent(
        saved: [CKRecord],
        failedSaves: [(record: CKRecord, error: CKError)],
        deleted: [CKRecord.ID],
        failedDeletes: [(recordID: CKRecord.ID, error: CKError)]
    ) throws -> SendResult {
        var result = SendResult()

        for record in saved {
            guard let name = RecordCodec.name(of: record.recordID) else { continue }
            try store.setSyncSystemFields(RecordCodec.encodeSystemFields(record), for: name)
            let at = builtAt.withLock { $0.removeValue(forKey: name) }
            try store.clearPendingSync([name], changedNoLaterThan: at ?? Date())
        }

        for (record, error) in failedSaves {
            guard let name = RecordCodec.name(of: record.recordID) else { continue }
            switch error.code {
            case .serverRecordChanged:
                // Someone else wrote first. Last writer (by modifiedAt) wins.
                guard let server = error.serverRecord else { result.resend.append(name); continue }
                try store.setSyncSystemFields(RecordCodec.encodeSystemFields(server), for: name)
                if let serverItem = RecordCodec.item(from: server), try store.applyRemoteSave(serverItem) == .appliedRemote {
                    builtAt.withLock { _ = $0.removeValue(forKey: name) }
                } else {
                    result.resend.append(name)   // ours is newer: retry on top of the server's change tag
                }
            case .zoneNotFound, .userDeletedZone:
                result.needsZone = true
                try store.setSyncSystemFields(nil, for: name)
                result.resend.append(name)
            case .unknownItem:
                // The server record vanished, so our change tag is stale: upload as a new record.
                try store.setSyncSystemFields(nil, for: name)
                result.resend.append(name)
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
                 .requestRateLimited, .notAuthenticated, .operationCancelled, .accountTemporarilyUnavailable:
                break   // CKSyncEngine keeps the pending change and retries on its own schedule.
            default:
                log.error("save failed \(name.description): \(error.localizedDescription)")
                result.failures.append(error.localizedDescription)
            }
        }

        for recordID in deleted { try confirmDeleted(recordID) }
        for (recordID, error) in failedDeletes {
            if error.code == .unknownItem { try confirmDeleted(recordID) }   // already gone: same outcome
            else if ![.networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited].contains(error.code) {
                result.failures.append(error.localizedDescription)
            }
        }
        return result
    }

    private func confirmDeleted(_ recordID: CKRecord.ID) throws {
        guard let name = RecordCodec.name(of: recordID) else { return }
        try store.setSyncSystemFields(nil, for: name)
        // Only clear the tombstone; if the row was re-created since, its pending save stays.
        let pending = try store.pendingSyncChanges().first { $0.name == name }
        if pending?.kind == .delete { try store.clearPendingSync([name]) }
    }

    // MARK: Incoming

    /// Merges fetched changes. Returns records that must go back up because the local copy won.
    public func handleFetched(modifications: [CKRecord], deletions: [CKRecord.ID]) throws -> [SyncRecordName] {
        var resend: [SyncRecordName] = []
        for record in modifications {
            guard let name = RecordCodec.name(of: record.recordID) else { continue }
            guard let item = RecordCodec.item(from: record) else {
                log.info("skipping undecodable record \(record.recordID.recordName)")
                continue
            }
            // Always keep the newest system fields so our next write carries the right change tag.
            try store.setSyncSystemFields(RecordCodec.encodeSystemFields(record), for: name)
            switch try store.applyRemoteSave(item) {
            case .appliedRemote: break
            case .keptLocal, .keptLocalDelete: resend.append(name)
            }
        }
        for recordID in deletions {
            guard let name = RecordCodec.name(of: recordID) else { continue }
            if try store.applyRemoteDelete(name) == .keptLocal {
                try store.setSyncSystemFields(nil, for: name)   // record no longer exists on the server
                resend.append(name)
            }
        }
        return resend
    }

    // MARK: Lifecycle events

    public func handleAccountChange(_ change: AccountChange) throws {
        switch change {
        case .signIn:
            try store.enqueueAllForSync()              // first sign-in: upload what this device has
        case .signOut:
            try store.resetSyncMetadata(reenqueueAll: false)   // keep local data, forget the old account
        case .switchAccounts:
            try store.resetSyncMetadata(reenqueueAll: true)
        }
        builtAt.withLock { $0.removeAll() }
    }

    /// Our zone was removed on the server. A deliberate delete or purge ("Delete data" in iCloud
    /// settings) is respected: nothing is re-uploaded until the next local edit. An encrypted-data
    /// reset loses server data the user didn't choose to lose, so everything goes back up.
    public func handleZoneDeleted(_ reason: ZoneDeletionReason) throws {
        try store.resetSyncMetadata(reenqueueAll: reason == .encryptedDataReset)
        builtAt.withLock { $0.removeAll() }
    }
}
