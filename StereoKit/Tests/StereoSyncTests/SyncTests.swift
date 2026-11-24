import CloudKit
import Foundation
import Testing
import StereoModel
@testable import StereoStore
@testable import StereoSync

private func station(_ n: Int, name: String? = nil) -> Station {
    Station(origin: .radioBrowser(uuid: "uuid-\(n)"), name: name ?? "Station \(n)",
            streamURL: URL(string: "https://s\(n).example/stream")!, codec: "MP3", bitRate: 128, tags: ["jazz"])
}

private func synced(_ s: Station, favorite: Bool = true, modified: Date) -> SyncItem {
    .station(SyncedStation(station: s, isFavorite: favorite, isCustom: false, sortIndex: 1,
                           addedAt: modified, lastPlayedAt: nil, modifiedAt: modified))
}

private func localModifiedAt(_ store: LibraryStore, _ s: Station) throws -> Date? {
    guard case .station(let local)? = try store.syncItem(named: .station(s.id)) else { return nil }
    return local.modifiedAt
}

// MARK: Store change tracking

@Suite struct SyncStoreTests {
    @Test func localEditsAreQueuedByTriggers() throws {
        let store = try LibraryStore.inMemory()
        try store.setFavorite(true, station: station(1))
        try store.markPlayed(station(2))
        let names = try store.pendingSyncChanges().map(\.name.description).sorted()
        #expect(names == ["st-rb:uuid-1", "st-rb:uuid-2"])
        #expect(try store.pendingSyncChanges().allSatisfy { $0.kind == .save })
    }

    @Test func identifiedSongsAreQueuedByHexName() throws {
        let store = try LibraryStore.inMemory()
        // Whole-second date: SQLite stores milliseconds, so sub-ms precision wouldn't round-trip.
        let song = IdentifiedSong(title: "Roygbiv", artist: "Boards of Canada", artworkURL: nil, stationName: "KEXP",
                                  identifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.addIdentified(song)
        let pending = try #require(try store.pendingSyncChanges().first)
        #expect(pending.name == .identifiedSong(song.id))
        #expect(pending.name.localID.count == 32)
        #expect(try store.syncItem(named: pending.name) == .identifiedSong(song))
    }

    @Test func deleteLeavesTombstone() throws {
        let store = try LibraryStore.inMemory()
        let s = station(1)
        try store.setFavorite(true, station: s)
        try store.deleteStation(s)
        let pending = try store.pendingSyncChanges()
        #expect(pending.count == 1)
        #expect(pending[0].kind == .delete)
        #expect(try store.syncItem(named: .station(s.id)) == nil)
    }

    @Test func remoteChangesDoNotEcho() throws {
        let store = try LibraryStore.inMemory()
        #expect(try store.applyRemoteSave(synced(station(1), modified: Date())) == .appliedRemote)
        #expect(try store.favoriteStations().map(\.name) == ["Station 1"])
        #expect(try store.pendingSyncChanges().isEmpty)
        #expect(try store.applyRemoteDelete(.station(station(1).id)) == .appliedRemote)
        #expect(try store.favoriteStations().isEmpty)
        #expect(try store.pendingSyncChanges().isEmpty)
    }

    @Test func lastWriterWins() throws {
        let store = try LibraryStore.inMemory()
        let s = station(1)
        try store.setFavorite(true, station: s)   // local pending save, modifiedAt ≈ now
        let local = try #require(try localModifiedAt(store, s))

        // Older remote loses; local stays pending.
        #expect(try store.applyRemoteSave(synced(s, favorite: false, modified: local.addingTimeInterval(-60))) == .keptLocal)
        #expect(try store.isFavorite(s))
        #expect(try store.pendingSyncChanges().count == 1)

        // Newer remote wins and clears the pending change.
        #expect(try store.applyRemoteSave(synced(s, favorite: false, modified: local.addingTimeInterval(60))) == .appliedRemote)
        #expect(try !store.isFavorite(s))
        #expect(try store.pendingSyncChanges().isEmpty)
    }

    @Test func tieGoesToRemote() throws {
        let store = try LibraryStore.inMemory()
        let s = station(1)
        try store.setFavorite(true, station: s)
        let local = try #require(try localModifiedAt(store, s))
        #expect(try store.applyRemoteSave(synced(s, favorite: false, modified: local)) == .appliedRemote)
    }

    @Test func tombstoneBeatsOlderSaveButNotNewer() throws {
        let store = try LibraryStore.inMemory()
        let s = station(1)
        try store.setFavorite(true, station: s)
        try store.deleteStation(s)
        let deletedAt = try #require(try store.pendingSyncChanges().first?.changedAt)

        #expect(try store.applyRemoteSave(synced(s, modified: deletedAt.addingTimeInterval(-10))) == .keptLocalDelete)
        #expect(try store.favoriteStations().isEmpty)
        #expect(try store.pendingSyncChanges().first?.kind == .delete)

        // Edited elsewhere after our delete: it comes back.
        #expect(try store.applyRemoteSave(synced(s, modified: deletedAt.addingTimeInterval(10))) == .appliedRemote)
        #expect(try store.favoriteStations().count == 1)
        #expect(try store.pendingSyncChanges().isEmpty)
    }

    @Test func remoteDeleteLosesToPendingSave() throws {
        let store = try LibraryStore.inMemory()
        let s = station(1)
        try store.setFavorite(true, station: s)
        #expect(try store.applyRemoteDelete(.station(s.id)) == .keptLocal)
        #expect(try store.favoriteStations().count == 1)
    }

    @Test func confirmationKeepsEditsMadeInFlight() throws {
        let store = try LibraryStore.inMemory()
        let s = station(1)
        try store.setFavorite(true, station: s)
        let sentAt = Date()
        Thread.sleep(forTimeInterval: 0.01)
        try store.markPlayed(s)                     // edited while the upload was in flight
        try store.clearPendingSync([.station(s.id)], changedNoLaterThan: sentAt)
        #expect(try store.pendingSyncChanges().count == 1)
        try store.clearPendingSync([.station(s.id)], changedNoLaterThan: Date())
        #expect(try store.pendingSyncChanges().isEmpty)
    }

    @Test func resetAndReenqueue() throws {
        let store = try LibraryStore.inMemory()
        try store.applyRemoteSave(synced(station(1), modified: Date()))
        try store.applyRemoteSave(.identifiedSong(IdentifiedSong(title: "t", artist: nil, artworkURL: nil, stationName: nil)))
        try store.setSyncSystemFields(Data([1, 2, 3]), for: .station(station(1).id))
        try store.resetSyncMetadata(reenqueueAll: true)
        #expect(try store.pendingSyncChanges().count == 2)
        #expect(try store.syncSystemFields(.station(station(1).id)) == nil)
    }
}

// MARK: Record codec

@Suite struct RecordCodecTests {
    @Test func stationRoundTrip() throws {
        let item = synced(station(7, name: "Radio Paradise"), modified: Date(timeIntervalSince1970: 1_700_000_000))
        let record = RecordCodec.record(for: item)
        #expect(record.recordType == "Station")
        #expect(record.recordID.recordName == "st-rb:uuid-7")
        #expect(record.recordID.zoneID.zoneName == "StereoState")
        #expect(record["name"] as? String == "Radio Paradise")
        #expect(RecordCodec.item(from: record) == item)
    }

    @Test func identifiedSongRoundTrip() throws {
        var song = IdentifiedSong(title: "Jóga", artist: "Björk", artworkURL: URL(string: "https://a.example/x.jpg"),
                                  stationName: "BBC 6", identifiedAt: Date(timeIntervalSince1970: 1_700_000_123))
        song.libraryTrackID = "nav:s-1"
        let record = RecordCodec.record(for: .identifiedSong(song))
        #expect(record.recordType == "IdentifiedSong")
        #expect(RecordCodec.item(from: record) == .identifiedSong(song))
    }

    @Test func rejectsNewerSchemaAndMismatchedTypes() {
        let record = RecordCodec.record(for: synced(station(1), modified: Date()))
        record["schema"] = 99 as Int64
        #expect(RecordCodec.item(from: record) == nil)

        let wrong = CKRecord(recordType: "IdentifiedSong", recordID: RecordCodec.recordID(for: .station("rb:x")))
        #expect(RecordCodec.item(from: wrong) == nil)
    }

    @Test func systemFieldsRoundTrip() throws {
        let record = RecordCodec.record(for: synced(station(1), modified: Date()))
        let data = RecordCodec.encodeSystemFields(record)
        let restored = try #require(RecordCodec.decodeSystemFields(data))
        #expect(restored.recordID == record.recordID)
        #expect(restored.recordType == record.recordType)
        // Building from stored system fields reuses them (the change tag rides along).
        let rebuilt = RecordCodec.record(for: synced(station(1), favorite: false, modified: Date()), systemFields: data)
        #expect(rebuilt.recordID == record.recordID)
        #expect(rebuilt["isFavorite"] as? Int64 == 0)
    }
}

// MARK: Coordinator (CKSyncEngine callbacks, without iCloud)

@Suite struct SyncCoordinatorTests {
    let zone = RecordCodec.defaultZoneID

    @Test func pendingAndRecordToSend() throws {
        let store = try LibraryStore.inMemory()
        let c = SyncCoordinator(store: store)
        try store.setFavorite(true, station: station(1))
        try store.setFavorite(true, station: station(2))
        try store.deleteStation(station(2))
        let pending = try c.pendingRecords()
        #expect(pending.count == 2)
        #expect(pending.contains { $0.recordID.recordName == "st-rb:uuid-2" && $0.isDelete })

        let record = try #require(try c.recordToSend(RecordCodec.recordID(for: .station(station(1).id))))
        #expect(record["isFavorite"] as? Int64 == 1)
        // Missing row: nothing to send, and its stale pending save is dropped.
        try store.markPendingSync(.station("rb:ghost"))
        #expect(try c.recordToSend(RecordCodec.recordID(for: .station("rb:ghost"))) == nil)
        #expect(try !store.pendingSyncChanges().contains { $0.name.localID == "rb:ghost" })
    }

    @Test func savedRecordsClearPendingAndStoreChangeTag() throws {
        let store = try LibraryStore.inMemory()
        let c = SyncCoordinator(store: store)
        try store.setFavorite(true, station: station(1))
        let record = try #require(try c.recordToSend(RecordCodec.recordID(for: .station(station(1).id))))
        let result = try c.handleSent(saved: [record], failedSaves: [], deleted: [], failedDeletes: [])
        #expect(result == .init())
        #expect(try store.pendingSyncChanges().isEmpty)
        #expect(try store.syncSystemFields(.station(station(1).id)) != nil)
    }

    @Test func conflictWithNewerServerCopyAdoptsIt() throws {
        let store = try LibraryStore.inMemory()
        let c = SyncCoordinator(store: store)
        let s = station(1)
        try store.setFavorite(true, station: s)
        let ours = try #require(try c.recordToSend(RecordCodec.recordID(for: .station(s.id))))
        let server = RecordCodec.record(for: synced(s, favorite: false, modified: Date().addingTimeInterval(120)))
        let error = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])

        let result = try c.handleSent(saved: [], failedSaves: [(ours, error)], deleted: [], failedDeletes: [])
        #expect(result.resend.isEmpty)
        #expect(try !store.isFavorite(s))
        #expect(try store.pendingSyncChanges().isEmpty)
    }

    @Test func conflictWithOlderServerCopyResends() throws {
        let store = try LibraryStore.inMemory()
        let c = SyncCoordinator(store: store)
        let s = station(1)
        try store.setFavorite(true, station: s)
        let ours = try #require(try c.recordToSend(RecordCodec.recordID(for: .station(s.id))))
        let server = RecordCodec.record(for: synced(s, favorite: false, modified: Date().addingTimeInterval(-3600)))
        let error = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])

        let result = try c.handleSent(saved: [], failedSaves: [(ours, error)], deleted: [], failedDeletes: [])
        #expect(result.resend == [.station(s.id)])
        #expect(try store.isFavorite(s))
        // Server change tag kept, so the retry is built on top of it.
        #expect(try store.syncSystemFields(.station(s.id)) != nil)
    }

    @Test func missingZoneAndUnknownItem() throws {
        let store = try LibraryStore.inMemory()
        let c = SyncCoordinator(store: store)
        try store.setFavorite(true, station: station(1))
        try store.setFavorite(true, station: station(2))
        let r1 = try #require(try c.recordToSend(RecordCodec.recordID(for: .station(station(1).id))))
        let r2 = try #require(try c.recordToSend(RecordCodec.recordID(for: .station(station(2).id))))
        try store.setSyncSystemFields(Data([9]), for: .station(station(2).id))

        let result = try c.handleSent(saved: [], failedSaves: [(r1, CKError(.zoneNotFound)), (r2, CKError(.unknownItem))],
                                      deleted: [], failedDeletes: [])
        #expect(result.needsZone)
        #expect(Set(result.resend) == [.station(station(1).id), .station(station(2).id)])
        #expect(try store.syncSystemFields(.station(station(2).id)) == nil)
    }

    @Test func transientErrorsAreLeftToTheEngineAndQuotaIsReported() throws {
        let store = try LibraryStore.inMemory()
        let c = SyncCoordinator(store: store)
        try store.setFavorite(true, station: station(1))
        let r = try #require(try c.recordToSend(RecordCodec.recordID(for: .station(station(1).id))))
        let transient = try c.handleSent(saved: [], failedSaves: [(r, CKError(.networkFailure))], deleted: [], failedDeletes: [])
        #expect(transient == .init())
        #expect(try store.pendingSyncChanges().count == 1)
        let quota = try c.handleSent(saved: [], failedSaves: [(r, CKError(.quotaExceeded))], deleted: [], failedDeletes: [])
        #expect(quota.failures.count == 1)
    }

    @Test func confirmedDeletesClearTombstones() throws {
        let store = try LibraryStore.inMemory()
        let c = SyncCoordinator(store: store)
        try store.setFavorite(true, station: station(1))
        try store.setFavorite(true, station: station(2))
        try store.clearPendingSync([.station(station(1).id), .station(station(2).id)])
        try store.deleteStation(station(1))
        try store.deleteStation(station(2))
        _ = try c.handleSent(saved: [], failedSaves: [],
                             deleted: [RecordCodec.recordID(for: .station(station(1).id))],
                             failedDeletes: [(RecordCodec.recordID(for: .station(station(2).id)), CKError(.unknownItem))])
        #expect(try store.pendingSyncChanges().isEmpty)
    }

    @Test func fetchedChangesMerge() throws {
        let store = try LibraryStore.inMemory()
        let c = SyncCoordinator(store: store)
        let mine = station(1), theirs = station(2), gone = station(3)
        try store.setFavorite(true, station: mine)          // pending, newer than the server copy below
        try store.applyRemoteSave(synced(gone, modified: Date()))

        let resend = try c.handleFetched(
            modifications: [
                RecordCodec.record(for: synced(mine, favorite: false, modified: Date().addingTimeInterval(-600))),
                RecordCodec.record(for: synced(theirs, modified: Date())),
            ],
            deletions: [RecordCodec.recordID(for: .station(gone.id))]
        )
        #expect(resend == [.station(mine.id)])
        #expect(Set(try store.favoriteStations().map(\.id)) == [mine.id, theirs.id])
        #expect(try store.syncSystemFields(.station(theirs.id)) != nil)
    }

    @Test func accountAndZoneLifecycle() throws {
        let store = try LibraryStore.inMemory()
        let c = SyncCoordinator(store: store)
        try store.applyRemoteSave(synced(station(1), modified: Date()))
        try store.setSyncSystemFields(Data([1]), for: .station(station(1).id))

        try c.handleZoneDeleted(.purged)
        #expect(try store.pendingSyncChanges().isEmpty)          // a deliberate purge isn't undone
        #expect(try store.syncSystemFields(.station(station(1).id)) == nil)
        #expect(try store.favoriteStations().count == 1)          // local data stays

        try c.handleZoneDeleted(.encryptedDataReset)
        #expect(try store.pendingSyncChanges().count == 1)

        try c.handleAccountChange(.signOut)
        #expect(try store.pendingSyncChanges().isEmpty)
        try c.handleAccountChange(.switchAccounts)
        #expect(try store.pendingSyncChanges().count == 1)
    }
}

// MARK: Degrades without entitlements

@Suite struct CloudKitAvailabilityTests {
    /// The test runner has no iCloud entitlement, exactly like an unsigned dev build.
    @Test func reportsUnavailableInsteadOfCrashing() async throws {
        let sync = CloudKitAppStateSync(containerIdentifier: "iCloud.app.stereo.test", store: try LibraryStore.inMemory())
        await sync.start()
        guard case .unavailable = sync.status else {
            Issue.record("expected .unavailable, got \(sync.status)")
            return
        }
        var updates = sync.statusUpdates().makeAsyncIterator()
        #expect(await updates.next() == sync.status)
        await sync.pushPending()   // no-ops, no crash
        await sync.pull()
    }

    @Test func runningTestProcessHasNoCloudKitEntitlement() {
        #expect(!Entitlements.current.allowsCloudKit(container: "iCloud.app.stereo.test"))
    }

    @Test func entitlementChecks() {
        let e = Entitlements(values: [
            "com.apple.developer.icloud-services": ["CloudKit"],
            "com.apple.developer.icloud-container-identifiers": ["iCloud.com.example.stereo"],
            "com.apple.developer.ubiquity-kvstore-identifier": "TEAM.com.example.stereo",
        ])
        #expect(e.allowsCloudKit(container: "iCloud.com.example.stereo"))
        #expect(!e.allowsCloudKit(container: "iCloud.other"))
        #expect(e.allowsKeyValueStore)
        #expect(!Entitlements(values: [:]).allowsKeyValueStore)
    }

    /// Parses a real signed Mach-O: system apps carry entitlements in their code signature.
    @Test func parsesEntitlementsFromASignedBinary() throws {
        let candidates = ["/System/Applications/Music.app/Contents/MacOS/Music", "/System/Applications/Notes.app/Contents/MacOS/Notes"]
        guard let path = candidates.first(where: FileManager.default.fileExists(atPath:)),
              let data = FileManager.default.contents(atPath: path) else { return }
        let values = try #require(Entitlements.parse(executable: data))
        #expect(!values.isEmpty)
    }
}

// MARK: Settings mirror

final class FakeKeyValueStore: KeyValueStore {
    var values: [String: Any] = [:]
    var syncCount = 0
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
    func synchronize() -> Bool { syncCount += 1; return true }
}

@MainActor
@Suite struct SettingsMirrorTests {
    let keys = ["wifiQuality", "replayGainMode", "replayGainPreamp"]

    func defaults() -> UserDefaults {
        let name = "stereo-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func cloudWinsOnStartAndLocalOnlyKeysGoUp() {
        let d = defaults(), cloud = FakeKeyValueStore(), center = NotificationCenter()
        d.set("aac256", forKey: "wifiQuality")
        d.set(2.0, forKey: "replayGainPreamp")
        cloud.values["wifiQuality"] = "original"
        var reported: [String] = []
        let mirror = SettingsMirror(keys: keys, defaults: d, cloud: cloud, center: center,
                                    externalChangeNotification: .init("ext"), onRemoteChange: { reported += $0 })
        mirror.start()
        #expect(d.string(forKey: "wifiQuality") == "original")
        #expect(cloud.values["replayGainPreamp"] as? Double == 2.0)
        #expect(reported == ["wifiQuality"])
    }

    @Test func localChangesPushAndRemoteChangesApplyWithoutEcho() {
        let d = defaults(), cloud = FakeKeyValueStore(), center = NotificationCenter()
        var reported: [String] = []
        let mirror = SettingsMirror(keys: keys, defaults: d, cloud: cloud, center: center,
                                    externalChangeNotification: .init("ext"), onRemoteChange: { reported += $0 })
        mirror.start()

        d.set("album", forKey: "replayGainMode")
        mirror.pushLocalChanges()
        #expect(cloud.values["replayGainMode"] as? String == "album")

        // Another device changed it.
        cloud.values["replayGainMode"] = "track"
        mirror.handleExternalChange(keys: ["replayGainMode", "someOtherAppKey"], reason: NSUbiquitousKeyValueStoreServerChange)
        #expect(d.string(forKey: "replayGainMode") == "track")
        #expect(reported == ["replayGainMode"])

        // Writing the remote value locally must not push it straight back.
        let before = cloud.syncCount
        mirror.pushLocalChanges()
        #expect(cloud.syncCount == before)
    }

    @Test func externalNotificationIsObserved() async {
        let d = defaults(), cloud = FakeKeyValueStore(), center = NotificationCenter()
        let name = Notification.Name("ext")
        var reported: [String] = []
        let mirror = SettingsMirror(keys: keys, defaults: d, cloud: cloud, center: center,
                                    externalChangeNotification: name, onRemoteChange: { reported += $0 })
        mirror.start()
        cloud.values["wifiQuality"] = "mp3320"
        center.post(name: name, object: cloud, userInfo: [
            NSUbiquitousKeyValueStoreChangedKeysKey: ["wifiQuality"],
            NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreServerChange,
        ])
        // Observer is delivered on the main queue.
        for _ in 0..<20 where reported.isEmpty { await Task.yield(); try? await Task.sleep(for: .milliseconds(5)) }
        #expect(reported == ["wifiQuality"])
        #expect(d.string(forKey: "wifiQuality") == "mp3320")
        mirror.stop()
    }
}
