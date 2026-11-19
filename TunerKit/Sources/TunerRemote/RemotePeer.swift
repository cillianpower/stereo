import Foundation
import os

/// One end of a Tuner↔Tuner connection. The protocol is symmetric: either end can be a host
/// (if it has a local player), a controller (if it subscribed to the other), or both.
///
/// Roles in a handoff:
/// - source: has the queue; sends `transferOffer`, waits for `transferReady`, sends `transferCommit`, stops.
/// - target: receives the offer, prepares, answers `transferReady`, starts on `transferCommit`.
/// Push = we are the source; pull = we send `transferRequest` and the other side becomes the source.
@MainActor
final class RemotePeer {
    enum Phase: Equatable { case connecting, handshaking, open, closed(String?) }

    let connection: RemoteConnection
    let local: DeviceInfo
    weak var host: RemotePlaybackHost?

    private(set) var phase: Phase = .connecting
    private(set) var remote: DeviceInfo?
    /// The other side's state, if we subscribed.
    private(set) var remoteState: RemoteState?

    var onOpen: ((DeviceInfo) -> Void)?
    var onRemoteState: ((RemoteState) -> Void)?
    var onClose: ((String?) -> Void)?
    var onRefused: ((RemoteErrorCode, String) -> Void)?

    /// How long a source waits for `transferReady` before giving up and playing on.
    var transferTimeout: Duration = .seconds(5)
    /// How long a prepared target waits for `transferCommit` before discarding.
    var commitTimeout: Duration = .seconds(10)
    var handshakeTimeout: Duration = .seconds(5)

    private let log = Logger(subsystem: "app.tuner", category: "remote")
    private var eventTask: Task<Void, Never>?
    private var subscriptionTask: Task<Void, Never>?
    private var lastSentState: RemoteState?
    private var openWaiters: [CheckedContinuation<DeviceInfo, Error>] = []
    private var commandWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var transferWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    /// Offers we sent (we're the source), waiting for ready.
    private var outgoingTransfers: Set<UUID> = []
    /// Offers we accepted (we're the target), waiting for commit.
    private var preparedTransfers: [UUID: Task<Void, Never>] = [:]
    /// Pulls we requested: the incoming offer with this id is accepted with our host.
    private var requestedPulls: Set<UUID> = []

    init(connection: RemoteConnection, local: DeviceInfo, host: RemotePlaybackHost?) {
        self.connection = connection
        self.local = local
        self.host = host
    }

    func start() {
        let events = connection.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
        connection.start()
        let timeout = handshakeTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, self.phase == .connecting || self.phase == .handshaking else { return }
            self.close(reason: "Handshake timed out")
        }
    }

    /// Resolves once both hellos are exchanged and accepted.
    func waitUntilOpen() async throws -> DeviceInfo {
        switch phase {
        case .open: return remote!
        case .closed(let reason): throw RemoteError.closed(reason)
        default: return try await withCheckedThrowingContinuation { openWaiters.append($0) }
        }
    }

    func close(reason: String? = nil) {
        connection.close()
        finish(reason)
    }

    // MARK: Controller-side API

    func subscribe() { connection.send(.subscribe) }
    func unsubscribe() { connection.send(.unsubscribe) }

    func send(_ command: RemoteCommand, timeout: Duration = .seconds(3)) async throws {
        guard phase == .open else { throw RemoteError.notConnected }
        let id = UUID()
        connection.send(.command(id: id, command))
        try await wait(id, in: \.commandWaiters, timeout: timeout)
    }

    /// Push: hand what `source` is playing to the peer. On any failure or timeout, `source`
    /// keeps playing.
    func pushTransfer(from source: RemotePlaybackHost) async throws {
        guard phase == .open else { throw RemoteError.notConnected }
        guard let snapshot = source.queueSnapshot() else { throw RemoteError.nothingPlaying }
        let id = UUID()
        outgoingTransfers.insert(id)
        defer { outgoingTransfers.remove(id) }
        connection.send(.transferOffer(id: id, snapshot))
        do {
            try await wait(id, in: \.transferWaiters, timeout: transferTimeout)
        } catch {
            connection.send(.transferCancel(id: id))
            throw error
        }
        // Commit first, then fade: the target starts as we fade, so there's overlap, not silence.
        connection.send(.transferCommit(id: id))
        await source.stopForTransfer()
    }

    /// Pull: ask the peer for what it's playing and start it on `target`.
    func pullTransfer(to target: RemotePlaybackHost) async throws {
        guard phase == .open else { throw RemoteError.notConnected }
        let id = UUID()
        requestedPulls.insert(id)
        defer { requestedPulls.remove(id) }
        let previousHost = host
        host = target
        defer { host = previousHost ?? target }
        connection.send(.transferRequest(id: id))
        // Completes on our transferCommit receipt (see `handleCommit`), so allow ready + commit.
        try await wait(id, in: \.transferWaiters, timeout: transferTimeout + .seconds(2))
    }

    // MARK: Events

    private func handle(_ event: RemoteConnection.Event) {
        switch event {
        case .ready:
            phase = .handshaking
            connection.send(.hello(local))
        case .frame(.message(let message)):
            handle(message)
        case .frame(.otherVersion(let v)):
            log.info("peer speaks protocol v\(v), we speak v\(remoteProtocolVersion)")
            refuse(.versionMismatch, "This device speaks protocol \(remoteProtocolVersion); yours speaks \(v).")
        case .frame(.garbage):
            if phase != .open { refuse(.badMessage, "Unreadable message") }
        case .closed(let reason):
            finish(reason)
        }
    }

    private func refuse(_ code: RemoteErrorCode, _ message: String) {
        connection.send(.error(code, message: message), thenClose: true)
        finishWaiters(with: RemoteError.refused(code, message))
        finish("Refused: \(code.rawValue)")
    }

    private func handle(_ message: RemoteMessage) {
        if case .hello(let info) = message { return handleHello(info) }
        if case .error(let code, let text) = message {
            onRefused?(code, text)
            finishWaiters(with: RemoteError.refused(code, text))
            return close(reason: text)
        }
        guard phase == .open else {
            return refuse(.badMessage, "Expected hello first")
        }

        switch message {
        case .hello, .error:
            break
        case .subscribe:
            startSubscription()
        case .unsubscribe:
            subscriptionTask?.cancel()
            subscriptionTask = nil
        case .state(let state):
            remoteState = state
            onRemoteState?(state)
        case .stateDelta(let delta):
            guard let current = remoteState else { return }
            let next = delta.applied(to: current)
            remoteState = next
            onRemoteState?(next)
        case .command(let id, let command):
            if let host {
                host.apply(command)
                connection.send(.commandResult(id: id, ok: true, message: nil))
            } else {
                connection.send(.commandResult(id: id, ok: false, message: "No player"))
            }
        case .commandResult(let id, let ok, let text):
            resume(id, in: \.commandWaiters, error: ok ? nil : RemoteError.refused(.notAHost, text ?? "Command failed"))
        case .transferRequest(let id):
            handleTransferRequest(id)
        case .transferOffer(let id, let snapshot):
            handleOffer(id, snapshot)
        case .transferReady(let id):
            if outgoingTransfers.contains(id) {
                resume(id, in: \.transferWaiters, error: nil)
            } else if pullsWeServe.contains(id) {
                // We're the source of a pull the peer requested.
                pullsWeServe.remove(id)
                connection.send(.transferCommit(id: id))
                if let host { Task { await host.stopForTransfer() } }
            }
        case .transferFailed(let id, let text):
            pullsWeServe.remove(id)
            resume(id, in: \.transferWaiters, error: RemoteError.transferFailed(text))
        case .transferCommit(let id):
            handleCommit(id)
        case .transferCancel(let id):
            if let task = preparedTransfers.removeValue(forKey: id) {
                task.cancel()
                host?.cancelTransfer()
            }
        }
    }

    private var pullsWeServe: Set<UUID> = []

    private func handleHello(_ info: DeviceInfo) {
        guard info.protocolVersion == remoteProtocolVersion else {
            return refuse(.versionMismatch, "Protocol \(info.protocolVersion) isn't supported.")
        }
        guard info.account == local.account else {
            return refuse(.accountMismatch, "Signed in to a different account.")
        }
        guard remote == nil else { return }
        remote = info
        if phase == .connecting {
            // Ready may not have been seen yet on the accepting side.
            connection.send(.hello(local))
        }
        phase = .open
        onOpen?(info)
        let waiters = openWaiters
        openWaiters = []
        for w in waiters { w.resume(returning: info) }
    }

    private func startSubscription() {
        guard let host else {
            connection.send(.error(.notAHost, message: "This device has no player."))
            return
        }
        subscriptionTask?.cancel()
        let initial = host.currentState()
        lastSentState = initial
        connection.send(.state(initial))
        let changes = host.stateChanges()
        subscriptionTask = Task { [weak self] in
            for await state in changes {
                guard let self, !Task.isCancelled else { return }
                self.push(state)
            }
        }
    }

    private func push(_ state: RemoteState) {
        guard let last = lastSentState else {
            lastSentState = state
            connection.send(.state(state))
            return
        }
        let delta = RemoteStateDelta(from: last, to: state)
        guard !delta.isEmpty else { return }
        lastSentState = delta.applied(to: last)
        connection.send(.stateDelta(delta))
    }

    // MARK: Transfers (target side)

    private func handleTransferRequest(_ id: UUID) {
        guard let host, let snapshot = host.queueSnapshot() else {
            connection.send(.transferFailed(id: id, message: "Nothing is playing."))
            return
        }
        pullsWeServe.insert(id)
        connection.send(.transferOffer(id: id, snapshot))
        let timeout = transferTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            // No ready in time: keep playing here.
            self?.pullsWeServe.remove(id)
        }
    }

    private func handleOffer(_ id: UUID, _ snapshot: QueueSnapshot) {
        guard let host else {
            connection.send(.transferFailed(id: id, message: "This device has no player."))
            return
        }
        let commitTimeout = self.commitTimeout
        preparedTransfers[id] = Task { [weak self] in
            do {
                try await host.prepareTransfer(snapshot)
                guard !Task.isCancelled else { return }
                self?.connection.send(.transferReady(id: id))
            } catch {
                self?.preparedTransfers[id] = nil
                self?.connection.send(.transferFailed(id: id, message: error.localizedDescription))
                self?.resume(id, in: \.transferWaiters, error: RemoteError.transferFailed(error.localizedDescription))
                return
            }
            try? await Task.sleep(for: commitTimeout)
            guard let self, self.preparedTransfers[id] != nil else { return }
            self.preparedTransfers[id] = nil
            host.cancelTransfer()
            self.resume(id, in: \.transferWaiters, error: RemoteError.timedOut)
        }
    }

    private func handleCommit(_ id: UUID) {
        guard preparedTransfers.removeValue(forKey: id) != nil else { return }
        host?.commitTransfer()
        resume(id, in: \.transferWaiters, error: nil)
    }

    // MARK: Waiting

    private func wait(_ id: UUID, in waiters: ReferenceWritableKeyPath<RemotePeer, [UUID: CheckedContinuation<Void, Error>]>,
                      timeout: Duration) async throws {
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.resume(id, in: waiters, error: RemoteError.timedOut)
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self[keyPath: waiters][id] = c
        }
    }

    private func resume(_ id: UUID, in waiters: ReferenceWritableKeyPath<RemotePeer, [UUID: CheckedContinuation<Void, Error>]>,
                        error: Error?) {
        guard let c = self[keyPath: waiters].removeValue(forKey: id) else { return }
        if let error { c.resume(throwing: error) } else { c.resume() }
    }

    private func finishWaiters(with error: Error) {
        for c in openWaiters { c.resume(throwing: error) }
        openWaiters = []
        for (_, c) in commandWaiters { c.resume(throwing: error) }
        commandWaiters = [:]
        for (_, c) in transferWaiters { c.resume(throwing: error) }
        transferWaiters = [:]
    }

    private func finish(_ reason: String?) {
        if case .closed = phase { return }
        phase = .closed(reason)
        subscriptionTask?.cancel()
        eventTask?.cancel()
        for (_, task) in preparedTransfers { task.cancel() }
        if !preparedTransfers.isEmpty { host?.cancelTransfer() }
        preparedTransfers = [:]
        finishWaiters(with: RemoteError.closed(reason))
        onClose?(reason)
    }
}
