#if os(macOS)
import SwiftUI
import TunerModel

/// An album or playlist page: large artwork with details beside the track list on wide windows,
/// stacked on narrow ones, over a wash of the artwork's color.
struct MacCollectionPage: View {
    @Environment(AppModel.self) private var app
    let coverArtID: String?
    let title: String
    var artist: String?
    var artistID: ItemID?
    let details: String
    let tracks: [Track]
    var showsTrackArtwork = false
    /// Set on album pages, so the artwork can receive the flight from the card that opened it.
    var albumID: ItemID?
    var info: AlbumInfo?
    /// Page actions shown beside Play and Shuffle, such as download.
    var actions: AnyView?
    /// Plays from `index`, optionally shuffled.
    let play: (_ index: Int, _ shuffled: Bool) -> Void

    @State private var pageWidth: CGFloat = 900

    private var isWide: Bool { pageWidth >= 720 }
    private var artSize: CGFloat {
        isWide ? min(max(pageWidth * 0.34, 240), 380) : min(pageWidth - Metrics.pagePadding * 2, 300)
    }

    private var isPlayingHere: Bool {
        guard app.player.isPlaying, case .track(let current) = app.player.nowPlaying else { return false }
        return tracks.contains { $0.id == current.id }
    }

    private var isReceivingFlight: Bool {
        albumID != nil && app.shell.albumHero?.albumID == albumID
    }

    var body: some View {
        ScrollView {
            Group {
                if isWide {
                    HStack(alignment: .top, spacing: 22) {
                        VStack(alignment: .leading, spacing: 14) {
                            artwork
                            about
                        }
                        .frame(width: artSize)
                        VStack(alignment: .leading, spacing: 12) {
                            header
                            trackList
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        artwork
                        header
                        trackList
                        about
                    }
                }
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(alignment: .top) {
            AmbientBackground(source: .coverArt(coverArtID), isAnimating: isPlayingHere)
                .frame(height: 430)
                .opacity(0.6)
                .mask(LinearGradient(stops: [.init(color: .black.opacity(0.95), location: 0),
                                             .init(color: .black.opacity(0.5), location: 0.55),
                                             .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
    }

    private var artwork: some View {
        ArtworkView(.coverArt(coverArtID), cornerRadius: Metrics.cardRadius + 2, size: artSize)
            .shadow(color: .black.opacity(0.34), radius: 16, y: 8)
            .opacity(isReceivingFlight ? 0 : 1)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                if let albumID { app.shell.landAlbumHero(albumID, at: frame) }
            }
    }

    @ViewBuilder
    private var about: some View {
        if let info { MacAlbumAbout(info: info) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 26, weight: .bold)).lineLimit(3)
            if let artist {
                if let artistID {
                    NavigationLink(value: Route.artist(artistID)) {
                        Text(artist).font(.title3).foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(artist).font(.title3).foregroundStyle(.tint)
                }
            }
            Text(details).font(.caption).foregroundStyle(.secondary).padding(.top, 1)
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    Button { play(0, false) } label: {
                        Label("Play", systemImage: "play.fill").frame(minWidth: 54)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(tracks.isEmpty)
                    Button { play(0, true) } label: {
                        Label("Shuffle", systemImage: "shuffle").frame(minWidth: 54)
                    }
                    .buttonStyle(.glass)
                    .disabled(tracks.isEmpty)
                    if let actions { actions }
                }
            }
            .padding(.top, 9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trackList: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                // Playlists number by position; albums use the track number.
                MacTrackRow(track: track, number: showsTrackArtwork ? index + 1 : track.trackNumber,
                            showsArtwork: showsTrackArtwork) { play(index, false) }
                    .scrollTransition(.animated(Motion.page), axis: .vertical) { row, phase in
                        row.opacity(phase.isIdentity ? 1 : 0.35)
                            .offset(y: phase == .bottomTrailing ? 4 : 0)
                    }
            }
        }
    }
}

/// A compact search field for page headers.
struct MacFilterField: View {
    @Binding var text: String
    let prompt: String
    var width: CGFloat = 180
    /// Each change moves keyboard focus here.
    var focusRequests = 0
    var focusOnAppear = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.caption)
                .focused($isFocused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.caption) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: 24)
        .glassEffect(.regular, in: .rect(cornerRadius: 8))
        .onAppear { if focusOnAppear { isFocused = true } }
        .onChange(of: focusRequests) { isFocused = true }
    }
}

/// Facts and notes about an album. Rows without data are left out.
private struct MacAlbumAbout: View {
    let info: AlbumInfo
    @State private var isExpanded = false

    private var facts: [(String, String)] {
        var rows: [(String, String)] = []
        if let released = releasedText { rows.append(("Released", released)) }
        if !info.labels.isEmpty { rows.append(("Label", info.labels.joined(separator: ", "))) }
        var type = info.releaseTypes
        if info.isCompilation, !type.contains(where: { $0.caseInsensitiveCompare("Compilation") == .orderedSame }) {
            type.append("Compilation")
        }
        if !type.isEmpty { rows.append(("Type", type.map(\.localizedCapitalized).joined(separator: ", "))) }
        if let version = info.version { rows.append(("Version", version)) }
        if !info.genres.isEmpty { rows.append(("Genres", info.genres.joined(separator: ", "))) }
        if !info.moods.isEmpty { rows.append(("Moods", info.moods.joined(separator: ", "))) }
        return rows
    }

    private var releasedText: String? {
        guard let released = info.released, let year = released.year else { return nil }
        guard let month = released.month,
              let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: released.day ?? 1)) else {
            return String(year)
        }
        return released.day == nil ? date.formatted(.dateTime.month(.wide).year())
                                   : date.formatted(.dateTime.day().month(.wide).year())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let notes = info.notes {
                VStack(alignment: .leading, spacing: 3) {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(isExpanded ? nil : 6)
                        .textSelection(.enabled)
                    if notes.count > 280 {
                        Button(isExpanded ? "Less" : "More") {
                            withAnimation(Motion.page) { isExpanded.toggle() }
                        }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                    }
                }
            }
            if !facts.isEmpty {
                Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 3) {
                    ForEach(facts, id: \.0) { label, value in
                        GridRow {
                            Text(label).foregroundStyle(.tertiary)
                            Text(value).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                .font(.caption)
            }
            if info.lastFmURL != nil || info.musicBrainzURL != nil {
                HStack(spacing: 10) {
                    if let url = info.lastFmURL { Link("Last.fm", destination: url) }
                    if let url = info.musicBrainzURL { Link("MusicBrainz", destination: url) }
                }
                .font(.caption.weight(.medium))
            }
        }
        .transition(.opacity)
    }
}

/// The artwork travelling from a card to its place on the album page.
struct MacAlbumHeroOverlay: View {
    let hero: MacShellState.AlbumHero
    let onFinish: () -> Void
    /// Called if the page may never have appeared.
    let onStalled: () -> Void
    @State private var hasLanded = false

    private var rect: CGRect { hasLanded ? (hero.to ?? hero.from) : hero.from }

    var body: some View {
        ArtworkView(.coverArt(hero.coverArtID), cornerRadius: hasLanded ? Metrics.cardRadius + 2 : Metrics.cardRadius)
            .frame(width: rect.width, height: rect.height)
            .shadow(color: .black.opacity(0.36), radius: hasLanded ? 16 : 6, y: hasLanded ? 8 : 3)
            .position(x: rect.midX, y: rect.midY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .animation(Motion.morph, value: hero.to)
            .onChange(of: hero.to != nil, initial: true) { _, hasTarget in
                guard hasTarget, !hasLanded else { return }
                withAnimation(Motion.morph, completionCriteria: .logicallyComplete) {
                    hasLanded = true
                } completion: {
                    onFinish()
                }
            }
            // If the page never appears (it can't load), don't leave art floating.
            .task {
                try? await Task.sleep(for: .seconds(1.2))
                if !Task.isCancelled { onStalled() }
            }
    }
}

private struct MacTrackRow: View {
    @Environment(AppModel.self) private var app
    let track: Track
    let number: Int?
    let showsArtwork: Bool
    let onPlay: () -> Void
    @State private var isHovering = false

    private var isCurrent: Bool {
        if case .track(let current) = app.player.nowPlaying { return current.id == track.id }
        return false
    }

    var body: some View {
        HStack(spacing: 8) {
            leading.frame(width: 20)
            if showsArtwork {
                ArtworkView(.coverArt(track.coverArtID), cornerRadius: 3, size: 26)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).font(.callout).fontWeight(isCurrent ? .semibold : .regular).lineLimit(1)
                if showsArtwork, let artist = track.artist {
                    Text(artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if showsArtwork, let album = track.album {
                Text(album).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: 240, alignment: .leading)
            }
            if track.starred != nil {
                Image(systemName: "star.fill").font(.caption2).foregroundStyle(.secondary)
            }
            Menu { TrackMenu(track: track) } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(isHovering ? 1 : 0)
                .accessibilityLabel("More for \(track.title)")
            Text(Format.duration(track.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .frame(height: showsArtwork ? 40 : 31)
        .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5).padding(.leading, 34) }
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(.primary.opacity(isHovering ? 0.07 : 0))
        }
        .contentShape(.rect(cornerRadius: 5))
        .onHover { hovering in withAnimation(Motion.hover) { isHovering = hovering } }
        .onTapGesture(count: 2, perform: onPlay)
        .contextMenu { TrackMenu(track: track) }
        .draggable(TrackDrag.payload([track]))
    }

    @ViewBuilder
    private var leading: some View {
        if isCurrent, !isHovering {
            PlayingBars(isPlaying: app.player.isPlaying)
        } else if isHovering {
            Button {
                if isCurrent { app.toggleTransport() } else { onPlay() }
            } label: {
                Image(systemName: isCurrent && app.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.caption)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .transition(.scale(scale: 0.7).combined(with: .opacity))
            .accessibilityLabel(isCurrent && app.player.isPlaying ? "Pause" : "Play \(track.title)")
        } else {
            Text(number.map(String.init) ?? "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
#endif
