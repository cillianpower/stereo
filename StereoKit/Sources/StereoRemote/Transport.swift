import CryptoKit
import Foundation
import Network
import os

/// How connections are secured.
public enum RemoteSecurity: Sendable {
    /// TLS 1.2 with a pre-shared key. Every device with the same key (an iCloud Keychain item)
    /// trusts the others with no pairing step.
    case preSharedKey(Data, identity: String = "stereo-handoff")
    /// Plain TCP. Tests only: never use it on a real network.
    case insecureForTesting
}

/// Length-prefixed framing: a 4-byte big-endian length, then that many bytes of JSON `Frame`.
final class StereoFramer: NWProtocolFramerImplementation {
    static let label = "StereoFrame"
    static let definition = NWProtocolFramer.Definition(implementation: StereoFramer.self)
    static let headerSize = 4
    /// Frames bigger than this are refused (a queue window is a few hundred KB at most).
    static let maxFrame = 8 * 1024 * 1024

    required init(framer: NWProtocolFramer.Instance) {}
    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        framer.writeOutput(data: Self.header(for: messageLength))
        do {
            try framer.writeOutputNoCopy(length: messageLength)
        } catch {
            framer.markFailed(error: .posix(.EMSGSIZE))
        }
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var length: Int?
            let parsed = framer.parseInput(minimumIncompleteLength: Self.headerSize, maximumLength: Self.headerSize) { buffer, _ in
                guard let buffer, buffer.count >= Self.headerSize else { return 0 }
                length = Self.length(fromHeader: buffer)
                return Self.headerSize
            }
            guard parsed, let length else { return Self.headerSize }
            guard length <= Self.maxFrame else {
                framer.markFailed(error: .posix(.EMSGSIZE))
                return 0
            }
            let message = NWProtocolFramer.Message(definition: Self.definition)
            // Waits until `length` bytes have arrived; returns false if they haven't yet.
            if !framer.deliverInputNoCopy(length: length, message: message, isComplete: true) {
                return 0
            }
        }
    }

    static func header(for length: Int) -> Data {
        withUnsafeBytes(of: UInt32(length).bigEndian) { Data($0) }
    }

    static func length(fromHeader buffer: UnsafeMutableRawBufferPointer) -> Int {
        Int(UInt32(buffer[0]) << 24 | UInt32(buffer[1]) << 16 | UInt32(buffer[2]) << 8 | UInt32(buffer[3]))
    }
}

enum RemoteTransport {
    static func parameters(_ security: RemoteSecurity) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.noDelay = true

        let params: NWParameters
        switch security {
        case .preSharedKey(let key, let identity):
            let tls = NWProtocolTLS.Options()
            let sec = tls.securityProtocolOptions
            // Derive the TLS key from the stored secret, so the raw Keychain value never goes into TLS.
            let derived = HMAC<SHA256>.authenticationCode(for: Data(identity.utf8), using: SymmetricKey(data: key))
            let keyData = derived.withUnsafeBytes { DispatchData(bytes: $0) }
            let idData = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(sec, keyData as __DispatchData, idData as __DispatchData)
            // PSK cipher suites exist only in TLS 1.2.
            sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
            sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
            sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
            params = NWParameters(tls: tls, tcp: tcp)
        case .insecureForTesting:
            params = NWParameters(tls: nil, tcp: tcp)
        }
        params.includePeerToPeer = true
        let framer = NWProtocolFramer.Options(definition: StereoFramer.definition)
        params.defaultProtocolStack.applicationProtocols.insert(framer, at: 0)
        return params
    }
}

/// One framed connection. Events arrive on `events`; everything else is thread-safe.
final class RemoteConnection: @unchecked Sendable {
    enum Event: Sendable {
        case ready
        case frame(Frame.DecodeResult)
        case closed(String?)
    }

    let connection: NWConnection
    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let queue = DispatchQueue(label: "stereo.remote.connection")
    private let log = Logger(subsystem: "app.stereo", category: "remote")
    private let closed = OSAllocatedUnfairLock(initialState: false)

    init(_ connection: NWConnection) {
        self.connection = connection
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    deinit {
        // An NWConnection that's dropped without cancel stays open; never leak one.
        connection.cancel()
    }

    convenience init(endpoint: NWEndpoint, security: RemoteSecurity) {
        self.init(NWConnection(to: endpoint, using: RemoteTransport.parameters(security)))
    }

    var endpoint: NWEndpoint { connection.endpoint }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.continuation.yield(.ready)
                self.receive()
            case .failed(let error):
                self.finish(error.localizedDescription)
            case .waiting(let error):
                // TLS handshake failures (wrong PSK) and refused connections land here; don't retry forever.
                self.log.debug("connection waiting: \(error.localizedDescription)")
                self.finish(error.localizedDescription)
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive() {
        connection.receiveMessage { [weak self] content, context, isComplete, error in
            guard let self else { return }
            if let content, !content.isEmpty {
                self.continuation.yield(.frame(Frame.decode(content)))
            }
            if let error {
                self.finish(error.localizedDescription)
                return
            }
            // The peer closed: the stream ends with an empty, final message.
            if context?.isFinal == true || (isComplete && (content?.isEmpty ?? true)) {
                self.finish("Closed by peer")
                return
            }
            if self.closed.withLock({ $0 }) { return }
            self.receive()
        }
    }

    func send(_ message: RemoteMessage) {
        guard let data = try? Frame(message).encoded() else { return }
        sendRaw(data)
    }

    func sendRaw(_ data: Data) {
        let framerMessage = NWProtocolFramer.Message(definition: StereoFramer.definition)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [framerMessage])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            if let error { self?.log.debug("send failed: \(error.localizedDescription)") }
        })
    }

    /// Sends `message`, then closes once it's on the wire.
    func send(_ message: RemoteMessage, thenClose: Bool) {
        guard thenClose, let data = try? Frame(message).encoded() else { return send(message) }
        let framerMessage = NWProtocolFramer.Message(definition: StereoFramer.definition)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [framerMessage])
        // Strong capture: the owner may drop us right after refusing, but the close must still happen.
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [self] _ in
            self.queue.asyncAfter(deadline: .now() + 0.1) { [self] in self.close() }
        })
    }

    func close() {
        connection.cancel()
        finish(nil)
    }

    private func finish(_ reason: String?) {
        let alreadyClosed = closed.withLock { done in
            defer { done = true }
            return done
        }
        guard !alreadyClosed else { return }
        continuation.yield(.closed(reason))
        continuation.finish()
        if connection.state != .cancelled { connection.cancel() }
    }
}
