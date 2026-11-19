import Foundation
import Network
import Observation
import os

/// This device on the network: listens for other Tuner instances (advertising over Bonjour),
/// serves them its player through `RemoteSession`s, and opens `RemoteController`s to them.
@MainActor
@Observable
public final class RemoteNode {
    public let device: DeviceInfo
    @ObservationIgnored public weak var host: RemotePlaybackHost?

    /// Devices currently connected to us (they control or subscribe to this player).
    public private(set) var sessions: [RemoteSession] = []
    public private(set) var port: UInt16?
    public private(set) var listenerError: String?

    @ObservationIgnored private let security: RemoteSecurity
    @ObservationIgnored private let advertise: Bool
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private let queue = DispatchQueue(label: "tuner.remote.listener")
    @ObservationIgnored private let log = Logger(subsystem: "app.tuner", category: "remote")

    /// - Parameter advertise: publish `_tuner._tcp` over Bonjour. Tests turn this off and connect by port.
    public init(device: DeviceInfo, security: RemoteSecurity, host: RemotePlaybackHost?, advertise: Bool = true) {
        self.device = device
        self.security = security
        self.host = host
        self.advertise = advertise
    }

    /// Starts listening. Returns the port once the listener is ready.
    @discardableResult
    public func start(port requested: UInt16 = 0) async throws -> UInt16 {
        if let port { return port }
        let params = RemoteTransport.parameters(security)
        params.allowLocalEndpointReuse = true
        let nwPort = requested == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: requested)!
        let listener = try NWListener(using: params, on: nwPort)
        if advertise {
            var txt = NWTXTRecord()
            txt["id"] = device.id
            txt["kind"] = device.kind.rawValue
            txt["v"] = String(remoteProtocolVersion)
            listener.service = NWListener.Service(name: device.name, type: remoteServiceType, txtRecord: txt)
        }
        listener.newConnectionHandler = { [weak self] connection in
            let wrapped = RemoteConnection(connection)
            Task { @MainActor in self?.accept(wrapped) }
        }
        self.listener = listener

        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.withLock({ let done = $0; $0 = true; return !done }) {
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    }
                case .failed(let error):
                    Task { @MainActor in self?.listenerError = error.localizedDescription }
                    if once.withLock({ let done = $0; $0 = true; return !done }) {
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        self.port = port
        log.info("remote listener on port \(port)")
        return port
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        for s in sessions { s.close() }
        sessions = []
    }

    private func accept(_ connection: RemoteConnection) {
        let peer = RemotePeer(connection: connection, local: device, host: host)
        let session = RemoteSession(peer: peer)
        sessions.append(session)
        peer.onClose = { [weak self, weak session] _ in
            self?.sessions.removeAll { $0 === session }
        }
        peer.onOpen = { [weak session] info in session?.peerDidOpen(info) }
        peer.start()
    }

    /// Opens a controller to another device.
    public func connect(to endpoint: NWEndpoint) async throws -> RemoteController {
        let peer = RemotePeer(connection: RemoteConnection(endpoint: endpoint, security: security), local: device, host: host)
        let controller = RemoteController(peer: peer)
        peer.start()
        try await controller.open()
        return controller
    }

    public func connect(to device: DiscoveredDevice) async throws -> RemoteController {
        try await connect(to: device.endpoint)
    }
}

/// Host side of one inbound connection: answers subscribe, commands and handoffs with our player.
@MainActor
@Observable
public final class RemoteSession: Identifiable {
    public let id = UUID()
    public private(set) var remoteDevice: DeviceInfo?
    @ObservationIgnored let peer: RemotePeer

    init(peer: RemotePeer) { self.peer = peer }

    func peerDidOpen(_ info: DeviceInfo) { remoteDevice = info }

    public func close() { peer.close() }
}

/// Controller side: a live view of another device's player, plus commands and handoff.
@MainActor
@Observable
public final class RemoteController: Identifiable {
    public enum ConnectionState: Equatable { case connecting, connected, disconnected(String?) }

    public let id = UUID()
    public private(set) var device: DeviceInfo?
    public private(set) var state: RemoteState?
    public private(set) var connection: ConnectionState = .connecting

    @ObservationIgnored let peer: RemotePeer

    init(peer: RemotePeer) {
        self.peer = peer
        peer.onRemoteState = { [weak self] in self?.state = $0 }
        peer.onClose = { [weak self] reason in self?.connection = .disconnected(reason) }
    }

    func open() async throws {
        let info = try await peer.waitUntilOpen()
        device = info
        connection = .connected
    }

    /// Starts receiving the device's state (`state` then updates live).
    public func subscribe() { peer.subscribe() }

    public func send(_ command: RemoteCommand) async throws { try await peer.send(command) }

    /// Fire-and-forget command for buttons.
    public func perform(_ command: RemoteCommand) {
        Task { try? await peer.send(command) }
    }

    /// Moves what `local` is playing to this device. `local` stops only once the device is ready;
    /// on failure or after 5 s it keeps playing.
    public func handOff(from local: RemotePlaybackHost) async throws {
        try await peer.pushTransfer(from: local)
    }

    /// Moves what this device is playing to `local`.
    public func bringHere(to local: RemotePlaybackHost) async throws {
        try await peer.pullTransfer(to: local)
    }

    public var transferTimeout: Duration {
        get { peer.transferTimeout }
        set { peer.transferTimeout = newValue }
    }

    public func disconnect() {
        peer.close()
        connection = .disconnected(nil)
    }
}

