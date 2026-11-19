import Foundation

/// The local player as the remote module sees it. The app adapts `PlayerController` to this, so
/// TunerRemote never depends on the playback engine.
@MainActor
public protocol RemotePlaybackHost: AnyObject {
    func currentState() -> RemoteState
    /// Emits whenever something a controller shows may have changed. Duplicates are fine:
    /// sessions diff against what they last sent.
    func stateChanges() -> AsyncStream<RemoteState>
    func apply(_ command: RemoteCommand)

    /// What to hand to another device, or nil if nothing is playing.
    func queueSnapshot() -> QueueSnapshot?
    /// Load `snapshot` paused at its position and pre-buffer, ready to start instantly.
    func prepareTransfer(_ snapshot: QueueSnapshot) async throws
    /// Start the prepared transfer.
    func commitTransfer()
    /// Drop a prepared transfer that never got committed.
    func cancelTransfer()
    /// The other device has taken over: fade out and stop.
    func stopForTransfer() async
}

public enum RemoteError: Error, Equatable, Sendable, LocalizedError {
    case notConnected
    case timedOut
    case refused(RemoteErrorCode, String)
    case transferFailed(String)
    case nothingPlaying
    case closed(String?)

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to that device."
        case .timedOut: "The other device didn't respond in time."
        case .refused(let code, let message):
            switch code {
            case .versionMismatch: "That device runs a different version of Tuner. Update both."
            case .accountMismatch: "That device is signed in to a different account."
            default: message
            }
        case .transferFailed(let message): "Handoff failed: \(message)"
        case .nothingPlaying: "Nothing is playing."
        case .closed(let reason): reason ?? "The connection closed."
        }
    }
}
