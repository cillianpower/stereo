import Foundation

/// The subset of `NSUbiquitousKeyValueStore` the mirror uses, so tests can inject a fake.
public protocol KeyValueStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: KeyValueStore {}

/// Mirrors chosen UserDefaults keys through iCloud key-value storage.
///
/// - On start, values already in iCloud win (a new device adopts your settings); keys iCloud
///   doesn't have yet are pushed up from this device.
/// - Local writes (anything that changes UserDefaults) are pushed when they differ from the last
///   value seen, so applying a remote change never echoes back.
/// - Remote changes are written to UserDefaults and reported through `onRemoteChange` so
///   observable settings can reload.
///
/// Without the KVS entitlement `NSUbiquitousKeyValueStore` silently behaves as a local store,
/// so this is safe in unsigned builds.
@MainActor
public final class SettingsMirror {
    public let keys: [String]
    private let defaults: UserDefaults
    private let cloud: KeyValueStore
    private let center: NotificationCenter
    private let externalChange: Notification.Name
    private let onRemoteChange: ([String]) -> Void
    private var lastKnown: [String: Any] = [:]
    private var observers: [NSObjectProtocol] = []

    public init(
        keys: [String],
        defaults: UserDefaults = .standard,
        cloud: KeyValueStore = NSUbiquitousKeyValueStore.default,
        center: NotificationCenter = .default,
        externalChangeNotification: Notification.Name = NSUbiquitousKeyValueStore.didChangeExternallyNotification,
        onRemoteChange: @escaping ([String]) -> Void
    ) {
        self.keys = keys
        self.defaults = defaults
        self.cloud = cloud
        self.center = center
        self.externalChange = externalChangeNotification
        self.onRemoteChange = onRemoteChange
    }

    public func start() {
        guard observers.isEmpty else { return }
        observers.append(center.addObserver(forName: externalChange, object: cloud, queue: .main) { [weak self] note in
            let changed = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            MainActor.assumeIsolated { self?.handleExternalChange(keys: changed, reason: reason) }
        })
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushLocalChanges() }
        })
        cloud.synchronize()
        reconcile()
    }

    public func stop() {
        for o in observers { center.removeObserver(o) }
        observers = []
    }

    /// Initial merge: cloud values win; local-only keys go up.
    func reconcile() {
        var changed: [String] = []
        for key in keys {
            if let remote = cloud.object(forKey: key) {
                if !Self.equal(defaults.object(forKey: key), remote) {
                    defaults.set(remote, forKey: key)
                    changed.append(key)
                }
                lastKnown[key] = remote
            } else if let local = defaults.object(forKey: key) {
                cloud.set(local, forKey: key)
                lastKnown[key] = local
            }
        }
        if !changed.isEmpty { onRemoteChange(changed) }
    }

    func handleExternalChange(keys changedKeys: [String]?, reason: Int?) {
        if reason == NSUbiquitousKeyValueStoreQuotaViolationChange { return }
        if reason == NSUbiquitousKeyValueStoreAccountChange {
            reconcile()
            return
        }
        let relevant = (changedKeys ?? keys).filter(keys.contains)
        var changed: [String] = []
        for key in relevant {
            let remote = cloud.object(forKey: key)
            lastKnown[key] = remote
            guard !Self.equal(defaults.object(forKey: key), remote) else { continue }
            if let remote { defaults.set(remote, forKey: key) } else { defaults.removeObject(forKey: key) }
            changed.append(key)
        }
        if !changed.isEmpty { onRemoteChange(changed) }
    }

    func pushLocalChanges() {
        var pushed = false
        for key in keys {
            let local = defaults.object(forKey: key)
            guard !Self.equal(local, lastKnown[key]) else { continue }
            if let local { cloud.set(local, forKey: key) } else { cloud.removeObject(forKey: key) }
            lastKnown[key] = local
            pushed = true
        }
        if pushed { cloud.synchronize() }
    }

    static func equal(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a as NSObject, b as NSObject): a.isEqual(b)
        default: false
        }
    }
}
