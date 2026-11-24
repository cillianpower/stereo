import Foundation
import StereoSync

/// iCloud sync wiring. Features never call this: they write to `LibraryStore` / `AppSettings`
/// and the store's triggers + the settings mirror pick changes up.
extension AppModel {
    /// Info.plist key holding the CloudKit container (`iCloud.$(STEREO_BUNDLE_PREFIX)`).
    static let cloudContainerInfoKey = "StereoCloudKitContainer"

    func startAppStateSync() {
        let entitlements = Entitlements.current

        // Settings: iCloud key-value store, only when this build is entitled to it.
        if entitlements.allowsKeyValueStore {
            let mirror = SettingsMirror(keys: AppSettings.syncedKeys) { [weak self] _ in
                guard let self else { return }
                self.settings.reload()
                self.applyPlaybackSettings()
            }
            settingsMirror = mirror
            mirror.start()
        }

        // Stations and identified songs: CloudKit.
        let sync: AppStateSync
        if let container = Bundle.main.object(forInfoDictionaryKey: Self.cloudContainerInfoKey) as? String, !container.isEmpty {
            sync = CloudKitAppStateSync(containerIdentifier: container, store: store, entitlements: entitlements)
        } else {
            sync = DisabledAppStateSync(reason: "no iCloud container configured")
        }
        cloudSync = sync

        Task { [weak self] in
            for await status in sync.statusUpdates() { self?.cloudSyncStatus = status }
        }
        Task { await sync.start() }
    }

    /// "Sync Now" in Settings.
    public func syncAppStateNow() async {
        await cloudSync?.pushPending()
        await cloudSync?.pull()
    }
}
