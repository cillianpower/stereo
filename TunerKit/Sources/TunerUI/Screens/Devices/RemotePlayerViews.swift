import SwiftUI
import TunerModel
import TunerRemote

/// Artwork for the remote device's current item.
private struct RemoteArtwork: View {
    let item: RemoteItem?
    var cornerRadius: CGFloat = 8

    var body: some View {
        switch item {
        case .track(let t): ArtworkView(.coverArt(t.coverArtID), cornerRadius: cornerRadius)
        case .station(let s): ArtworkView(.station(s), cornerRadius: cornerRadius)
        case nil: ArtworkView(.coverArt(nil), cornerRadius: cornerRadius)
        }
    }
}

private extension RemoteState {
    var title: String {
        if case .station = item, let t = streamTitle.map(StreamTitle.init(raw:))?.title { return t }
        return item?.title ?? "Not Playing"
    }

    var subtitle: String {
        switch item {
        case .track(let t): [t.artist, t.album].compactMap { $0 }.joined(separator: " — ")
        case .station(let s): [streamTitle.map(StreamTitle.init(raw:))?.artist, s.name].compactMap { $0 }.joined(separator: " — ")
        case nil: ""
        }
    }

    var isTrack: Bool { if case .track = item { true } else { false } }
}

/// Mini player while controlling another device.
struct RemoteMiniPlayer: View {
    @Environment(AppModel.self) private var app
    @Binding var showNowPlaying: Bool

    var body: some View {
        let remote = app.remote
        let state = remote.remoteState ?? RemoteState()
        HStack(spacing: 12) {
            RemoteArtwork(item: state.item, cornerRadius: 6).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 0) {
                Text(state.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Label(remote.controller?.device?.name ?? "", systemImage: remote.controller?.device?.kind.symbolName ?? "hifispeaker")
                    .font(.caption).foregroundStyle(.tint).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { remote.send(.togglePlayPause) } label: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            if state.isTrack {
                Button { remote.send(.next) } label: { Image(systemName: "forward.fill").font(.title3).frame(width: 32, height: 32) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .contentShape(.rect)
        .onTapGesture { showNowPlaying = true }
    }
}

/// Full Now Playing for a remote device: progress is drawn locally from the position anchor.
struct RemoteNowPlayingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var scrubbing: Double?
    @State private var volume: Double?
    @State private var showDevices = false

    var body: some View {
        let remote = app.remote
        let state = remote.remoteState ?? RemoteState()
        ZStack {
            GeometryReader { geo in
                RemoteArtwork(item: state.item, cornerRadius: 0)
                    .frame(width: geo.size.width * 1.6, height: geo.size.width * 1.6)
                    .position(x: geo.size.width / 2, y: geo.size.height / 3)
                    .blur(radius: 80).saturation(1.6).overlay(Color.black.opacity(0.35))
            }
            .ignoresSafeArea()
            .background(Color.black)

            VStack(spacing: 20) {
                Capsule().fill(.secondary).frame(width: 40, height: 5).padding(.top, 8).onTapGesture { dismiss() }
                Label("Playing on \(remote.controller?.device?.name ?? "")", systemImage: remote.controller?.device?.kind.symbolName ?? "hifispeaker")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.white.opacity(0.15), in: .capsule)

                RemoteArtwork(item: state.item, cornerRadius: 12)
                    .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
                    .scaleEffect(state.isPlaying ? 1 : 0.85)
                    .animation(.spring(response: 0.45, dampingFraction: 0.7), value: state.isPlaying)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title).font(.title3.bold()).lineLimit(1)
                    Text(state.subtitle).font(.title3).opacity(0.7).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if state.isTrack, let duration = state.duration, duration > 0 {
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        let position = scrubbing ?? min(state.anchor.position(at: context.date), duration)
                        VStack(spacing: 4) {
                            Slider(value: Binding(get: { position }, set: { scrubbing = $0 }), in: 0...duration) { editing in
                                if !editing, let s = scrubbing { remote.send(.seek(s)); scrubbing = nil }
                            }
                            HStack {
                                Text(Format.duration(position))
                                Spacer()
                                Text("-" + Format.duration(max(0, duration - position)))
                            }
                            .font(.caption.monospacedDigit()).opacity(0.7)
                        }
                    }
                }

                HStack(spacing: 48) {
                    Button { remote.send(.previous) } label: { Image(systemName: "backward.fill") }
                        .disabled(!state.isTrack).opacity(state.isTrack ? 1 : 0.3)
                    Button { remote.send(.togglePlayPause) } label: {
                        Image(systemName: state.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 44))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    Button { remote.send(.next) } label: { Image(systemName: "forward.fill") }
                        .disabled(!state.isTrack).opacity(state.isTrack ? 1 : 0.3)
                }
                .font(.system(size: 30))
                .buttonStyle(.plain)

                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill").opacity(0.6)
                    Slider(value: Binding(get: { volume ?? Double(state.volume) }, set: { volume = $0 })) { editing in
                        if !editing, let v = volume { remote.send(.setVolume(Float(v))); volume = nil }
                    }
                    Image(systemName: "speaker.wave.3.fill").opacity(0.6)
                }

                HStack {
                    Button { Task { await remote.bringHere(); dismiss() } } label: {
                        Label("Bring Here", systemImage: "arrow.down.circle")
                    }
                    Spacer()
                    Button { showDevices = true } label: { Image(systemName: "hifispeaker.2") }
                    Spacer()
                    Button { remote.stopControlling(); dismiss() } label: { Label("Disconnect", systemImage: "xmark.circle") }
                }
                .buttonStyle(.plain)
                .font(.callout)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
            .frame(maxWidth: 560)
        }
        .foregroundStyle(.white)
        .tint(.white)
        .sheet(isPresented: $showDevices) { DevicePickerSheet() }
        .onChange(of: remote.isControllingRemote) { _, controlling in if !controlling { dismiss() } }
    }
}

/// Button that opens the device picker; lights up while controlling another device.
struct DevicesButton: View {
    @Environment(AppModel.self) private var app
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            Image(systemName: app.remote.isControllingRemote ? "hifispeaker.2.fill" : "hifispeaker.2")
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $show) { DevicePickerSheet() }
    }
}
