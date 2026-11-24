import SwiftUI
import StereoModel

// MARK: Artwork

/// Square artwork with a placeholder, loaded through `ArtworkPipeline`.
public struct ArtworkView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.displayScale) private var scale

    public enum Source: Hashable {
        case coverArt(String?)
        case station(Station)
        case url(URL?, key: String)
    }

    let source: Source
    var cornerRadius: CGFloat = 8
    var size: CGFloat?

    @State private var image: CGImage?
    @State private var pixels = 0

    public init(_ source: Source, cornerRadius: CGFloat = 8, size: CGFloat? = nil) {
        self.source = source
        self.cornerRadius = cornerRadius
        self.size = size
    }

    public var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                } else {
                    placeholder
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
            }
            // Only a change of size bucket reloads, so resizing the window doesn't refetch art.
            .onGeometryChange(for: Int.self) { proxy in
                proxy.size.width > 0 ? ArtworkPipeline.bucket(for: proxy.size.width, scale: scale) : 0
            } action: { bucket in
                pixels = bucket
                // Cached art is ready before the first frame, so it never flashes a placeholder.
                if image == nil, bucket > 0, let hit = app.cachedArtwork(for: source, pixels: bucket) { image = hit }
            }
            .task(id: TaskKey(source: source, pixels: pixels)) { await load() }
            .frame(width: size, height: size)
    }

    private struct TaskKey: Hashable { let source: Source; let pixels: Int }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: placeholderSymbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
        }
    }

    private var placeholderSymbol: String {
        if case .station = source { return "dot.radiowaves.left.and.right" }
        return "music.note"
    }

    private func load() async {
        guard pixels > 0 else { return }
        if let hit = app.cachedArtwork(for: source, pixels: pixels) {
            image = hit
            return
        }
        let loaded = await app.artworkImage(for: source, pixels: pixels)
        // A view that scrolled away keeps what it has rather than clearing to a placeholder.
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.18)) { image = loaded }
    }
}

extension ArtworkView.Source {
    var cacheKey: String? {
        switch self {
        case .coverArt(let id): id.map { "cover:\($0)" }
        case .station(let station): "station:\(station.id)"
        case .url(_, let key): key
        }
    }
}

extension AppModel {
    func cachedArtwork(for source: ArtworkView.Source, pixels: Int) -> CGImage? {
        source.cacheKey.flatMap { artwork.cachedImage(key: $0, size: pixels) }
    }

    func artworkImage(for source: ArtworkView.Source, pixels: Int) async -> CGImage? {
        guard let key = source.cacheKey else { return nil }
        switch source {
        case .coverArt(let id):
            guard let id else { return nil }
            return await artwork.image(key: key, size: pixels) { await self.coverArtURL(id, size: pixels) }
        case .station(let station):
            let url = station.faviconURL
            return await artwork.image(key: key, size: pixels) { url }
        case .url(let url, _):
            return await artwork.image(key: key, size: pixels) { url }
        }
    }
}

// MARK: Formatting

enum Format {
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let s = Int(seconds.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func duration(_ d: Duration?) -> String {
        guard let d else { return "" }
        return duration(TimeInterval(d.components.seconds))
    }

    static func longDuration(_ d: Duration?) -> String? {
        guard let d else { return nil }
        let minutes = Int(d.components.seconds) / 60
        return minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min"
    }

    static func qualityBadge(_ f: AudioFormat) -> String? {
        if f.isHiRes { return "Hi-Res Lossless" }
        if f.isLossless { return "Lossless" }
        return nil
    }

    static func formatDetail(_ f: AudioFormat) -> String {
        var parts: [String] = []
        if let codec = f.codec, !codec.isEmpty { parts.append(codec.uppercased()) }
        // Lossy files report a bit depth of zero, so depth only appears when it means something.
        if let depth = f.bitDepth, depth > 0 { parts.append("\(depth)-bit") }
        if let rate = f.sampleRate, rate > 0 {
            parts.append((Double(rate) / 1000).formatted(.number.precision(.fractionLength(0...1))) + " kHz")
        }
        if !f.isLossless, let bitRate = f.bitRate, bitRate > 0 { parts.append("\(bitRate) kbps") }
        return parts.joined(separator: " · ")
    }
}

// MARK: Rows & cards

/// A song row with Apple Music–style gestures: swipe right to Play Next, left to Add to Queue,
/// and a long-press menu.
struct TrackRow: View {
    @Environment(AppModel.self) private var app
    let track: Track
    var showArtwork = false
    var showNumber = false
    let onPlay: () -> Void

    private var isCurrent: Bool {
        if case .track(let t) = app.player.nowPlaying { return t.id == track.id }
        return false
    }

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                if showArtwork {
                    ArtworkView(.coverArt(track.coverArtID), cornerRadius: 4, size: 44)
                } else if showNumber {
                    Group {
                        if isCurrent {
                            Image(systemName: "waveform").symbolEffect(.variableColor.iterative, isActive: app.player.isPlaying)
                                .foregroundStyle(.tint)
                        } else {
                            Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout.monospacedDigit())
                    .frame(width: 24, alignment: .trailing)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                    if showArtwork, let artist = track.artist {
                        Text(artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if track.starred != nil {
                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(.secondary)
                }
                Text(Format.duration(track.duration))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { app.player.playNext([track]) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                .tint(.indigo)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button { app.player.addToQueue([track]) } label: { Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") }
                .tint(.orange)
        }
        .contextMenu { TrackMenu(track: track) }
        .draggable(track.id.description)
    }
}

struct TrackMenu: View {
    @Environment(AppModel.self) private var app
    let track: Track

    var body: some View {
        Button { app.player.playNext([track]) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { app.player.addToQueue([track]) } label: { Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") }
        Button { Task { await app.startRadio(from: track) } } label: { Label("Create Station", systemImage: "dot.radiowaves.left.and.right") }
        Divider()
        Button { app.toggleStar(track) } label: {
            track.starred == nil ? Label("Favorite", systemImage: "star") : Label("Undo Favorite", systemImage: "star.slash")
        }
        if let albumID = track.albumID {
            NavigationLink(value: Route.album(albumID)) { Label("Go to Album", systemImage: "square.stack") }
        }
        if let artistID = track.artistID {
            NavigationLink(value: Route.artist(artistID)) { Label("Go to Artist", systemImage: "music.microphone") }
        }
    }
}

struct AlbumCard: View {
    @Environment(AppModel.self) private var app
    let album: Album
    var width: CGFloat?
    @State private var isHovering = false
    #if os(macOS)
    @Environment(\.usesAlbumHero) private var usesAlbumHero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Updated while scrolling without redrawing the card; only read on click.
    @State private var artFrame = ArtFrame()
    private final class ArtFrame { var rect = CGRect.zero }
    #endif

    /// In the main window the artwork flies to the album page. Other windows use a plain link.
    @ViewBuilder
    private func albumLink<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        #if os(macOS)
        if usesAlbumHero {
            Button {
                app.shell.openAlbum(album.id, coverArtID: album.coverArtID, from: artFrame.rect, animated: !reduceMotion)
            } label: { label() }
        } else {
            NavigationLink(value: Route.album(album.id)) { label() }
        }
        #else
        NavigationLink(value: Route.album(album.id)) { label() }
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            albumLink {
                ArtworkView(.coverArt(album.coverArtID), cornerRadius: Metrics.cardRadius)
            }
            .buttonStyle(.plain)
            #if os(macOS)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { artFrame.rect = $0 }
            .overlay(alignment: .bottomTrailing) {
                AlbumCardPlayButton(album: album, isHovering: isHovering)
            }
            .hoverLift()
            #endif
            albumLink {
                VStack(alignment: .leading, spacing: 1) {
                    Text(album.name).font(.caption.weight(.medium)).lineLimit(1).foregroundStyle(.primary)
                    Text(album.artist ?? "").font(.caption).lineLimit(1).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .frame(width: width)
        .contentShape(.rect)
        .onHover { hovering in withAnimation(Motion.hover) { isHovering = hovering } }
        .contextMenu { AlbumMenu(album: album) }
    }
}

#if os(macOS)
/// Plays the album, then shows and controls its state. Separate from the card so that playback
/// changes only redraw this button.
private struct AlbumCardPlayButton: View {
    @Environment(AppModel.self) private var app
    let album: Album
    let isHovering: Bool
    @State private var isStarting = false
    @State private var showsSpinner = false

    private var isCurrent: Bool {
        if case .track(let track) = app.player.nowPlaying { return track.albumID == album.id }
        return false
    }

    /// Only a real start counts. Streaming rebuffers briefly and often, which would make it flicker.
    private var wantsSpinner: Bool { isStarting || (isCurrent && app.player.status == .loading) }

    private var isPlaying: Bool { isCurrent && app.player.isPlaying }

    var body: some View {
        if isHovering || isCurrent || isStarting {
            Button(action: activate) {
                Group {
                    if showsSpinner {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.caption)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: Metrics.cardPlayButton, height: Metrics.cardPlayButton)
                .contentShape(.circle)
                // A quick start never shows a spinner at all.
                .task(id: wantsSpinner) {
                    guard wantsSpinner else { showsSpinner = false; return }
                    try? await Task.sleep(for: .milliseconds(350))
                    if !Task.isCancelled { showsSpinner = true }
                }
            }
            .buttonStyle(.plain)
            .glassEffect(isCurrent ? .regular.tint(.accentColor.opacity(0.55)).interactive() : .regular.interactive(), in: .circle)
            .padding(5)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
            .help(isPlaying ? "Pause" : "Play")
            .accessibilityLabel("\(isPlaying ? "Pause" : "Play") \(album.name)")
        }
    }

    private func activate() {
        guard !isStarting else { return }
        if isCurrent {
            app.toggleTransport()
            return
        }
        isStarting = true
        Task {
            await app.play(album: album.id)
            isStarting = false
        }
    }
}
#endif

/// A few lines about an album or artist, which open up in place.
struct AboutBlurb: View {
    let title: String
    let text: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(Metrics.shelfTitle)
            Text(text)
                #if os(macOS)
                .font(.callout)
                .textSelection(.enabled)
                #else
                .font(.subheadline)
                #endif
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : 4)
            if text.count > 180 {
                Button(isExpanded ? "Less" : "More") {
                    withAnimation(Motion.page) { isExpanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AlbumMenu: View {
    @Environment(AppModel.self) private var app
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    let album: Album

    var body: some View {
        #if os(macOS)
        Button { openWindow(value: Route.album(album.id)) } label: { Label("Open in New Window", systemImage: "macwindow.badge.plus") }
        Divider()
        #endif
        Button { Task { await app.play(album: album.id) } } label: { Label("Play", systemImage: "play") }
        Button { Task { await app.play(album: album.id, shuffled: true) } } label: { Label("Shuffle", systemImage: "shuffle") }
        Button {
            Task { if let d = await app.albumDetail(album.id) { app.player.playNext(d.tracks) } }
        } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button {
            Task { if let d = await app.albumDetail(album.id) { app.player.addToQueue(d.tracks) } }
        } label: { Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") }
        Divider()
        Button { app.toggleStar(album) } label: {
            album.starred == nil ? Label("Favorite", systemImage: "star") : Label("Undo Favorite", systemImage: "star.slash")
        }
    }
}

struct StationRow: View {
    @Environment(AppModel.self) private var app
    let station: Station

    private var isCurrent: Bool {
        if case .station(let s) = app.player.nowPlaying { return s.id == station.id }
        return false
    }

    var body: some View {
        Button { app.player.play(station) } label: {
            HStack(spacing: 12) {
                ArtworkView(.station(station), cornerRadius: Metrics.cardRadius, size: Metrics.stationArtwork)
                VStack(alignment: .leading, spacing: 2) {
                    Text(station.name).lineLimit(1)
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if isCurrent {
                    Image(systemName: "waveform").foregroundStyle(.tint)
                        .symbolEffect(.variableColor.iterative, isActive: app.player.isPlaying)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu { StationMenu(station: station) }
    }

    private var detail: String {
        var parts: [String] = []
        if let c = station.countryCode { parts.append(c) }
        if let codec = station.codec { parts.append(station.bitRate.map { "\(codec) \($0)k" } ?? codec) }
        parts += station.tags.prefix(3)
        return parts.joined(separator: " · ")
    }
}

struct StationMenu: View {
    @Environment(AppModel.self) private var app
    let station: Station

    var body: some View {
        let favorite = (try? app.store.isFavorite(station)) ?? false
        Button { app.player.play(station) } label: { Label("Play", systemImage: "play") }
        Button { try? app.store.setFavorite(!favorite, station: station) } label: {
            favorite ? Label("Remove from Favorites", systemImage: "star.slash") : Label("Add to Favorites", systemImage: "star")
        }
        if let homepage = station.homepage {
            Link(destination: homepage) { Label("Station Website", systemImage: "safari") }
        }
        if case .custom = station.origin {
            Button(role: .destructive) { try? app.store.deleteStation(station) } label: { Label("Delete", systemImage: "trash") }
        }
    }
}

/// A titled horizontal shelf, like Apple Music's Home.
struct Shelf<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Metrics.shelfTitle).padding(.horizontal, Metrics.pagePadding)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Metrics.gridSpacing) { content }
                    .scrollTargetLayout()
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.vertical, 6)   // room for the hover lift and its shadow
            }
            .scrollClipDisabled()
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
        }
    }
}
