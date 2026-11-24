import Foundation
import Observation
import os
import StereoModel
import StereoPlayback
import StereoRemote
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
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
    /// Name of the controlled device while its connection is being re-established.
    public private(set) var reconnectingTo: String?
    public var lastError: String?

    @ObservationIgnored let host: PlayerRemoteHost
    @ObservationIgnored private let log = Logger(subsystem: "app.stereo", category: "remote")
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?

    init(player: PlayerController) {
        host = PlayerRemoteHost(player: player)
        observeLifecycle()
    }

    public var devices: [DiscoveredDevice] { directory?.devices ?? [] }
    /// True while reconnecting too, so commands aren't silently played on this device instead.
    public var isControllingRemote: Bool { controller?.connection == .connected || reconnectingTo != nil }
    public var remoteState: RemoteState? { controller?.state }
    /// "Living Room Mac", or "Reconnecting to Living Room Mac…" while the link is down.
    public var controlledDeviceLabel: String {
        if let reconnectingTo { return "Reconnecting to \(reconnectingTo)…" }
        return controller?.device?.name ?? ""
    }

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
        cancelReconnect()
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
            cancelReconnect()
            controller?.disconnect()
            let c = try await node.connect(to: device)
            adopt(c, deviceID: device.id)
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func stopControlling() {
        cancelReconnect()
        controller?.disconnect()
        controller = nil
    }

    /// Makes `c` the controlled device and watches for it dropping.
    private func adopt(_ c: RemoteController, deviceID: String) {
        c.subscribe()
        c.onLost = { [weak self] reason in self?.controllerLost(deviceID: deviceID, name: c.device?.name, reason: reason) }
        controller = c
    }

    /// The controlled device went quiet (asleep, out of range, app quit). Keep trying for a while
    /// before falling back to this device's own player.
    private func controllerLost(deviceID: String, name: String?, reason: String?) {
        guard let node else { return }
        log.info("lost controlled device: \(reason ?? "closed")")
        let label = name ?? "the other device"
        reconnectingTo = label
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            let c = await node.reconnect { [weak self] in
                self?.devices.first { $0.id == deviceID }?.endpoint
            }
            guard let self, !Task.isCancelled else { c?.disconnect(); return }
            self.reconnectingTo = nil
            self.reconnectTask = nil
            if let c {
                self.adopt(c, deviceID: deviceID)
            } else {
                self.controller = nil
                self.lastError = "Lost connection to \(label)."
            }
        }
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectingTo = nil
    }

    // MARK: App lifecycle

    /// Listeners and browsers can die while iOS suspends the app or the Mac sleeps; nothing tells
    /// the app, so check on the way back.
    private func observeLifecycle() {
        #if os(iOS) || os(tvOS)
        let center = NotificationCenter.default
        let name = UIApplication.willEnterForegroundNotification
        #elseif os(macOS)
        let center = NSWorkspace.shared.notificationCenter
        let name = NSWorkspace.didWakeNotification
        #endif
        lifecycleTask = Task { [weak self] in
            for await _ in center.notifications(named: name).map({ _ in () }) {
                await self?.recover()
            }
        }
    }

    func recover() async {
        guard let node else { return }
        directory?.restart()
        await node.ensureListening()
    }

    /// Moves what's playing here to `device`, then controls it.
    public func handOff(to device: DiscoveredDevice) async {
        guard let node else { return }
        isTransferring = true
        defer { isTransferring = false }
        lastError = nil
        do {
            let c = try await node.connect(to: device)
            do {
                try await c.handOff(from: host)
            } catch {
                c.disconnect()
                throw error
            }
            cancelReconnect()
            controller?.disconnect()
            adopt(c, deviceID: device.id)
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
