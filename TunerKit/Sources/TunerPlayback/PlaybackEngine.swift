import AVFoundation
import Foundation
import os

/// Shared, thread-safe "where did this stream end up" box. The engine sets it when a stream has
/// fully downloaded; the resolver sets it when a background prefetch finishes. Either way the
/// engine can switch to the local file for seeks and for starting the item.
public final class StreamCompletion: Hashable, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<URL?>(initialState: nil)
    /// Moves a completed temporary download somewhere durable (the track cache) and returns it.
    let store: (@Sendable (URL) async -> URL?)?

    public init(store: (@Sendable (URL) async -> URL?)? = nil) { self.store = store }

    public var finalURL: URL? {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }

    public static func == (a: StreamCompletion, b: StreamCompletion) -> Bool { a === b }
    public func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
}

/// An HTTP source the engine decodes while it downloads.
public struct StreamSpec: Hashable, Sendable {
    public var request: URLRequest
    /// Codec or file extension ("flac", "mp3", "aac", "m4a"…) to help the parser; content type is used if nil.
    public var typeHint: String?
    /// Live radio: ICY metadata, no seeking, nothing written to disk.
    public var isLive: Bool
    public var expectedDuration: TimeInterval?
    public var completion: StreamCompletion

    public init(request: URLRequest, typeHint: String? = nil, isLive: Bool = false,
                expectedDuration: TimeInterval? = nil, completion: StreamCompletion = StreamCompletion()) {
        self.request = request
        self.typeHint = typeHint
        self.isLive = isLive
        self.expectedDuration = expectedDuration
        self.completion = completion
    }
}

/// One thing the engine can play: a local file or a stream, plus its gain.
public struct EngineItem: Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        case file(URL)
        case stream(StreamSpec)
    }

    public var id: String
    public var source: Source
    /// Linear gain applied to every sample (ReplayGain).
    public var gain: Float

    public init(id: String, source: Source, gain: Float = 1) {
        self.id = id
        self.source = source
        self.gain = gain
    }

    public init(id: String, fileURL: URL, gain: Float = 1) {
        self.init(id: id, source: .file(fileURL), gain: gain)
    }

    var isLive: Bool {
        if case .stream(let s) = source { return s.isLive }
        return false
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
    /// The engine ran out of decoded audio while a stream was still loading (true), or recovered (false).
    case buffering(Bool)
    /// ICY metadata from a live stream, e.g. `StreamTitle`.
    case streamMetadata(id: String, title: String)
}

/// Gapless PCM playback of local files and HTTP streams.
public protocol PlaybackEngine: AnyObject, Sendable {
    var events: AsyncStream<EngineEvent> { get }

    /// Starts `item` immediately (replacing anything playing) at `offset` seconds.
    func play(_ item: EngineItem, at offset: TimeInterval)
    /// Loads `item` at `offset` and starts decoding, but stays paused until `resume()`.
    func load(_ item: EngineItem, at offset: TimeInterval)
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

/// Lets features such as ShazamKit see the PCM the engine is playing.
public protocol AudioTapHost: AnyObject, Sendable {
    func installTap(_ handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)
    func removeTap()
}

/// What a decoder produced for one read.
enum PCMRead {
    case buffer(AVAudioPCMBuffer)
    /// Nothing decodable yet (stream still loading). `onReadable` fires when that changes.
    case wait
    case end
}

/// A decoder that yields PCM in the engine's format. Every method is called on the engine queue.
protocol PCMSource: AnyObject {
    var item: EngineItem { get }
    var onReadable: (() -> Void)? { get set }
    func read(frames: AVAudioFrameCount) throws -> PCMRead
    /// Moves within the open source, keeping what it has loaded. False means reopen it instead.
    func seek(to seconds: TimeInterval) -> Bool
    func cancel()
}

extension PCMSource {
    func seek(to seconds: TimeInterval) -> Bool { false }
}
