import SwiftUI
import TunerModel

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

    public init(_ source: Source, cornerRadius: CGFloat = 8, size: CGFloat? = nil) {
        self.source = source
        self.cornerRadius = cornerRadius
        self.size = size
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                } else {
                    placeholder
                }
            }
            .frame(width: geo.size.width, height: geo.size.width)
            .clipShape(.rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
            }
            .task(id: TaskKey(source: source, width: geo.size.width)) {
                await load(points: geo.size.width)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(width: size, height: size)
    }

    private struct TaskKey: Hashable { let source: Source; let width: CGFloat }

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

    private func load(points: CGFloat) async {
        guard points > 0 else { return }
        let px = ArtworkPipeline.bucket(for: points, scale: scale)
        let app = self.app
        let loaded: CGImage?
        switch source {
        case .coverArt(let id):
            guard let id else { image = nil; return }
            loaded = await app.artwork.image(key: "cover:\(id)", size: px) { await app.coverArtURL(id, size: px) }
        case .station(let s):
            loaded = await app.artwork.image(key: "station:\(s.id)", size: px) { s.faviconURL }
        case .url(let url, let key):
            loaded = await app.artwork.image(key: key, size: px) { url }
        }
        withAnimation(.easeOut(duration: 0.2)) { image = loaded }
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
        if let c = f.codec { parts.append(c.uppercased()) }
        if let b = f.bitDepth, let r = f.sampleRate { parts.append("\(b)-bit/\(String(format: "%g", Double(r) / 1000)) kHz") }
        else if let br = f.bitRate { parts.append("\(br) kbps") }
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
    let album: Album
    var width: CGFloat?

    var body: some View {
        NavigationLink(value: Route.album(album.id)) {
            VStack(alignment: .leading, spacing: 6) {
                ArtworkView(.coverArt(album.coverArtID))
                VStack(alignment: .leading, spacing: 1) {
                    Text(album.name).font(.subheadline).lineLimit(1).foregroundStyle(.primary)
                    Text(album.artist ?? "").font(.subheadline).lineLimit(1).foregroundStyle(.secondary)
                }
            }
            .frame(width: width)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu { AlbumMenu(album: album) }
    }
}

struct AlbumMenu: View {
    @Environment(AppModel.self) private var app
    let album: Album

    var body: some View {
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
                ArtworkView(.station(station), cornerRadius: 8, size: 48)
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
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title2.bold()).padding(.horizontal)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) { content }
                    .scrollTargetLayout()
                    .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
        }
    }
}
