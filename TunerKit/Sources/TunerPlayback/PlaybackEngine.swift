import Foundation

/// One thing the engine can play: a local audio file plus its gain.
public struct EngineItem: Hashable, Sendable {
    public var id: String
    public var fileURL: URL
    /// Linear gain applied to every sample (ReplayGain).
    public var gain: Float

    public init(id: String, fileURL: URL, gain: Float = 1) {
        self.id = id
        self.fileURL = fileURL
        self.gain = gain
    }
}

public enum EngineEvent: Sendable, Equatable {
    /// `play(_:)` started this item.
    case started(id: String)
    /// Playback moved, without a gap, from one item to the pre-scheduled next item.
    case advanced(id: String)
    /// The last scheduled item finished and nothing was queued after it.
    case ended
    case failed(id: String, message: String)
    case playingChanged(Bool)
}

/// Gapless PCM playback of local files. Library tracks are resolved to files (cache or download)
/// before they reach the engine; radio uses `RadioPlayer` for now.
public protocol PlaybackEngine: AnyObject, Sendable {
    var events: AsyncStream<EngineEvent> { get }

    /// Starts `item` immediately (replacing anything playing) at `offset` seconds.
    func play(_ item: EngineItem, at offset: TimeInterval)
    /// Sets the item to play straight after the current one, without a gap.
    /// Ignored if the engine has already started decoding a different next item.
    func setNext(_ item: EngineItem?)
    func pause()
    func resume()
    func stop()
    func seek(to seconds: TimeInterval)
    /// Position within the audible item, in seconds.
    var currentTime: TimeInterval { get }
    var currentItemID: String? { get }
    var volume: Float { get set }
}
