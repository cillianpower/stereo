import SwiftUI
import StereoModel
import StereoRemote

/// Where playback happens: this device, other Stereo devices on the LAN, and AirPlay (iOS).
struct DevicePickerSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let remote = app.remote
        NavigationStack {
            List {
                Section {
                    Button {
                        if remote.isControllingRemote { Task { await remote.bringHere(); dismiss() } }
                        else { dismiss() }
                    } label: {
                        HStack {
                            Label(RemoteCoordinator.deviceName, systemImage: RemoteCoordinator.deviceKind.symbolName)
                            Spacer()
                            if !remote.isControllingRemote { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            else { Text("Bring Here").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                } header: { Text("This Device") }

                Section {
                    if remote.devices.isEmpty {
                        Text("Open Stereo on another device on this network.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(remote.devices) { device in
                        DeviceRow(device: device, isControlled: remote.controller?.device?.id == device.id,
                                  canHandOff: app.player.nowPlaying != nil) { action in
                            Task {
                                switch action {
                                case .control: await remote.control(device)
                                case .handOff: await remote.handOff(to: device)
                                }
                                if remote.lastError == nil { dismiss() }
                            }
                        }
                    }
                } header: { Text("Stereo Devices") }

                #if os(iOS)
                Section {
                    HStack {
                        Label("AirPlay & Bluetooth", systemImage: "airplayaudio")
                        Spacer()
                        RoutePickerButton().frame(width: 32, height: 32).tint(.accentColor)
                    }
                }
                #endif

                if let error = remote.lastError {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .overlay { if remote.isTransferring { ProgressView("Handing off…").padding().background(.regularMaterial, in: .rect(cornerRadius: 12)) } }
            .navigationTitle("Play On")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .frame(minWidth: 360, minHeight: 360)
    }
}

private struct DeviceRow: View {
    enum Action { case control, handOff }
    let device: DiscoveredDevice
    let isControlled: Bool
    let canHandOff: Bool
    let perform: (Action) -> Void

    var body: some View {
        HStack {
            Label(device.name, systemImage: device.kind.symbolName)
            Spacer()
            if isControlled {
                Image(systemName: "checkmark").foregroundStyle(.tint)
            } else {
                Menu {
                    if canHandOff {
                        Button { perform(.handOff) } label: { Label("Move Playback Here", systemImage: "arrow.right.circle") }
                    }
                    Button { perform(.control) } label: { Label("Control", systemImage: "av.remote") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
            }
        }
        .contentShape(.rect)
        .onTapGesture { perform(canHandOff ? .handOff : .control) }
    }
}
