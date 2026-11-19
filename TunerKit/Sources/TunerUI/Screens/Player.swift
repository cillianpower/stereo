import SwiftUI
import TunerModel

extension PlayableItem {
    var subtitle: String? {
        switch self {
        case .track(let t): [t.artist, t.album].compactMap { $0 }.joined(separator: " — ")
        case .station(let s): s.tags.prefix(3).joined(separator: ", ")
        }
    }
}

/// Artwork for whatever's playing: cover art, or the radio song's looked-up artwork, or the station logo.
struct NowPlayingArtwork: View {
    @Environment(AppModel.self) private var app
    var cornerRadius: CGFloat = 8

    var body: some View {
        switch app.player.nowPlaying {
        case .track(let t): ArtworkView(.coverArt(t.coverArtID), cornerRadius: cornerRadius)
        case .station(let s):
            if let art = app.radioEnrichment?.artworkURL {
                ArtworkView(.url(art, key: "itunes:\(art.absoluteString)"), cornerRadius: cornerRadius)
            } else {
                ArtworkView(.station(s), cornerRadius: cornerRadius)
            }
        case nil: ArtworkView(.coverArt(nil), cornerRadius: cornerRadius)
        }
    }
}

// MARK: Mini player

struct MiniPlayer: View {
    @Environment(AppModel.self) private var app
    @Binding var showNowPlaying: Bool

    var body: some View {
        let player = app.player
        HStack(spacing: 12) {
            NowPlayingArtwork(cornerRadius: 6).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
                if let sub = subtitle { Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if player.status == .loading || player.status == .buffering {
                ProgressView().controlSize(.small)
            }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            if case .track = player.nowPlaying {
                Button { player.next() } label: { Image(systemName: "forward.fill").font(.title3).frame(width: 32, height: 32) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .contentShape(.rect)
        .onTapGesture { showNowPlaying = true }
        .gesture(DragGesture(minimumDistance: 20).onEnded { value in
            if value.translation.height < -30 { showNowPlaying = true }
            else if value.translation.width < -50 { player.next() }
            else if value.translation.width > 50 { player.previous() }
        })
    }

    private var title: String {
        if case .station = app.player.nowPlaying, let t = app.player.streamTitle?.title { return t }
        return app.player.nowPlaying?.title ?? "Not Playing"
    }

    private var subtitle: String? {
        if case .station(let s) = app.player.nowPlaying {
            return [app.player.streamTitle?.artist, s.name].compactMap { $0 }.joined(separator: " — ")
        }
        return app.player.nowPlaying?.subtitle
    }
}

// MARK: Now Playing

struct NowPlayingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var panel: Panel = .artwork
    @State private var scrubbing: Double?
    @State private var artworkOffset: CGFloat = 0
    @State private var lyrics: Lyrics?

    enum Panel { case artwork, lyrics, queue }

    var body: some View {
        let player = app.player
        ZStack {
            background
            VStack(spacing: 20) {
                Capsule().fill(.secondary).frame(width: 40, height: 5).padding(.top, 8)
                    .onTapGesture { dismiss() }

                Group {
                    switch panel {
                    case .artwork: artwork
                    case .lyrics: LyricsView(lyrics: lyrics, position: player.position) { player.seek(to: $0) }
                    case .queue: QueueView()
                    }
                }
                .frame(maxHeight: .infinity)

                titles
                IdentificationBanner()
                    .animation(.snappy, value: app.identification)
                if case .track = player.nowPlaying { scrubber }
                transport
                bottomBar
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
            .frame(maxWidth: 560)
        }
        .foregroundStyle(.white)
        .tint(.white)
        .task(id: trackID) { await loadLyrics() }
    }

    private var trackID: ItemID? {
        if case .track(let t) = app.player.nowPlaying { return t.id }
        return nil
    }

    private func loadLyrics() async {
        lyrics = nil
        guard case .track(let t) = app.player.nowPlaying, let lib = app.library else { return }
        lyrics = try? await lib.lyrics(for: t)
    }

    /// Blurred, saturated artwork filling the screen — the Apple Music look.
    private var background: some View {
        GeometryReader { geo in
            NowPlayingArtwork(cornerRadius: 0)
                .frame(width: geo.size.width * 1.6, height: geo.size.width * 1.6)
                .position(x: geo.size.width / 2, y: geo.size.height / 3)
                .blur(radius: 80)
                .saturation(1.6)
                .overlay(Color.black.opacity(0.35))
        }
        .ignoresSafeArea()
        .background(Color.black)
        .animation(.easeInOut(duration: 0.8), value: trackID)
    }

    /// Swipe the artwork left or right to skip, and it shrinks when paused, as in Apple Music.
    private var artwork: some View {
        NowPlayingArtwork(cornerRadius: 12)
            .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
            .scaleEffect(app.player.isPlaying ? 1 : 0.85)
            .animation(.spring(response: 0.45, dampingFraction: 0.7), value: app.player.isPlaying)
            .offset(x: artworkOffset)
            .gesture(DragGesture(minimumDistance: 10)
                .onChanged { artworkOffset = $0.translation.width * 0.6 }
                .onEnded { value in
                    if value.translation.width < -80 { app.player.next() }
                    else if value.translation.width > 80 { app.player.previous() }
                    withAnimation(.spring) { artworkOffset = 0 }
                })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var titles: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(primaryTitle).font(.title3.bold()).lineLimit(1)
                Text(secondaryTitle).font(.title3).opacity(0.7).lineLimit(1)
            }
            Spacer()
            if case .track(let t) = app.player.nowPlaying {
                Button { app.toggleStar(t) } label: {
                    Image(systemName: t.starred == nil ? "star" : "star.fill").font(.title3)
                }
                .buttonStyle(.plain)
                Menu { TrackMenu(track: t) } label: {
                    Image(systemName: "ellipsis.circle.fill").font(.title2).symbolRenderingMode(.hierarchical)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
            } else if case .station(let s) = app.player.nowPlaying, let match = app.radioLibraryMatch {
                Button { app.player.play([match], from: .search) } label: {
                    Label("In Library", systemImage: "music.note.house")
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Plays this song from your library instead of \(s.name)")
            }
        }
    }

    private var primaryTitle: String {
        if case .station = app.player.nowPlaying {
            return app.radioEnrichment?.title ?? app.player.streamTitle?.title ?? app.player.nowPlaying?.title ?? ""
        }
        return app.player.nowPlaying?.title ?? "Not Playing"
    }

    private var secondaryTitle: String {
        switch app.player.nowPlaying {
        case .track(let t): return t.artist ?? ""
        case .station(let s): return [app.radioEnrichment?.artist ?? app.player.streamTitle?.artist, s.name].compactMap { $0 }.joined(separator: " — ")
        case nil: return ""
        }
    }

    private var scrubber: some View {
        let duration = max(app.player.duration ?? 1, 1)
        let position = scrubbing ?? app.player.position
        return VStack(spacing: 4) {
            Slider(value: Binding(get: { position }, set: { scrubbing = $0 }), in: 0...duration) { editing in
                if !editing, let s = scrubbing { app.player.seek(to: s); scrubbing = nil }
            }
            HStack {
                Text(Format.duration(position))
                Spacer()
                if case .track(let t) = app.player.nowPlaying, let badge = Format.qualityBadge(t.format) {
                    Text(badge).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.white.opacity(0.15), in: .capsule)
                        .help(Format.formatDetail(t.format))
                }
                Spacer()
                Text("-" + Format.duration(max(0, duration - position)))
            }
            .font(.caption.monospacedDigit())
            .opacity(0.7)
        }
    }

    private var transport: some View {
        let player = app.player
        let isTrack: Bool = { if case .track = player.nowPlaying { return true } else { return false } }()
        return HStack(spacing: 48) {
            Button { player.previous() } label: { Image(systemName: "backward.fill") }
                .disabled(!isTrack).opacity(isTrack ? 1 : 0.3)
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? (isTrack ? "pause.fill" : "stop.fill") : "play.fill")
                    .font(.system(size: 44))
                    .contentTransition(.symbolEffect(.replace))
            }
            Button { player.next() } label: { Image(systemName: "forward.fill") }
                .disabled(!isTrack).opacity(isTrack ? 1 : 0.3)
        }
        .font(.system(size: 30))
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }

    private var bottomBar: some View {
        HStack {
            if case .track = app.player.nowPlaying {
                toggle(.lyrics, symbol: "quote.bubble")
            }
            Spacer()
            IdentifyButton()
            Spacer()
            #if os(iOS)
            RoutePickerButton().frame(width: 32, height: 32)
            #endif
            Spacer()
            if case .track = app.player.nowPlaying {
                toggle(.queue, symbol: "list.bullet")
            }
        }
        .font(.title3)
    }

    private func toggle(_ target: Panel, symbol: String) -> some View {
        Button { withAnimation(.snappy) { panel = panel == target ? .artwork : target } } label: {
            Image(systemName: symbol)
                .padding(8)
                .background(panel == target ? AnyShapeStyle(.white.opacity(0.25)) : AnyShapeStyle(.clear), in: .circle)
        }
        .buttonStyle(.plain)
    }
}

struct LyricsView: View {
    let lyrics: Lyrics?
    let position: TimeInterval
    let seek: (TimeInterval) -> Void

    var body: some View {
        if let lyrics, !lyrics.lines.isEmpty {
            let active = lyrics.activeLineIndex(at: .seconds(position))
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { i, line in
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.title2.bold())
                                .opacity(!lyrics.isSynced || i == active ? 1 : 0.35)
                                .blur(radius: lyrics.isSynced && active != nil && i != active ? 0.6 : 0)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                                .onTapGesture { if let s = line.start { seek(TimeInterval(s.components.seconds) + Double(s.components.attoseconds) / 1e18) } }
                        }
                    }
                    .padding(.vertical, 120)
                }
                .scrollIndicators(.hidden)
                .onChange(of: active) { _, new in
                    guard let new else { return }
                    withAnimation(.easeInOut(duration: 0.5)) { proxy.scrollTo(new, anchor: .center) }
                }
            }
        } else {
            ContentUnavailableView("No Lyrics", systemImage: "quote.bubble")
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

struct QueueView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let queue = app.player.queue
        List {
            if !queue.upNext.isEmpty {
                Section {
                    ForEach(queue.upNext) { row($0) }
                        .onDelete { app.player.removeFromUpNext(at: $0) }
                        .onMove { app.player.moveUpNext(from: $0, to: $1) }
                } header: {
                    Text("Up Next").foregroundStyle(.white.opacity(0.7))
                }
            }
            Section {
                ForEach(queue.remainingContext) { track in
                    Button { app.player.jump(to: track) } label: { row(track) }.buttonStyle(.plain)
                }
            } header: {
                HStack {
                    Text(contextTitle).foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Button { app.player.setShuffle(!queue.isShuffled) } label: {
                        Image(systemName: "shuffle").foregroundStyle(queue.isShuffled ? .white : .white.opacity(0.5))
                    }
                    Button { app.player.cycleRepeat() } label: {
                        Image(systemName: queue.repeatMode == .one ? "repeat.1" : "repeat")
                            .foregroundStyle(queue.repeatMode == .off ? .white.opacity(0.5) : .white)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var contextTitle: String {
        switch app.player.queue.contextSource {
        case .album(_, let name), .playlist(_, let name), .artist(_, let name): "Playing from \(name)"
        case .radio: "Station"
        default: "Continue Playing"
        }
    }

    private func row(_ track: Track) -> some View {
        HStack(spacing: 12) {
            ArtworkView(.coverArt(track.coverArtID), cornerRadius: 4, size: 40)
            VStack(alignment: .leading) {
                Text(track.title).lineLimit(1)
                Text(track.artist ?? "").font(.caption).opacity(0.6).lineLimit(1)
            }
        }
        .listRowBackground(Color.clear)
    }
}

#if os(iOS)
import AVKit

/// AirPlay picker. Tuner devices join this sheet when handoff lands (M4).
struct RoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = .white
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif
