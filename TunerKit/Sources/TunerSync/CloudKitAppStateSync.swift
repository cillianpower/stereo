import CloudKit
import Foundation
import os
import TunerStore

/// iCloud sync of app-owned state with `CKSyncEngine`, in a custom zone of the private database.
///
/// Thin by design: every merge decision lives in `SyncCoordinator`. This class owns the engine,
/// persists its state serialization, feeds it the store's pending changes, and reports status.
/// It degrades to `.unavailable` (never crashes) when the build has no iCloud entitlement.
public final class CloudKitAppStateSync: AppStateSync, CKSyncEngineDelegate, @unchecked Sendable {
    static let engineStateKey = "ckSyncEngine.state"
    static let zoneCreatedKey = "ckSyncEngine.zoneCreated"

    private struct State {
        var status: SyncStatus = .notStarted
        var engine: CKSyncEngine?
        var container: CKContainer?
        var continuations: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]
        var enqueued: Set<SyncCoordinator.PendingRecord> = []
        var observeTask: Task<Void, Never>?
        var accountObserver: NSObjectProtocol?
        var lastSync: Date?
    }

    public let containerIdentifier: String
    public let coordinator: SyncCoordinator
    private let store: LibraryStore
    // CK types aren't all Sendable; every access goes through this lock.
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let log = Logger(subsystem: "app.tuner", category: "cloudkit")

    private let entitlements: Entitlements

    public init(containerIdentifier: String, store: LibraryStore, entitlements: Entitlements = .current) {
        self.containerIdentifier = containerIdentifier
        self.store = store
        self.entitlements = entitlements
        self.coordinator = SyncCoordinator(store: store)
    }

    // MARK: AppStateSync

    public var status: SyncStatus { state.withLock { $0.status } }

    public func statusUpdates() -> AsyncStream<SyncStatus> {
        let id = UUID()
        return AsyncStream { continuation in
            let current = state.withLock { s in
                s.continuations[id] = continuation
                return s.status
            }
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) }
            }
        }
    }

    public func start() async {
        guard state.withLock({ $0.engine == nil }) else { return }

        // CKContainer traps (uncatchably) without the entitlement, so check before touching it.
        guard entitlements.allowsCloudKit(container: containerIdentifier) else {
            setStatus(.unavailable(reason: "this build isn't signed with iCloud"))
            log.info("CloudKit unavailable: no entitlement for \(self.containerIdentifier)")
            return
        }
        let container = CKContainer(identifier: containerIdentifier)
        state.withLock { $0.container = container }
        observeAccountChanges()

        do {
            switch try await container.accountStatus() {
            case .available: break
            case .noAccount, .restricted, .temporarilyUnavailable:
                setStatus(.noAccount)
                return
            case .couldNotDetermine:
                setStatus(.failed(message: "couldn't check the iCloud account"))
                return
            @unknown default:
                setStatus(.noAccount)
                return
            }
        } catch {
            setStatus(.unavailable(reason: error.localizedDescription))
            return
        }

        let serialization = (try? store.syncBlob(Self.engineStateKey))
            .flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        let config = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                                                stateSerialization: serialization, delegate: self)
        let engine = CKSyncEngine(config)
        state.withLock { $0.engine = engine }

        if (try? store.syncBlob(Self.zoneCreatedKey)) == nil {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: coordinator.zoneID))])
        }
        enqueueLocalChanges()
        observeLocalChanges()
        setStatus(.upToDate(lastSync: nil))
    }

    public func stop() async {
        let (task, observer) = state.withLockUnchecked { s -> (Task<Void, Never>?, NSObjectProtocol?) in
            defer { s.engine = nil; s.observeTask = nil; s.accountObserver = nil; s.enqueued = [] }
            return (s.observeTask, s.accountObserver)
        }
        task?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        setStatus(.notStarted)
    }

    public func pushPending() async {
        guard let engine = state.withLock({ $0.engine }) else { return }
        enqueueLocalChanges()
        do { try await engine.sendChanges() } catch { report(error) }
    }

    public func pull() async {
        guard let engine = state.withLock({ $0.engine }) else { return }
        do { try await engine.fetchChanges() } catch { report(error) }
    }

    // MARK: Local changes → engine

    private func observeLocalChanges() {
        let stream = store.observePendingSyncCount()
        let task = Task { [weak self] in
            for await _ in stream { self?.enqueueLocalChanges() }
        }
        state.withLock { $0.observeTask = task }
    }

    /// Hands any not-yet-enqueued pending rows to the engine, which schedules the upload.
    private func enqueueLocalChanges() {
        guard let pending = try? coordinator.pendingRecords() else { return }
        let (engine, fresh) = state.withLock { s -> (CKSyncEngine?, [SyncCoordinator.PendingRecord]) in
            let fresh = pending.filter { !s.enqueued.contains($0) }
            s.enqueued = Set(pending)
            return (s.engine, fresh)
        }
        guard let engine, !fresh.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: fresh.map {
            $0.isDelete ? .deleteRecord($0.recordID) : .saveRecord($0.recordID)
        })
    }

    private func requeue(_ names: [SyncRecordName], engine: CKSyncEngine) {
        guard !names.isEmpty else { return }
        for name in names { try? store.markPendingSync(name) }
        engine.state.add(pendingRecordZoneChanges: names.map { .saveRecord(RecordCodec.recordID(for: $0, zoneID: coordinator.zoneID)) })
    }

    // MARK: CKSyncEngineDelegate

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        do {
            switch event {
            case .stateUpdate(let update):
                try store.setSyncBlob(try JSONEncoder().encode(update.stateSerialization), for: Self.engineStateKey)

            case .accountChange(let change):
                switch change.changeType {
                case .signIn: try coordinator.handleAccountChange(.signIn)
                case .signOut:
                    try coordinator.handleAccountChange(.signOut)
                    setStatus(.noAccount)
                case .switchAccounts: try coordinator.handleAccountChange(.switchAccounts)
                @unknown default: break
                }
                state.withLock { $0.enqueued = [] }
                enqueueLocalChanges()

            case .fetchedDatabaseChanges(let changes):
                for deletion in changes.deletions where deletion.zoneID == coordinator.zoneID {
                    let reason: SyncCoordinator.ZoneDeletionReason = switch deletion.reason {
                    case .purged: .purged
                    case .encryptedDataReset: .encryptedDataReset
                    default: .deleted
                    }
                    try coordinator.handleZoneDeleted(reason)
                    state.withLock { $0.enqueued = [] }
                    if reason == .encryptedDataReset {
                        syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: coordinator.zoneID))])
                        enqueueLocalChanges()
                    }
                }

            case .fetchedRecordZoneChanges(let changes):
                let resend = try coordinator.handleFetched(
                    modifications: changes.modifications.map(\.record),
                    deletions: changes.deletions.map(\.recordID)
                )
                requeue(resend, engine: syncEngine)

            case .sentDatabaseChanges(let sent):
                if sent.savedZones.contains(where: { $0.zoneID == coordinator.zoneID }) {
                    try store.setSyncBlob(Data([1]), for: Self.zoneCreatedKey)
                }
                for failure in sent.failedZoneSaves { report(failure.error) }

            case .sentRecordZoneChanges(let sent):
                let result = try coordinator.handleSent(
                    saved: sent.savedRecords,
                    failedSaves: sent.failedRecordSaves.map { ($0.record, $0.error) },
                    deleted: sent.deletedRecordIDs,
                    failedDeletes: sent.failedRecordDeletes.map { ($0.key, $0.value) }
                )
                if result.needsZone {
                    try store.setSyncBlob(nil, for: Self.zoneCreatedKey)
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: coordinator.zoneID))])
                }
                requeue(result.resend, engine: syncEngine)
                // Drop confirmed rows from the "already enqueued" set so a later edit enqueues again.
                let remaining = Set((try? coordinator.pendingRecords()) ?? [])
                state.withLock { $0.enqueued.formIntersection(remaining) }
                if let first = result.failures.first { setStatus(.failed(message: first)) }

            case .willFetchChanges, .willSendChanges:
                setStatus(.syncing)

            case .didFetchChanges, .didSendChanges:
                let now = Date()
                state.withLock { $0.lastSync = now }
                if case .failed = status {} else { setStatus(.upToDate(lastSync: now)) }

            default:
                break
            }
        } catch {
            log.error("sync event failed: \(error.localizedDescription)")
            setStatus(.failed(message: error.localizedDescription))
        }
    }

    public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                          syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !changes.isEmpty else { return nil }
        let coordinator = self.coordinator
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
            if let record = try? coordinator.recordToSend(recordID) { return record }
            // Row is gone locally (or unreadable): stop trying to save it.
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return nil
        }
    }

    // MARK: Status

    private func observeAccountChanges() {
        guard state.withLock({ $0.accountObserver == nil }) else { return }
        let observer = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            Task {
                // Signing in from Settings while Tuner runs: start the engine now.
                if self.state.withLock({ $0.engine == nil }) { await self.start() }
            }
        }
        state.withLockUnchecked { $0.accountObserver = observer }
    }

    private func report(_ error: Error) {
        let ck = error as? CKError
        switch ck?.code {
        case .notAuthenticated?: setStatus(.noAccount)
        case .networkFailure?, .networkUnavailable?: break   // retried automatically; don't alarm
        case .quotaExceeded?: setStatus(.failed(message: "iCloud storage is full"))
        default: setStatus(.failed(message: error.localizedDescription))
        }
    }

    private func setStatus(_ new: SyncStatus) {
        let continuations = state.withLock { s -> [AsyncStream<SyncStatus>.Continuation] in
            guard s.status != new else { return [] }
            s.status = new
            return Array(s.continuations.values)
        }
        for c in continuations { c.yield(new) }
    }
}
