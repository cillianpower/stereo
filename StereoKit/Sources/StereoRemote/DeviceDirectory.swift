import Foundation
import Network
import Observation

public struct DiscoveredDevice: Identifiable, Hashable, Sendable {
    /// The advertised device ID (TXT `id`), or the service name if missing.
    public var id: String
    public var name: String
    public var kind: DeviceKind
    public var endpoint: NWEndpoint

    public init(id: String, name: String, kind: DeviceKind, endpoint: NWEndpoint) {
        self.id = id; self.name = name; self.kind = kind; self.endpoint = endpoint
    }
}

/// Live list of Stereo instances on the LAN, excluding this one.
@MainActor
@Observable
public final class DeviceDirectory {
    public private(set) var devices: [DiscoveredDevice] = []
    public private(set) var error: String?

    @ObservationIgnored private let ownID: String
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private let queue = DispatchQueue(label: "stereo.remote.browser")

    public init(ownDeviceID: String) { ownID = ownDeviceID }

    public func start() {
        guard browser == nil else { return }
        startBrowser()
    }

    /// Starts browsing again without clearing the list, which refills within a second. Call when
    /// the app returns to the foreground or the Mac wakes: a suspended browser can stop updating.
    public func restart() {
        browser?.cancel()
        browser = nil
        startBrowser()
    }

    private func startBrowser() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: remoteServiceType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap(Self.device(from:))
            Task { @MainActor in self?.update(found) }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            switch state {
            case .ready:
                Task { @MainActor in self?.error = nil }
            case .waiting(let e):
                // Usually local network access denied; it recovers on its own once allowed.
                Task { @MainActor in self?.error = e.localizedDescription }
            case .failed(let e):
                let identity = browser.map(ObjectIdentifier.init)
                Task { @MainActor in self?.browserFailed(identity, error: e.localizedDescription) }
            default:
                break
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        devices = []
    }

    private func browserFailed(_ identity: ObjectIdentifier?, error: String) {
        guard let browser, identity == ObjectIdentifier(browser) else { return }
        self.error = error
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.browser.map(ObjectIdentifier.init) == identity else { return }
            self.restart()
        }
    }

    private func update(_ found: [DiscoveredDevice]) {
        var seen = Set<String>()
        devices = found
            .filter { $0.id != ownID && seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    nonisolated static func device(from result: NWBrowser.Result) -> DiscoveredDevice? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        var id = name
        var kind = DeviceKind.unknown
        if case .bonjour(let txt) = result.metadata {
            if let v = txt["id"] { id = v }
            if let k = txt["kind"], let parsed = DeviceKind(rawValue: k) { kind = parsed }
        }
        return DiscoveredDevice(id: id, name: name, kind: kind, endpoint: result.endpoint)
    }
}
