import Foundation
import StereoModel

/// Wire protocol version. Bump on any incompatible change to `RemoteMessage`; peers on a
/// different version refuse the session with `.versionMismatch` instead of misreading messages.
/// v2: adds `ping`. Each side sends one at least every few seconds and drops a peer that goes quiet.
public let remoteProtocolVersion = 2

/// Bonjour service type every Stereo instance advertises.
public let remoteServiceType = "_stereo._tcp"

public enum DeviceKind: String, Codable, Sendable, Hashable {
    case phone, pad, mac, tv, unknown

    public var symbolName: String {
        switch self {
        case .phone: "iphone"
        case .pad: "ipad"
        case .mac: "laptopcomputer"
        case .tv: "appletv"
        case .unknown: "hifispeaker"
        }
    }
}

/// Who a peer is, sent in `hello`.
public struct DeviceInfo: Codable, Hashable, Sendable, Identifiable {
    /// Stable per install.
    public var id: String
    public var name: String
    public var kind: DeviceKind
    public var protocolVersion: Int
    /// Navidrome account the device is signed in to. Peers on another account are refused.
    public var account: String

    public init(id: String, name: String, kind: DeviceKind, account: String, protocolVersion: Int = remoteProtocolVersion) {
        self.id = id
        self.name = name
        self.kind = kind
        self.account = account
        self.protocolVersion = protocolVersion
    }
}

/// Playback position as (position at a moment, rate), so controllers draw progress locally
/// instead of polling. Uses wall-clock time; devices on the same LAN are NTP-synced closely enough.
public struct PositionAnchor: Codable, Hashable, Sendable {
    public var position: TimeInterval
    public var at: Date
    public var rate: Double

    public init(position: TimeInterval, at: Date = Date(), rate: Double) {
        self.position = position
        self.at = at
        self.rate = rate
    }

    public func position(at now: Date = Date()) -> TimeInterval {
        max(0, position + now.timeIntervalSince(at) * rate)
    }

    /// True when two anchors predict noticeably different positions (a seek) or the rate changed.
    func diverges(from other: PositionAnchor, tolerance: TimeInterval = 0.75) -> Bool {
        if rate != other.rate { return true }
        let now = Date()
        return abs(position(at: now) - other.position(at: now)) > tolerance
    }
}

/// `PlayableItem` in a Codable form.
public enum RemoteItem: Codable, Hashable, Sendable {
    case track(Track)
    case station(Station)

    public init(_ item: PlayableItem) {
        switch item {
        case .track(let t): self = .track(t)
        case .station(let s): self = .station(s)
        }
    }

    public var playable: PlayableItem {
        switch self {
        case .track(let t): .track(t)
        case .station(let s): .station(s)
        }
    }

    public var title: String { playable.title }
}

public enum RemoteStatus: String, Codable, Sendable, Hashable { case idle, loading, playing, paused, buffering }

/// Everything a controller shows about a device that's playing.
public struct RemoteState: Codable, Hashable, Sendable {
    public var item: RemoteItem?
    public var status: RemoteStatus
    public var anchor: PositionAnchor
    public var duration: TimeInterval?
    public var volume: Float
    /// Next few Up Next tracks (window, not the whole list).
    public var upNext: [Track]
    /// Next few context tracks after Up Next.
    public var remaining: [Track]
    public var shuffle: Bool
    public var repeatMode: RepeatMode
    public var streamTitle: String?
    public var contextName: String?

    public static let windowSize = 50

    public init(item: RemoteItem? = nil, status: RemoteStatus = .idle, anchor: PositionAnchor = .init(position: 0, rate: 0),
                duration: TimeInterval? = nil, volume: Float = 1, upNext: [Track] = [], remaining: [Track] = [],
                shuffle: Bool = false, repeatMode: RepeatMode = .off, streamTitle: String? = nil, contextName: String? = nil) {
        self.item = item; self.status = status; self.anchor = anchor; self.duration = duration; self.volume = volume
        self.upNext = upNext; self.remaining = remaining; self.shuffle = shuffle; self.repeatMode = repeatMode
        self.streamTitle = streamTitle; self.contextName = contextName
    }

    public var isPlaying: Bool { status == .playing || status == .buffering }
}

/// A changed value; wraps optionals so "set to nil" and "unchanged" are distinguishable.
public struct Change<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public var value: Value
    public init(_ value: Value) { self.value = value }
}

/// Only the fields that changed since the last state sent on this connection.
public struct RemoteStateDelta: Codable, Hashable, Sendable {
    public var item: Change<RemoteItem?>?
    public var status: RemoteStatus?
    public var anchor: PositionAnchor?
    public var duration: Change<TimeInterval?>?
    public var volume: Float?
    public var upNext: [Track]?
    public var remaining: [Track]?
    public var shuffle: Bool?
    public var repeatMode: RepeatMode?
    public var streamTitle: Change<String?>?
    public var contextName: Change<String?>?

    public init() {}

    public init(from old: RemoteState, to new: RemoteState) {
        if old.item != new.item { item = Change(new.item) }
        if old.status != new.status { status = new.status }
        if old.anchor.diverges(from: new.anchor) { anchor = new.anchor }
        if old.duration != new.duration { duration = Change(new.duration) }
        if old.volume != new.volume { volume = new.volume }
        if old.upNext != new.upNext { upNext = new.upNext }
        if old.remaining != new.remaining { remaining = new.remaining }
        if old.shuffle != new.shuffle { shuffle = new.shuffle }
        if old.repeatMode != new.repeatMode { repeatMode = new.repeatMode }
        if old.streamTitle != new.streamTitle { streamTitle = Change(new.streamTitle) }
        if old.contextName != new.contextName { contextName = Change(new.contextName) }
        // A new item always needs a fresh anchor.
        if item != nil, anchor == nil { anchor = new.anchor }
    }

    public var isEmpty: Bool { self == RemoteStateDelta() }

    public func applied(to state: RemoteState) -> RemoteState {
        var s = state
        if let item { s.item = item.value }
        if let status { s.status = status }
        if let anchor { s.anchor = anchor }
        if let duration { s.duration = duration.value }
        if let volume { s.volume = volume }
        if let upNext { s.upNext = upNext }
        if let remaining { s.remaining = remaining }
        if let shuffle { s.shuffle = shuffle }
        if let repeatMode { s.repeatMode = repeatMode }
        if let streamTitle { s.streamTitle = streamTitle.value }
        if let contextName { s.contextName = contextName.value }
        return s
    }
}

public enum RemoteCommand: Codable, Hashable, Sendable {
    case play
    case pause
    case togglePlayPause
    case seek(TimeInterval)
    case next
    case previous
    case setQueue(tracks: [Track], startIndex: Int, shuffled: Bool)
    case enqueue(tracks: [Track], playNext: Bool)
    case playStation(Station)
    case setVolume(Float)
    case setShuffle(Bool)
    case setRepeat(RepeatMode)
}

/// What moves between devices on a handoff. Track IDs are server IDs: the receiving device
/// resolves its own stream URLs (it may be on the LAN address while the sender used the remote one).
public struct QueueSnapshot: Codable, Hashable, Sendable {
    public enum Content: Codable, Hashable, Sendable {
        /// Tracks in play order, starting with the current one.
        case tracks([Track], currentIndex: Int)
        case station(Station)
    }

    public var content: Content
    public var position: TimeInterval
    public var shuffle: Bool
    public var repeatMode: RepeatMode
    public var volume: Float
    public var contextName: String?

    public init(content: Content, position: TimeInterval, shuffle: Bool = false, repeatMode: RepeatMode = .off,
                volume: Float = 1, contextName: String? = nil) {
        self.content = content; self.position = position; self.shuffle = shuffle
        self.repeatMode = repeatMode; self.volume = volume; self.contextName = contextName
    }
}

public enum RemoteErrorCode: String, Codable, Sendable, Hashable {
    case versionMismatch
    case accountMismatch
    case notAHost          // peer has no player to control
    case badMessage
    case nothingPlaying
    case transferFailed
}

public enum RemoteMessage: Codable, Hashable, Sendable {
    case hello(DeviceInfo)
    case subscribe
    case unsubscribe
    case state(RemoteState)
    case stateDelta(RemoteStateDelta)
    case command(id: UUID, RemoteCommand)
    case commandResult(id: UUID, ok: Bool, message: String?)
    /// "Send me what you're playing": the peer answers with a `transferOffer` (pull handoff).
    case transferRequest(id: UUID)
    case transferOffer(id: UUID, QueueSnapshot)
    case transferReady(id: UUID)
    case transferFailed(id: UUID, message: String)
    case transferCommit(id: UUID)
    case transferCancel(id: UUID)
    case error(RemoteErrorCode, message: String)
    /// Keepalive. Any frame proves the peer is alive; this one is sent when there's nothing else to say.
    case ping
}

/// One frame on the wire: the protocol version travels with every message.
struct Frame: Codable, Sendable {
    var v: Int
    var m: RemoteMessage

    init(_ m: RemoteMessage, version: Int = remoteProtocolVersion) {
        self.v = version
        self.m = m
    }

    private struct VersionOnly: Decodable { var v: Int }

    enum DecodeResult: Sendable {
        case message(RemoteMessage)
        /// The peer speaks a different protocol version.
        case otherVersion(Int)
        case garbage
    }

    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()

    func encoded() throws -> Data { try Self.encoder.encode(self) }

    static func decode(_ data: Data) -> DecodeResult {
        guard let version = try? decoder.decode(VersionOnly.self, from: data) else { return .garbage }
        guard version.v == remoteProtocolVersion else { return .otherVersion(version.v) }
        guard let frame = try? decoder.decode(Frame.self, from: data) else { return .garbage }
        return .message(frame.m)
    }
}
