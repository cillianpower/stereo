import Foundation
import Network
import Observation
import os

/// This device on the network: listens for other Stereo instances (advertising over Bonjour),
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
    @ObservationIgnored private let queue = DispatchQueue(label: "stereo.remote.listener")
    @ObservationIgnored private let log = Logger(subsystem: "app.stereo", category: "remote")
    /// Liveness settings for every connection this node makes or accepts. Tests shorten them.
    @ObservationIgnored var heartbeatInterval: Duration = .seconds(2)
    @ObservationIgnored var idleTimeout: Duration = .seconds(8)
    /// The last port we listened on, reused on restart so known endpoints stay valid.
    @ObservationIgnored private var lastPort: UInt16?

    /// - Parameter advertise: publish `_stereo._tcp` over Bonjour. Tests turn this off and connect by port.
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
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready:
                    if once.withLock({ let done = $0; $0 = true; return !done }) {
                        continuation.resume(returning: listener?.port?.rawValue ?? 0)
                    }
                case .failed(let error):
                    let identity = listener.map(ObjectIdentifier.init)
                    Task { @MainActor in self?.listenerDied(identity, error: error.localizedDescription) }
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
        lastPort = port
        listenerError = nil
        log.info("remote listener on port \(port)")
        return port
    }

    /// A listener can fail long after it started: iOS reclaims listening sockets of suspended
    /// apps, and a Mac's network goes away while asleep. Forget it so `ensureListening` restarts it.
    private func listenerDied(_ identity: ObjectIdentifier?, error: String) {
        guard let listener, identity == ObjectIdentifier(listener) else { return }
        log.error("remote listener failed: \(error)")
        listener.cancel()
        self.listener = nil
        port = nil
        listenerError = error
    }

    /// Restarts the listener if it died. Call when the app returns to the foreground or the Mac wakes.
    /// Open sessions are left alone; each one notices on its own if its peer has gone.
    public func ensureListening() async {
        guard listener == nil else { return }
        if let lastPort, (try? await start(port: lastPort)) != nil { return }
        listener?.cancel()
        listener = nil
        do {
            try await start()   // the old port is taken: any port works, Bonjour advertises the new one
        } catch {
            listenerError = error.localizedDescription
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        for s in sessions { s.close() }
        sessions = []
    }

    private func makePeer(_ connection: RemoteConnection) -> RemotePeer {
        let peer = RemotePeer(connection: connection, local: device, host: host)
        peer.heartbeatInterval = heartbeatInterval
        peer.idleTimeout = idleTimeout
        return peer
    }

    private func accept(_ connection: RemoteConnection) {
        let peer = makePeer(connection)
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
        let peer = makePeer(RemoteConnection(endpoint: endpoint, security: security))
        let controller = RemoteController(peer: peer)
        peer.start()
        try await controller.open()
        return controller
    }

    public func connect(to device: DiscoveredDevice) async throws -> RemoteController {
        try await connect(to: device.endpoint)
    }

    /// Tries to reach a device again after its connection dropped, until `limit` passes or the
    /// task is cancelled. `resolve` is asked for the endpoint before every attempt, because a
    /// device that slept or changed network comes back with a new address.
    public func reconnect(limit: Duration = .seconds(30),
                          resolve: @escaping @MainActor () -> NWEndpoint?) async -> RemoteController? {
        let deadline = ContinuousClock.now + limit
        var delay: Duration = .milliseconds(500)
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if let endpoint = resolve(), let controller = try? await connect(to: endpoint) {
                if Task.isCancelled { controller.disconnect(); return nil }
                return controller
            }
            try? await Task.sleep(for: min(delay, deadline - ContinuousClock.now))
            delay = min(delay * 2, .seconds(4))
        }
        return nil
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

    /// Called when the connection drops without `disconnect()`: the device went away or the
    /// network did. Not called if opening failed (that throws instead).
    @ObservationIgnored public var onLost: ((String?) -> Void)?

    @ObservationIgnored let peer: RemotePeer
    @ObservationIgnored private var userDisconnected = false

    init(peer: RemotePeer) {
        self.peer = peer
        peer.onRemoteState = { [weak self] in self?.state = $0 }
        peer.onClose = { [weak self] reason in
            guard let self else { return }
            let wasConnected = self.connection == .connected
            self.connection = .disconnected(reason)
            if wasConnected && !self.userDisconnected { self.onLost?(reason) }
        }
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
        userDisconnected = true
        peer.close()
        connection = .disconnected(nil)
    }
}

