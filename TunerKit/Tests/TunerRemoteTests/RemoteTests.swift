import Foundation
import Network
import Testing
import TunerModel
@testable import TunerRemote

// MARK: Helpers

private let src = SourceID("nav")
private func track(_ n: Int) -> Track { Track(id: ItemID(source: src, raw: "t\(n)"), title: "Track \(n)", duration: .seconds(200)) }
private let keyA = Data(repeating: 7, count: 32)
private let keyB = Data(repeating: 9, count: 32)

@MainActor
final class FakeHost: RemotePlaybackHost {
    var state = RemoteState()
    var applied: [RemoteCommand] = []
    var prepared: QueueSnapshot?
    var committed = false
    var cancelled = false
    var stopped = false
    var prepareDelay: Duration = .zero
    var prepareError: Error?
    private var continuations: [AsyncStream<RemoteState>.Continuation] = []

    init(playing: Bool = false) {
        if playing {
            state = RemoteState(item: .track(track(1)), status: .playing,
                                anchor: PositionAnchor(position: 42, rate: 1), duration: 200, remaining: [track(2), track(3)])
        }
    }

    func currentState() -> RemoteState { state }
    func stateChanges() -> AsyncStream<RemoteState> {
        let (stream, c) = AsyncStream.makeStream(of: RemoteState.self)
        continuations.append(c)
        return stream
    }
    func setState(_ s: RemoteState) {
        state = s
        for c in continuations { c.yield(s) }
    }

    func apply(_ command: RemoteCommand) {
        applied.append(command)
        var s = state
        switch command {
        case .pause: s.status = .paused; s.anchor = PositionAnchor(position: s.anchor.position(), rate: 0)
        case .play: s.status = .playing; s.anchor = PositionAnchor(position: s.anchor.position, rate: 1)
        case .seek(let t): s.anchor = PositionAnchor(position: t, rate: s.anchor.rate)
        case .setVolume(let v): s.volume = v
        default: break
        }
        setState(s)
    }

    func queueSnapshot() -> QueueSnapshot? {
        guard case .track(let t) = state.item else { return nil }
        return QueueSnapshot(content: .tracks([t] + state.remaining, currentIndex: 0), position: state.anchor.position(), volume: state.volume)
    }

    func prepareTransfer(_ snapshot: QueueSnapshot) async throws {
        try await Task.sleep(for: prepareDelay)
        if let prepareError { throw prepareError }
        prepared = snapshot
    }
    func commitTransfer() {
        committed = true
        if case .tracks(let tracks, let i) = prepared?.content {
            setState(RemoteState(item: .track(tracks[i]), status: .playing,
                                 anchor: PositionAnchor(position: prepared!.position, rate: 1)))
        }
    }
    func cancelTransfer() { cancelled = true; prepared = nil }
    func stopForTransfer() async { stopped = true; setState(RemoteState()) }
}

private func device(_ name: String, account: String = "me") -> DeviceInfo {
    DeviceInfo(id: name, name: name, kind: .mac, account: account)
}

@MainActor
private func eventually(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

private func loopback(_ port: UInt16) -> NWEndpoint { .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!) }

@MainActor
private func makePair(hostPlaying: Bool = true, security: RemoteSecurity = .preSharedKey(keyA),
                      clientSecurity: RemoteSecurity? = nil, clientAccount: String = "me",
                      clientHost: FakeHost? = nil) async throws -> (server: RemoteNode, serverHost: FakeHost, client: RemoteNode, port: UInt16) {
    let serverHost = FakeHost(playing: hostPlaying)
    let server = RemoteNode(device: device("Mac"), security: security, host: serverHost, advertise: false)
    let port = try await server.start()
    let client = RemoteNode(device: device("Phone", account: clientAccount), security: clientSecurity ?? security,
                            host: clientHost, advertise: false)
    return (server, serverHost, client, port)
}

// MARK: Pure logic

@Suite struct RemoteModelTests {
    @Test func anchorExtrapolates() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let a = PositionAnchor(position: 10, at: t0, rate: 1)
        #expect(a.position(at: t0.addingTimeInterval(5)) == 15)
        #expect(PositionAnchor(position: 10, at: t0, rate: 0).position(at: t0.addingTimeInterval(5)) == 10)
    }

    @Test func deltaOnlyCarriesChanges() {
        let base = RemoteState(item: .track(track(1)), status: .playing, anchor: PositionAnchor(position: 0, rate: 1), volume: 1)
        // Re-anchoring at the extrapolated position is not a change.
        var same = base
        same.anchor = PositionAnchor(position: base.anchor.position(), rate: 1)
        #expect(RemoteStateDelta(from: base, to: same).isEmpty)

        var changed = base
        changed.volume = 0.5
        changed.streamTitle = "x"
        let d = RemoteStateDelta(from: base, to: changed)
        #expect(d.volume == 0.5)
        #expect(d.streamTitle == Change("x"))
        #expect(d.item == nil)
        #expect(d.applied(to: base) == changed)

        var cleared = changed
        cleared.streamTitle = nil
        let d2 = RemoteStateDelta(from: changed, to: cleared)
        #expect(d2.streamTitle == Change(nil))
        #expect(d2.applied(to: changed).streamTitle == nil)
    }

    @Test func framesRoundTripAndDetectVersion() throws {
        let msg = RemoteMessage.command(id: UUID(), .setQueue(tracks: [track(1)], startIndex: 0, shuffled: true))
        let data = try Frame(msg).encoded()
        guard case .message(let decoded) = Frame.decode(data) else { Issue.record("decode failed"); return }
        #expect(decoded == msg)
        let future = try Frame(.subscribe, version: 99).encoded()
        guard case .otherVersion(99) = Frame.decode(future) else { Issue.record("expected otherVersion"); return }
        guard case .garbage = Frame.decode(Data("nope".utf8)) else { Issue.record("expected garbage"); return }
    }

    @Test func framerHeader() {
        let header = TunerFramer.header(for: 0x01020304)
        #expect(Array(header) == [1, 2, 3, 4])
    }
}

// MARK: Over loopback

@Suite(.serialized) @MainActor struct RemoteLoopbackTests {
    @Test func handshakeWithPreSharedKey() async throws {
        let (server, _, client, port) = try await makePair()
        defer { server.stop() }
        let controller = try await client.connect(to: loopback(port))
        #expect(controller.device?.name == "Mac")
        #expect(controller.connection == .connected)
        #expect(await eventually { server.sessions.first?.remoteDevice?.name == "Phone" })
        controller.disconnect()
        #expect(await eventually { server.sessions.isEmpty })
    }

    @Test func wrongKeyIsRejected() async throws {
        let (server, _, client, port) = try await makePair(clientSecurity: .preSharedKey(keyB))
        defer { server.stop() }
        await #expect(throws: (any Error).self) { _ = try await client.connect(to: loopback(port)) }
    }

    @Test func otherAccountIsRejected() async throws {
        let (server, _, client, port) = try await makePair(clientAccount: "someone-else")
        defer { server.stop() }
        do {
            _ = try await client.connect(to: loopback(port))
            Issue.record("expected refusal")
        } catch let error as RemoteError {
            guard case .refused(.accountMismatch, _) = error else { Issue.record("got \(error)"); return }
        }
    }

    @Test func subscribeSnapshotAndCommandRoundTrip() async throws {
        let (server, host, client, port) = try await makePair()
        defer { server.stop() }
        let controller = try await client.connect(to: loopback(port))
        controller.subscribe()
        #expect(await eventually { controller.state?.item == .track(track(1)) })
        #expect(controller.state?.remaining.count == 2)
        #expect(abs((controller.state?.anchor.position() ?? 0) - 42) < 1)

        try await controller.send(.pause)
        #expect(host.applied == [.pause])
        #expect(await eventually { controller.state?.status == .paused })

        try await controller.send(.setVolume(0.25))
        #expect(await eventually { controller.state?.volume == 0.25 })

        try await controller.send(.seek(120))
        #expect(await eventually { abs((controller.state?.anchor.position() ?? 0) - 120) < 0.5 })

        // Host-side change with no command (e.g. a track ended) also reaches the controller.
        host.setState(RemoteState(item: .track(track(2)), status: .playing, anchor: PositionAnchor(position: 0, rate: 1)))
        #expect(await eventually { controller.state?.item == .track(track(2)) })
    }

    @Test func commandWithoutHostFails() async throws {
        let server = RemoteNode(device: device("Mac"), security: .preSharedKey(keyA), host: nil, advertise: false)
        let port = try await server.start()
        defer { server.stop() }
        let controller = try await RemoteNode(device: device("Phone"), security: .preSharedKey(keyA), host: nil, advertise: false)
            .connect(to: loopback(port))
        await #expect(throws: RemoteError.self) { try await controller.send(.play) }
    }

    @Test func pushHandoffMovesPlayback() async throws {
        let phonePlayer = FakeHost(playing: true)
        let (server, macPlayer, client, port) = try await makePair(hostPlaying: false, clientHost: phonePlayer)
        defer { server.stop() }
        let controller = try await client.connect(to: loopback(port))
        try await controller.handOff(from: phonePlayer)
        #expect(phonePlayer.stopped)
        #expect(await eventually { macPlayer.committed })
        guard case .tracks(let tracks, 0) = macPlayer.prepared?.content else { Issue.record("no snapshot"); return }
        #expect(tracks.map(\.id) == [track(1), track(2), track(3)].map(\.id))
        #expect(abs((macPlayer.prepared?.position ?? 0) - 42) < 1)
    }

    @Test func pullHandoffBringsPlaybackHere() async throws {
        let phonePlayer = FakeHost(playing: false)
        let (server, macPlayer, client, port) = try await makePair(hostPlaying: true, clientHost: phonePlayer)
        defer { server.stop() }
        let controller = try await client.connect(to: loopback(port))
        try await controller.bringHere(to: phonePlayer)
        #expect(phonePlayer.committed)
        #expect(phonePlayer.state.item == .track(track(1)))
        #expect(await eventually { macPlayer.stopped })
    }

    @Test func handoffTimeoutKeepsSourcePlaying() async throws {
        let phonePlayer = FakeHost(playing: true)
        let (server, macPlayer, client, port) = try await makePair(hostPlaying: false, clientHost: phonePlayer)
        defer { server.stop() }
        macPlayer.prepareDelay = .seconds(3)
        let controller = try await client.connect(to: loopback(port))
        controller.transferTimeout = .milliseconds(400)
        await #expect(throws: RemoteError.timedOut) { try await controller.handOff(from: phonePlayer) }
        #expect(!phonePlayer.stopped)
        #expect(phonePlayer.state.status == .playing)
        // The target got a cancel and must not start later.
        #expect(await eventually(.seconds(4)) { macPlayer.cancelled || macPlayer.prepared != nil })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(!macPlayer.committed)
    }

    @Test func handoffFailureOnTargetKeepsSourcePlaying() async throws {
        struct Boom: Error {}
        let phonePlayer = FakeHost(playing: true)
        let (server, macPlayer, client, port) = try await makePair(hostPlaying: false, clientHost: phonePlayer)
        defer { server.stop() }
        macPlayer.prepareError = Boom()
        let controller = try await client.connect(to: loopback(port))
        await #expect(throws: RemoteError.self) { try await controller.handOff(from: phonePlayer) }
        #expect(!phonePlayer.stopped)
    }

    @Test func nothingPlayingCannotHandOff() async throws {
        let idle = FakeHost(playing: false)
        let (server, _, client, port) = try await makePair(hostPlaying: false, clientHost: idle)
        defer { server.stop() }
        let controller = try await client.connect(to: loopback(port))
        await #expect(throws: RemoteError.nothingPlaying) { try await controller.handOff(from: idle) }
    }

    @Test func versionMismatchIsRefused() async throws {
        let (server, _, _, port) = try await makePair(security: .insecureForTesting)
        defer { server.stop() }
        let raw = RemoteConnection(endpoint: loopback(port), security: .insecureForTesting)
        raw.start()
        var iterator = raw.events.makeAsyncIterator()
        guard case .ready = await iterator.next() else { Issue.record("not ready"); return }
        let futureHello = DeviceInfo(id: "x", name: "Future", kind: .phone, account: "me", protocolVersion: 2)
        raw.sendRaw(try Frame(.hello(futureHello), version: 2).encoded())

        var refused = false
        while let event = await iterator.next() {
            if case .frame(.message(.error(.versionMismatch, _))) = event { refused = true }
            if case .closed = event { break }
        }
        #expect(refused)
    }

    @Test func framerHandlesSplitAndMergedPackets() async throws {
        let (server, host, _, port) = try await makePair(security: .insecureForTesting)
        defer { server.stop() }
        defer { withExtendedLifetime(host) {} }   // RemoteNode holds its host weakly

        // Plain TCP, no framer: we write the length-prefixed bytes ourselves.
        let tcp = NWConnection(to: loopback(port), using: .tcp)
        let reader = FrameReader()
        try await tcp.startAndWait()

        func frame(_ m: RemoteMessage) throws -> Data {
            let body = try Frame(m).encoded()
            return TunerFramer.header(for: body.count) + body
        }
        // hello + subscribe merged into one write…
        try await tcp.sendAsync(try frame(.hello(device("Raw"))) + frame(.subscribe))
        // …then one command split across three writes, including inside the header.
        let command = try frame(.command(id: UUID(), .setVolume(0.5)))
        for chunk in [command.prefix(2), command.dropFirst(2).prefix(7), command.dropFirst(9)] {
            try await tcp.sendAsync(Data(chunk))
            try await Task.sleep(for: .milliseconds(30))
        }

        let received = try await reader.read(from: tcp, until: { messages in
            messages.contains { if case .commandResult(_, true, _) = $0 { true } else { false } }
        })
        #expect(received.contains { if case .hello = $0 { true } else { false } })
        #expect(received.contains { if case .state = $0 { true } else { false } })
        #expect(server.sessions.count == 1)
        #expect(host.applied == [.setVolume(0.5)])
        tcp.cancel()
    }
}

// MARK: Raw TCP helpers

extension NWConnection {
    func startAndWait() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = OSAllocatedUnfairLockBox()
            stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { c.resume() }
                case .failed(let e), .waiting(let e): if once.claim() { c.resume(throwing: e) }
                default: break
                }
            }
            start(queue: .global())
        }
    }

    func sendAsync(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            send(content: data, completion: .contentProcessed { e in e.map { c.resume(throwing: $0) } ?? c.resume() })
        }
    }

    func receiveAsync() async throws -> Data {
        try await withCheckedThrowingContinuation { c in
            receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: data ?? Data()) }
            }
        }
    }
}

final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

/// Reassembles length-prefixed frames from raw TCP reads.
final class FrameReader: @unchecked Sendable {
    private var buffer = Data()

    func read(from connection: NWConnection, until done: @Sendable ([RemoteMessage]) -> Bool) async throws -> [RemoteMessage] {
        var messages: [RemoteMessage] = []
        let deadline = ContinuousClock.now + .seconds(5)
        while !done(messages), ContinuousClock.now < deadline {
            buffer.append(try await connection.receiveAsync())
            while buffer.count >= 4 {
                let b = [UInt8](buffer.prefix(4))
                let length = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
                guard buffer.count >= 4 + length else { break }
                let body = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + length)
                buffer.removeFirst(4 + length)
                if case .message(let m) = Frame.decode(body) { messages.append(m) }
            }
        }
        return messages
    }
}
