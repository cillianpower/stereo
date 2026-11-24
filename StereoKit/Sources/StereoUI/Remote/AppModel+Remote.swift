import Foundation
import Observation
import os
import StereoModel
import StereoPlayback
import StereoRemote
#if canImport(UIKit)
import UIKit
#endif

/// Owns this device's handoff node, the LAN device list and the device being controlled.
@MainActor
@Observable
public final class RemoteCoordinator {
    public private(set) var node: RemoteNode?
    public private(set) var directory: DeviceDirectory?
    /// Set while this device is controlling another one ("controlling <device>" mode).
    public private(set) var controller: RemoteController?
    public private(set) var isTransferring = false
    public var lastError: String?

    @ObservationIgnored let host: PlayerRemoteHost
    @ObservationIgnored private let log = Logger(subsystem: "app.stereo", category: "remote")

    init(player: PlayerController) {
        host = PlayerRemoteHost(player: player)
    }

    public var devices: [DiscoveredDevice] { directory?.devices ?? [] }
    public var isControllingRemote: Bool { controller?.connection == .connected }
    public var remoteState: RemoteState? { controller?.state }

    // MARK: Lifecycle

    /// Starts advertising and browsing. `account` (the Navidrome username) must match on both devices.
    func start(account: String) {
        stop()
        let info = DeviceInfo(id: Self.deviceID, name: Self.deviceName, kind: Self.deviceKind, account: account.lowercased())
        let node = RemoteNode(device: info, security: .preSharedKey(Self.preSharedKey()), host: host)
        self.node = node
        let directory = DeviceDirectory(ownDeviceID: info.id)
        directory.start()
        self.directory = directory
        Task {
            do { try await node.start() }
            catch { self.lastError = error.localizedDescription; self.log.error("listener failed: \(error.localizedDescription)") }
        }
    }

    func stop() {
        controller?.disconnect()
        controller = nil
        node?.stop()
        node = nil
        directory?.stop()
        directory = nil
    }

    // MARK: Actions

    /// Enter "controlling <device>" mode.
    public func control(_ device: DiscoveredDevice) async {
        guard let node else { return }
        lastError = nil
        do {
            controller?.disconnect()
            let c = try await node.connect(to: device)
            c.subscribe()
            controller = c
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func stopControlling() {
        controller?.disconnect()
        controller = nil
    }

    /// Moves what's playing here to `device`, then controls it.
    public func handOff(to device: DiscoveredDevice) async {
        guard let node else { return }
        isTransferring = true
        defer { isTransferring = false }
        lastError = nil
        do {
            let c = try await node.connect(to: device)
            try await c.handOff(from: host)
            c.subscribe()
            controller?.disconnect()
            controller = c
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Moves what the controlled device is playing to this one.
    public func bringHere() async {
        guard let controller else { return }
        isTransferring = true
        defer { isTransferring = false }
        lastError = nil
        do {
            try await controller.bringHere(to: host)
            stopControlling()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func send(_ command: RemoteCommand) { controller?.perform(command) }

    // MARK: Device identity

    static var deviceID: String {
        let key = "remote.deviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }

    static var deviceKind: DeviceKind {
        #if os(macOS)
        .mac
        #elseif os(tvOS)
        .tv
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
        #endif
    }

    /// One random key per iCloud account: stored as a synchronizable Keychain item, so every
    /// signed-in device trusts the others. Created by whichever device needs it first.
    static func preSharedKey() -> Data {
        let account = "remote.psk"
        if let stored = Keychain.get(account), let data = Data(base64Encoded: stored), data.count == 32 { return data }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let data = Data(bytes)
        Keychain.set(data.base64EncodedString(), for: account)
        return data
    }
}
