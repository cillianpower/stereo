import Foundation

/// Where app-owned state sync stands. Shown in Settings.
public enum SyncStatus: Equatable, Sendable {
    case notStarted
    /// This build can't use the backend at all (no iCloud entitlement, unsigned dev build…).
    case unavailable(reason: String)
    /// The backend works but the user isn't signed in (or iCloud Drive is off / restricted).
    case noAccount
    case syncing
    case upToDate(lastSync: Date?)
    case failed(message: String)

    public var isUsable: Bool {
        switch self {
        case .syncing, .upToDate, .failed: true
        default: false
        }
    }

    public var summary: String {
        switch self {
        case .notStarted: "Not started"
        case .unavailable(let reason): "Unavailable — \(reason)"
        case .noAccount: "Sign in to iCloud to sync favourites and settings"
        case .syncing: "Syncing…"
        case .upToDate(let date?): "Up to date · \(date.formatted(.relative(presentation: .named)))"
        case .upToDate(nil): "Up to date"
        case .failed(let message): "Sync error — \(message)"
        }
    }
}

/// Syncs app-owned state (radio favourites, custom stations, recents, identified songs) with a
/// backend. iCloud today (`CloudKitAppStateSync`); a self-hosted service can implement this later
/// without touching features, which only ever write to `LibraryStore`.
public protocol AppStateSync: AnyObject, Sendable {
    var status: SyncStatus { get }
    /// Current status first, then every change.
    func statusUpdates() -> AsyncStream<SyncStatus>
    func start() async
    func stop() async
    /// Upload local changes now instead of waiting for the backend's scheduler.
    func pushPending() async
    /// Fetch remote changes now.
    func pull() async
}

/// Used when sync is switched off or can't run: keeps the UI path uniform.
public final class DisabledAppStateSync: AppStateSync {
    public let status: SyncStatus
    public init(reason: String) { status = .unavailable(reason: reason) }
    public func statusUpdates() -> AsyncStream<SyncStatus> {
        let status = status
        return AsyncStream { $0.yield(status) }
    }
    public func start() async {}
    public func stop() async {}
    public func pushPending() async {}
    public func pull() async {}
}
