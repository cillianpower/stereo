#if os(macOS)
import AppKit
import SwiftUI
import StereoModel
import StereoRemote
import StereoStore

extension EnvironmentValues {
    /// True inside the main window's navigation, where album artwork can fly to its page.
    @Entry var usesAlbumHero = false
}

/// Window-level state for the Mac app, kept on `AppModel` so menu commands can reach it.
@MainActor
@Observable
public final class MacShellState {
    public enum Section: Hashable {
        case home, radio, search
        case recentlyPlayed, recentlyAdded, artists, albums, songs, favorites, downloaded
        case playlist(ItemID)
    }

    public enum Panel: String, CaseIterable, Identifiable {
        case lyrics = "Lyrics", queue = "Queue"
        public var id: String { rawValue }
    }

    var section: Section? = .home
    /// One path for the visible section. Changing section and path together keeps them in step.
    var path = NavigationPath()
    /// A page to open once a newly selected section's stack has settled.
    var pendingRoute: Route?
    /// Artwork in flight from a card to its album page.
    var albumHero: AlbumHero?

    struct AlbumHero: Equatable {
        let albumID: ItemID
        let coverArtID: String?
        let from: CGRect
        var to: CGRect?
    }
    var panel: Panel = .queue
    var isPanelVisible = false
    /// Collapsing the sidebar leaves the mini icon rail in its place.
    var sidebarVisibility: NavigationSplitViewVisibility = .all
    var railWidth: CGFloat { sidebarVisibility == .detailOnly ? Metrics.macRail : 0 }
    /// The full-window Now Playing.
    var isNowPlayingExpanded = false
    /// Stays true through the closing animation, after `isNowPlayingExpanded` has gone false.
    var isNowPlayingMounted = false
    /// Drives the animation between the top bar's artwork and the full view.
    var isNowPlayingRevealed = false
    /// True once the full view has taken over from the top bar's artwork.
    var isNowPlayingLive = false
    /// Side of the large artwork, so its image can be ready before the animation starts.
    var nowPlayingArtSide: CGFloat = 0
    /// Where the top bar's artwork sits, which Now Playing grows from and returns to.
    var barArtFrame = CGRect.zero
    /// Width of the content column, which the top bar lays itself out to fit.
    var detailWidth: CGFloat = 930
    /// Where the content column starts in the window.
    var detailMinX: CGFloat = 186
    /// Goes up each time ⌘F is pressed, so the search field takes focus even if already showing.
    var searchRequests = 0

    func show(_ target: Panel) {
        panel = target
        isPanelVisible = true
    }

    /// Opens `target`, or closes the panel if it's already showing.
    func toggle(_ target: Panel) {
        if isPanelVisible, panel == target { isPanelVisible = false } else { show(target) }
    }

    func toggleNowPlaying() {
        isNowPlayingExpanded.toggle()
    }

    /// Picking a section shows its top level.
    func select(_ target: Section) {
        section = target
        path = NavigationPath()
        pendingRoute = nil
        albumHero = nil
    }

    /// Opens an album from a card, flying its artwork from `frame` into place.
    func openAlbum(_ id: ItemID, coverArtID: String?, from frame: CGRect, animated: Bool) {
        albumHero = animated && frame.width > 0 ? AlbumHero(albumID: id, coverArtID: coverArtID, from: frame) : nil
        path.append(Route.album(id))
    }

    /// The album page reporting where its artwork sits.
    func landAlbumHero(_ id: ItemID, at frame: CGRect) {
        guard albumHero?.albumID == id, frame.width > 0, albumHero?.to != frame else { return }
        albumHero?.to = frame
    }

    func open(_ destination: AppDestination) {
        isNowPlayingExpanded = false
        switch destination {
        case .radio:
            select(.radio)
        case .library(.playlist(let id)):
            select(.playlist(id))
        case .library(let route):
            let home: Section = switch route {
            case .artist, .artists: .artists
            case .favoriteSongs: .favorites
            default: .albums
            }
            let isSameSection = section == home
            select(home)
            guard route != .albums, route != .artists, route != .favoriteSongs else { return }
            // A new stack resets its path while it mounts, so a page has to wait for that.
            if isSameSection { path.append(route) } else { pendingRoute = route }
        }
    }

    func focusSearch() {
        isNowPlayingExpanded = false
        select(.search)
        searchRequests += 1
    }
}

/// The main Mac window: sidebar, content, the player in the top bar, and a full-window Now Playing.
struct MacShell: View {
    @Environment(AppModel.self) private var app
    @State private var spaceMonitor: Any?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var shell = app.shell
        ZStack {
            NavigationSplitView(columnVisibility: $shell.sidebarVisibility) {
                MacSidebar()
                    .navigationSplitViewColumnWidth(min: 160, ideal: 186, max: 260)
                    .toolbar(removing: .sidebarToggle)
                    .overlay(alignment: .topTrailing) {
                        MacSidebarToggle().padding(.trailing, 6).ignoresSafeArea(.container, edges: .top)
                    }
            } detail: {
                let section = shell.section ?? .home
                // One stack whose path follows the section, so a page can be opened directly.
                ZStack {
                    NavigationStack(path: $shell.path) {
                        MacSectionView(section: section)
                            .stereoDestinations(isInMainWindow: true)
                    }
                    .toolbar(removing: .title)
                    .environment(\.usesAlbumHero, true)
                    .id(section)
                    // The old stack leaves at once: if it lingered, it would write its path over the new one.
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.985)), removal: .identity))
                    .task(id: section) {
                        guard let route = shell.pendingRoute else { return }
                        try? await Task.sleep(for: .milliseconds(120))
                        guard !Task.isCancelled, shell.pendingRoute == route else { return }
                        shell.pendingRoute = nil
                        shell.path.append(route)
                    }
                }
                .animation(Motion.page, value: section)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    shell.detailWidth = $0.width
                    shell.detailMinX = $0.minX
                }
                // Room for the top bar, which pages scroll beneath.
                .safeAreaPadding(.top, MacBarMetrics.height)
                .safeAreaPadding(.leading, shell.railWidth)
                .ignoresSafeArea(.container, edges: .top)
            }
            // Outside the navigation stack, so pushing a page can't dismiss it.
            .inspector(isPresented: $shell.isPanelVisible) {
                MacSidePanel()
                    .inspectorColumnWidth(min: 240, ideal: 280, max: 380)
            }
            // Hiding the toolbar outright would take the traffic lights with it.
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)

            // One shape for the bar and mini sidebar, so the corner where they meet has no seam.
            Color.clear
                .overlay(alignment: .topLeading) {
                    MacChromeShape(topHeight: Metrics.macTopBar, railWidth: shell.railWidth)
                        .fill(.ultraThinMaterial)
                        .frame(width: shell.detailWidth + shell.railWidth)
                        .offset(x: shell.detailMinX - shell.railWidth)
                }
                .allowsHitTesting(false)
                .ignoresSafeArea(.container, edges: .top)
                .zIndex(0.4)

            if shell.sidebarVisibility == .detailOnly {
                Color.clear
                    .overlay(alignment: .topLeading) { MacSidebarRail() }
                    .ignoresSafeArea(.container, edges: .top)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .zIndex(0.6)
            }

            // Above the split view, because pushed pages draw over anything inside the content column.
            // Hung off an empty view so the bar's width can never hold the window open.
            Color.clear
                .overlay(alignment: .topLeading) {
                    MacPlayerBar(width: shell.detailWidth)
                        .frame(width: shell.detailWidth)
                        .offset(x: shell.detailMinX)
                }
                .ignoresSafeArea(.container, edges: .top)
                .zIndex(0.5)

            if shell.isNowPlayingMounted {
                MacNowPlaying().zIndex(1)
            }

            if let hero = shell.albumHero {
                MacAlbumHeroOverlay(hero: hero) {
                    shell.albumHero = nil
                } onStalled: {
                    if shell.albumHero?.to == nil { shell.albumHero = nil }
                }
                    .id(hero.albumID)
                    .zIndex(2)
            }
        }
        .tint(app.settings.accent.color)
        .onChange(of: shell.isNowPlayingExpanded) { _, expanded in animateNowPlaying(expanded) }
        .frame(minWidth: 900, minHeight: 520)
        .onChange(of: app.pendingDestination, initial: true) { _, destination in
            guard let destination else { return }
            shell.open(destination)
            app.pendingDestination = nil
        }
        .onAppear(perform: installSpaceMonitor)
        .onDisappear {
            if let spaceMonitor { NSEvent.removeMonitor(spaceMonitor) }
            spaceMonitor = nil
        }
    }

    /// Lays the view out unseen, readies the large artwork, then grows it out of the top bar.
    private func animateNowPlaying(_ expanded: Bool) {
        let shell = app.shell
        let animation = reduceMotion ? Animation.easeInOut(duration: 0.15) : Motion.morph
        if expanded {
            shell.isNowPlayingMounted = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(32))
                await prepareNowPlayingArtwork()
                guard shell.isNowPlayingExpanded else { return }
                shell.isNowPlayingLive = true
                try? await Task.sleep(for: .milliseconds(16))
                guard shell.isNowPlayingExpanded else { return }
                withAnimation(animation) { shell.isNowPlayingRevealed = true }
            }
        } else if shell.isNowPlayingLive {
            withAnimation(animation) {
                shell.isNowPlayingRevealed = false
            } completion: {
                guard !shell.isNowPlayingExpanded else { return }
                shell.isNowPlayingLive = false
                shell.isNowPlayingMounted = false
            }
        } else {
            shell.isNowPlayingMounted = false
        }
    }

    /// Waits briefly for the full-size image, so the artwork doesn't fly as a placeholder.
    private func prepareNowPlayingArtwork() async {
        let app = app
        let side = app.shell.nowPlayingArtSide
        guard side > 0 else { return }
        let pixels = ArtworkPipeline.bucket(for: side, scale: NSScreen.main?.backingScaleFactor ?? 2)
        guard app.cachedArtwork(for: app.nowPlayingArtworkSource, pixels: pixels) == nil else { return }
        // Keeps loading if it runs long, so the image still arrives shortly after the animation starts.
        Task { @MainActor in _ = await app.artworkImage(for: app.nowPlayingArtworkSource, pixels: pixels) }
        for _ in 0..<11 where app.cachedArtwork(for: app.nowPlayingArtworkSource, pixels: pixels) == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Space plays and pauses, except while typing. A menu shortcut would swallow it in text fields.
    private func installSpaceMonitor() {
        guard spaceMonitor == nil else { return }
        let app = app
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard event.keyCode == 49, modifiers.isEmpty, !(event.window?.firstResponder is NSText) else { return event }
            if !event.isARepeat { app.toggleTransport() }
            return nil
        }
    }
}

// MARK: Sidebar

private struct MacSidebar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var playlists: [Playlist] = []

    var body: some View {
        let shell = app.shell
        // The list echoes programmatic selection changes, which must not reset an opened page.
        List(selection: Binding(get: { shell.section }, set: { target in
            if let target, target != shell.section { shell.select(target) }
        })) {
            MacSidebarLabel(title: "Search", symbol: "magnifyingglass").tag(MacShellState.Section.search)
            MacSidebarLabel(title: "Home", symbol: "house").tag(MacShellState.Section.home)
            MacSidebarLabel(title: "Radio", symbol: "dot.radiowaves.left.and.right").tag(MacShellState.Section.radio)

            Section("Library") {
                MacSidebarLabel(title: "Recently Played", symbol: "clock.arrow.circlepath").tag(MacShellState.Section.recentlyPlayed)
                MacSidebarLabel(title: "Recently Added", symbol: "clock").tag(MacShellState.Section.recentlyAdded)
                MacSidebarLabel(title: "Artists", symbol: "music.microphone").tag(MacShellState.Section.artists)
                MacSidebarLabel(title: "Albums", symbol: "square.stack").tag(MacShellState.Section.albums)
                MacSidebarLabel(title: "Songs", symbol: "music.note").tag(MacShellState.Section.songs)
                MacSidebarLabel(title: "Favorite Songs", symbol: "star").tag(MacShellState.Section.favorites)
                MacSidebarLabel(title: "Downloaded", symbol: "arrow.down.circle").tag(MacShellState.Section.downloaded)
            }

            if !playlists.isEmpty {
                Section("Playlists") {
                    ForEach(playlists) { playlist in
                        MacSidebarLabel(title: playlist.name, symbol: "music.note.list")
                            .tag(MacShellState.Section.playlist(playlist.id))
                            .contextMenu {
                                Button("Open in New Window") { openWindow(value: Route.playlist(playlist.id)) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.sidebarRowSize, .small)
        .safeAreaInset(edge: .bottom) {
            if let progress = app.syncProgress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Syncing \(progress.phase)…").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .task { for await value in app.store.observePlaylists() { playlists = value } }
    }
}

/// Sidebar rows with Music.app's red icons.
private struct MacSidebarLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint)
        }
    }
}

private struct MacSectionView: View {
    let section: MacShellState.Section

    var body: some View {
        switch section {
        case .home: HomeView()
        case .radio: RadioView()
        case .search: SearchView()
        case .recentlyPlayed: AlbumsView(title: "Recently Played", initialSort: .recentlyPlayed)
        case .recentlyAdded: AlbumsView(title: "Recently Added", initialSort: .recentlyAdded)
        case .artists: ArtistsView()
        case .albums: AlbumsView()
        case .songs: MacSongsView()
        case .favorites: FavoriteSongsView()
        case .downloaded: DownloadedView()
        case .playlist(let id): PlaylistDetailView(playlistID: id)
        }
    }
}

private struct MacSongsView: View {
    @Environment(AppModel.self) private var app
    @State private var tracks: [Track] = []
    @State private var filter = ""

    private var shown: [Track] {
        guard !filter.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.localizedCaseInsensitiveContains(filter)
                || ($0.artist ?? "").localizedCaseInsensitiveContains(filter)
                || ($0.album ?? "").localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        SongTable(tracks: shown) { rows, index in app.player.play(rows, startAt: index, from: .songs) }
            .overlay { if tracks.isEmpty { ContentUnavailableView("No Songs", systemImage: "music.note") } }
            .navigationTitle("Songs")
            .pageHeader("Songs") {
                MacFilterField(text: $filter, prompt: "Filter songs")
                Button { app.player.play(shown, from: .songs, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                    .buttonStyle(.glass)
                    .disabled(shown.isEmpty)
            }
            .task(id: app.librarySyncCount) { tracks = (try? app.store.allTracks()) ?? [] }
    }
}

// MARK: Top bar player

/// How much of the player fits. Controls leave in a fixed order as the content column narrows.
private enum MacBarDensity: Int, Comparable {
    case wide, standard, narrow, tight

    init(width: CGFloat) {
        switch width {
        case 1000...: self = .wide
        case 780...: self = .standard
        case 600...: self = .narrow
        default: self = .tight
        }
    }

    var songWidth: CGFloat {
        switch self {
        case .wide: 250
        case .standard: 220
        case .narrow: 200
        case .tight: 120
        }
    }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Square-celled controls shared by the top bar.
private enum MacBarMetrics {
    static let height = Metrics.macTopBar
    static let button: CGFloat = 28
    /// Square, for a pointer rather than a finger.
    static let railItem: CGFloat = 28
    /// Clears the window's traffic lights when the sidebar is hidden.
    static let trafficLights: CGFloat = 78
}

/// The blurred top strip plus, when the sidebar is collapsed, a column down the left edge.
private struct MacChromeShape: Shape {
    var topHeight: CGFloat
    var railWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: rect.maxX, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX, y: topHeight))
        path.addLine(to: CGPoint(x: railWidth, y: topHeight))
        path.addLine(to: CGPoint(x: railWidth, y: rect.maxY))
        path.addLine(to: CGPoint(x: 0, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Opens from the top bar's artwork out to the whole window.
private struct MacRevealShape: Shape {
    var source: CGRect
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let from = source.width > 0 ? source : CGRect(x: rect.midX, y: 0, width: 1, height: 1)
        let p = max(progress, 0)
        let frame = CGRect(
            x: from.minX + (rect.minX - from.minX) * p,
            y: from.minY + (rect.minY - from.minY) * p,
            width: from.width + (rect.width - from.width) * p,
            height: from.height + (rect.height - from.height) * p
        )
        return Path(roundedRect: frame, cornerRadius: max(14 * (1 - p), 0), style: .continuous)
    }
}

/// Places full-size artwork between the top bar and its resting frame, from one animated value.
private struct MacArtFlight: GeometryEffect {
    var progress: CGFloat
    var source: CGRect
    var target: CGRect

    var animatableData: AnimatablePair<CGFloat, CGRect.AnimatableData> {
        get { AnimatablePair(progress, target.animatableData) }
        set {
            progress = newValue.first
            target.animatableData = newValue.second
        }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        guard size.width > 0, target.width > 0 else { return ProjectionTransform(.identity) }
        let width = source.width + (target.width - source.width) * progress
        let midX = source.midX + (target.midX - source.midX) * progress
        let midY = source.midY + (target.midY - source.midY) * progress
        let scale = width / size.width
        return ProjectionTransform(
            CGAffineTransform(translationX: midX - width / 2, y: midY - width / 2).scaledBy(x: scale, y: scale)
        )
    }
}

/// The top bar's artwork. Hovering shows that it opens Now Playing.
private struct MacBarArtwork: View {
    @Environment(AppModel.self) private var app
    @State private var isHovering = false

    var body: some View {
        let hasItem = app.player.nowPlaying != nil
        Button { app.shell.toggleNowPlaying() } label: {
            NowPlayingArtwork(cornerRadius: 0)
                .frame(width: MacBarMetrics.height, height: MacBarMetrics.height)
                .clipped()
                .overlay {
                    if isHovering, hasItem {
                        ZStack {
                            Color.black.opacity(0.45)
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .transition(.opacity)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(MacPressStyle())
        .disabled(!hasItem)
        .pointerStyle(hasItem ? .link : .default)
        .onHover { hovering in withAnimation(Motion.hover) { isHovering = hovering } }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { app.shell.barArtFrame = $0 }
        // The full view's artwork takes over while it's open, so there's only ever one.
        .opacity(app.shell.isNowPlayingLive ? 0 : 1)
        .help("Open Now Playing")
        .accessibilityLabel("Open Now Playing")
    }
}

private struct MacBarDivider: View {
    var body: some View {
        Rectangle().fill(.primary.opacity(0.09)).frame(width: 0.5, height: 16).accessibilityHidden(true)
    }
}

private struct MacSidebarToggle: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let shell = app.shell
        Button {
            withAnimation(Motion.page) { shell.sidebarVisibility = shell.sidebarVisibility == .detailOnly ? .all : .detailOnly }
        } label: {
            Image(systemName: "sidebar.left").font(.system(size: 12))
                .frame(width: MacBarMetrics.railItem, height: MacBarMetrics.railItem).contentShape(.rect)
        }
        .buttonStyle(MacPressStyle())
        .help("Toggle Sidebar")
        .accessibilityLabel("Toggle Sidebar")
    }
}

/// Stays in one place and dims at the top level, so nothing in the top bar moves as you navigate.
private struct MacBackButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Button { if !app.shell.path.isEmpty { app.shell.path.removeLast() } } label: {
            Image(systemName: "chevron.left").font(.caption.weight(.semibold))
                .frame(width: MacBarMetrics.button, height: MacBarMetrics.height).contentShape(.rect)
        }
        .buttonStyle(MacPressStyle())
        .disabled(app.shell.path.isEmpty)
        .opacity(app.shell.path.isEmpty ? 0.35 : 1)
        .help("Back")
        .accessibilityLabel("Back")
    }
}

/// The player as one flush strip, on the blur each page draws, across the content column, laid out in fixed cells.
private struct MacPlayerBar: View {
    @Environment(AppModel.self) private var app
    let width: CGFloat
    @State private var scrubbing: Double?
    @State private var showRemote = false
    /// The listener's own width for the song cell. Zero follows the window.
    @AppStorage("macBarSongWidth") private var storedSongWidth = 0.0
    @State private var dragStartWidth: CGFloat?

    /// The traffic lights are wider than the mini sidebar, so the bar steps past them.
    private var leadingInset: CGFloat {
        app.shell.railWidth > 0 ? MacBarMetrics.trafficLights - app.shell.railWidth : 0
    }

    private var density: MacBarDensity { MacBarDensity(width: width - leadingInset) }

    private var isTrack: Bool {
        if case .track = app.player.nowPlaying { return true }
        return false
    }

    private var duration: Double { max(app.player.duration ?? 1, 1) }
    private var position: Double { scrubbing ?? app.player.position }

    /// Keeps the progress cell usable however far the partition is dragged.
    private var maxSongWidth: CGFloat {
        let transport = MacBarMetrics.button * (density == .tight ? 3 : 5)
        let accessories: CGFloat = switch density {
        case .wide: 176
        case .standard: MacBarMetrics.button * 4
        case .narrow, .tight: MacBarMetrics.button
        }
        return max(minSongWidth, width - leadingInset - MacBarMetrics.button - transport - accessories - 170)
    }

    private var minSongWidth: CGFloat { 120 }

    private var songWidth: CGFloat {
        let wanted = storedSongWidth > 0 ? CGFloat(storedSongWidth) : density.songWidth
        return min(max(wanted, minSongWidth), maxSongWidth)
    }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: leadingInset)
            MacBackButton()
            MacBarDivider()
            if app.remote.isControllingRemote {
                remote
            } else {
                MacTransportControls(size: .bar, isCompact: density == .tight)
                MacBarDivider()
                song
                MacBarDivider().overlay {
                    MacColumnHandle { delta in
                        let start = dragStartWidth ?? songWidth
                        dragStartWidth = start
                        storedSongWidth = Double(min(max(start + delta, minSongWidth), maxSongWidth))
                    } onEnd: {
                        dragStartWidth = nil
                    } onReset: {
                        dragStartWidth = nil
                        storedSongWidth = 0
                    }
                    .frame(width: 9, height: MacBarMetrics.height)
                    .help("Drag to resize. Double-click to reset.")
                    .accessibilityLabel("Resize Song Column")
                }
                progress
                MacBarDivider()
                MacPlayerAccessories(density: density)
            }
        }
        .frame(height: MacBarMetrics.height)
        .frame(maxWidth: .infinity)
        // Empty parts of the bar still move the window, as a title bar should.
        .background { Color.clear.contentShape(.rect).gesture(WindowDragGesture()) }
        .sheet(isPresented: $showRemote) {
            RemoteNowPlayingView().frame(minWidth: 480, minHeight: 720)
        }
    }

    private var song: some View {
        HStack(spacing: 8) {
            MacBarArtwork()

            HStack(spacing: 5) {
                Text(MacPlayerText.title(app)).font(.system(size: 12, weight: .semibold)).layoutPriority(1)
                if density < .tight, let subtitle = MacPlayerText.barSubtitle(app), !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .contentTransition(.opacity)
            .animation(Motion.page, value: MacPlayerText.title(app))
            Spacer(minLength: 0)
        }
        .padding(.trailing, 8)
        .frame(width: songWidth)
    }

    @ViewBuilder
    private var progress: some View {
        HStack(spacing: 6) {
            if isTrack {
                if density < .tight {
                    Text(Format.duration(position)).frame(width: 34, alignment: .trailing)
                }
                MacTopScrubber(position: app.player.position, duration: duration, scrubbing: $scrubbing) {
                    app.player.seek(to: $0)
                }
                Text("-" + Format.duration(max(0, duration - position))).frame(width: 36, alignment: .leading)
            } else if app.player.nowPlaying != nil {
                Spacer(minLength: 0)
                Text("LIVE").fontWeight(.semibold)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 10.5).monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
    }

    private var remote: some View {
        let controlled = app.remote
        let state = controlled.remoteState ?? RemoteState()
        return HStack(spacing: 0) {
            Button { controlled.send(.togglePlayPause) } label: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: MacBarMetrics.button, height: MacBarMetrics.height).contentShape(.rect)
            }
            .buttonStyle(MacPressStyle())
            .accessibilityLabel(state.isPlaying ? "Pause" : "Play")
            if state.isTrack {
                Button { controlled.send(.next) } label: {
                    Image(systemName: "forward.fill").font(.caption)
                        .frame(width: MacBarMetrics.button, height: MacBarMetrics.height).contentShape(.rect)
                }
                .buttonStyle(MacPressStyle())
                .accessibilityLabel("Next")
            }
            MacBarDivider()
            Button { showRemote = true } label: {
                HStack(spacing: 8) {
                    RemoteArtwork(item: state.item, cornerRadius: 0).frame(width: MacBarMetrics.height, height: MacBarMetrics.height).clipped()
                    Text(state.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(controlled.controlledDeviceLabel).font(.system(size: 12)).foregroundStyle(.tint).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            MacBarDivider()
            DevicesButton().frame(width: MacBarMetrics.button, height: MacBarMetrics.height)
        }
    }
}

/// The position bar. Mouse handling is in AppKit because a title bar otherwise treats a drag as
/// moving the window.
private struct MacTopScrubber: View {
    let position: Double
    let duration: Double
    @Binding var scrubbing: Double?
    let onSeek: (Double) -> Void
    @State private var isHovering = false

    var body: some View {
        let shown = min(max((scrubbing ?? position) / duration, 0), 1)
        let isActive = isHovering || scrubbing != nil
        GeometryReader { geometry in
            let thickness: CGFloat = isActive ? 4 : 3
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.18)).frame(height: thickness)
                Capsule().fill(.tint).frame(width: max(thickness, geometry.size.width * shown), height: thickness)
                if isActive {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                        .frame(width: 9, height: 9)
                        .offset(x: geometry.size.width * shown - 4.5)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 13)
        .overlay {
            MacScrubSurface { fraction in
                scrubbing = fraction * duration
            } onEnd: { fraction in
                onSeek(fraction * duration)
                scrubbing = nil
            }
        }
        .onHover { hovering in withAnimation(Motion.hover) { isHovering = hovering } }
        .accessibilityElement()
        .accessibilityLabel("Playback Position")
        .accessibilityValue(Format.duration(scrubbing ?? position))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(min(position + 5, duration))
            case .decrement: onSeek(max(position - 5, 0))
            @unknown default: break
            }
        }
    }
}

private struct MacScrubSurface: NSViewRepresentable {
    let onChange: (Double) -> Void
    let onEnd: (Double) -> Void

    func makeNSView(context: Context) -> MacScrubNSView { MacScrubNSView() }

    func updateNSView(_ view: MacScrubNSView, context: Context) {
        view.onChange = onChange
        view.onEnd = onEnd
    }
}

final class MacScrubNSView: NSView {
    var onChange: ((Double) -> Void)?
    var onEnd: ((Double) -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func fraction(_ event: NSEvent) -> Double {
        guard bounds.width > 0 else { return 0 }
        return min(max(convert(event.locationInWindow, from: nil).x / bounds.width, 0), 1)
    }

    override func mouseDown(with event: NSEvent) { onChange?(fraction(event)) }
    override func mouseDragged(with event: NSEvent) { onChange?(fraction(event)) }
    override func mouseUp(with event: NSEvent) { onEnd?(fraction(event)) }
}

private struct MacPlayerAccessories: View {
    @Environment(AppModel.self) private var app
    let density: MacBarDensity
    @State private var showVolume = false
    @State private var showMore = false
    @State private var showDevices = false

    private var isTrack: Bool {
        if case .track = app.player.nowPlaying { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 0) {
            if density == .wide {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(width: MacBarMetrics.button, height: MacBarMetrics.height)
                volumeSlider.frame(width: 58).padding(.trailing, 6)
            } else if density == .standard {
                iconButton("speaker.wave.2.fill", label: "Volume") { showVolume.toggle() }
                    .popover(isPresented: $showVolume, arrowEdge: .bottom) {
                        volumeSlider.frame(width: 140).padding(12)
                    }
            }
            if density <= .standard {
                panelButton(.lyrics, symbol: "quote.bubble").disabled(!isTrack)
                panelButton(.queue, symbol: "list.bullet").disabled(!isTrack)
                iconButton(devicesSymbol, label: "Devices") { showDevices = true }
            } else {
                iconButton("ellipsis", label: "More Controls") { showMore.toggle() }
                    .popover(isPresented: $showMore, arrowEdge: .bottom) { more }
            }
        }
        .font(.caption)
        .sheet(isPresented: $showDevices) { DevicePickerSheet() }
    }

    private var devicesSymbol: String {
        app.remote.isControllingRemote ? "hifispeaker.2.fill" : "hifispeaker.2"
    }

    private var volumeSlider: some View {
        @Bindable var player = app.player
        return Slider(value: $player.volume, in: 0...1)
            .controlSize(.mini)
            .labelsHidden()
            .accessibilityLabel("Volume")
    }

    /// Everything the current width has no room for.
    private var more: some View {
        let player = app.player
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary).frame(width: 18)
                volumeSlider
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            Divider()
            if density == .tight {
                moreRow("Shuffle", symbol: "shuffle", isOn: player.queue.isShuffled) { player.setShuffle(!player.queue.isShuffled) }
                    .disabled(!isTrack)
                moreRow("Repeat", symbol: player.queue.repeatMode == .one ? "repeat.1" : "repeat", isOn: player.queue.repeatMode != .off) { player.cycleRepeat() }
                    .disabled(!isTrack)
            }
            moreRow("Lyrics", symbol: "quote.bubble", isOn: isPanelShowing(.lyrics)) { togglePanel(.lyrics) }
                .disabled(!isTrack)
            moreRow("Queue", symbol: "list.bullet", isOn: isPanelShowing(.queue)) { togglePanel(.queue) }
                .disabled(!isTrack)
            moreRow("Devices", symbol: devicesSymbol, isOn: app.remote.isControllingRemote) {
                showMore = false
                showDevices = true
            }
        }
        .padding(6)
        .frame(width: 190)
    }

    private func moreRow(_ title: String, symbol: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18)
                    .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func isPanelShowing(_ panel: MacShellState.Panel) -> Bool {
        app.shell.isPanelVisible && app.shell.panel == panel
    }

    private func togglePanel(_ panel: MacShellState.Panel) {
        withAnimation(Motion.page) { app.shell.toggle(panel) }
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: MacBarMetrics.button, height: MacBarMetrics.height)
                .contentShape(.rect)
        }
        .buttonStyle(MacPressStyle())
        .help(label)
        .accessibilityLabel(label)
    }

    private func panelButton(_ panel: MacShellState.Panel, symbol: String) -> some View {
        Button { togglePanel(panel) } label: {
            Image(systemName: symbol)
                .foregroundStyle(isPanelShowing(panel) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: MacBarMetrics.button, height: MacBarMetrics.height)
                .contentShape(.rect)
        }
        .buttonStyle(MacPressStyle())
        .help(panel.rawValue)
        .accessibilityLabel(panel.rawValue)
    }
}

private enum MacPlayerText {
    @MainActor static func title(_ app: AppModel) -> String {
        if case .station = app.player.nowPlaying {
            return app.radioEnrichment?.title ?? app.player.streamTitle?.title ?? app.player.nowPlaying?.title ?? ""
        }
        return app.player.nowPlaying?.title ?? "Not Playing"
    }

    /// Just the artist for a song: the artwork beside it already says which album.
    @MainActor static func barSubtitle(_ app: AppModel) -> String? {
        if case .track(let track) = app.player.nowPlaying { return track.artist }
        return subtitle(app)
    }

    @MainActor static func subtitle(_ app: AppModel) -> String? {
        if case .station(let s) = app.player.nowPlaying {
            return [app.radioEnrichment?.artist ?? app.player.streamTitle?.artist, s.name].compactMap { $0 }.joined(separator: " — ")
        }
        return app.player.nowPlaying?.subtitle
    }
}

/// Shuffle, previous, play, next and repeat, shared by the top bar and Now Playing.
private struct MacTransportControls: View {
    enum Size { case bar, large }
    @Environment(AppModel.self) private var app
    let size: Size
    var isCompact = false

    private var isTrack: Bool {
        if case .track = app.player.nowPlaying { return true }
        return false
    }

    var body: some View {
        let player = app.player
        HStack(spacing: size == .bar ? 0 : 26) {
            if !isCompact {
                toggle(symbol: "shuffle", isOn: player.queue.isShuffled, help: "Shuffle") {
                    player.setShuffle(!player.queue.isShuffled)
                }
            }
            skip("backward.fill", help: "Previous") { player.previous() }
            Button { app.toggleTransport() } label: {
                Image(systemName: player.isPlaying ? (isTrack ? "pause.fill" : "stop.fill") : "play.fill")
                    .font(size == .bar ? .body : .system(size: 30))
                    .frame(width: size == .bar ? MacBarMetrics.button : 38, height: size == .bar ? MacBarMetrics.height : 38)
                    .contentTransition(.symbolEffect(.replace))
                    .contentShape(.rect)
            }
            .buttonStyle(MacPressStyle())
            .disabled(player.nowPlaying == nil)
            .help(player.isPlaying ? "Pause" : "Play")
            skip("forward.fill", help: "Next") { player.next() }
            if !isCompact {
                toggle(symbol: player.queue.repeatMode == .one ? "repeat.1" : "repeat",
                       isOn: player.queue.repeatMode != .off, help: "Repeat") { player.cycleRepeat() }
            }
        }
    }

    private func skip(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(size == .bar ? .caption : .title2)
                .frame(width: size == .bar ? MacBarMetrics.button : nil, height: size == .bar ? MacBarMetrics.height : nil)
                .contentShape(.rect)
        }
        .buttonStyle(MacPressStyle())
        .disabled(!isTrack)
        .help(help)
    }

    private func toggle(symbol: String, isOn: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(size == .bar ? .system(size: 10) : .body)
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size == .bar ? MacBarMetrics.button : nil, height: size == .bar ? MacBarMetrics.height : nil)
                .contentShape(.rect)
        }
        .buttonStyle(MacPressStyle())
        .disabled(!isTrack)
        .help(help)
    }
}

/// Controls squash slightly under the pointer and spring back.
private struct MacPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.84 : 1)
            .animation(Motion.hover, value: configuration.isPressed)
    }
}

private struct MacScrubber: View {
    @Environment(AppModel.self) private var app
    @Binding var scrubbing: Double?

    var body: some View {
        let duration = max(app.player.duration ?? 1, 1)
        let position = scrubbing ?? app.player.position
        HStack(spacing: 8) {
            Text(Format.duration(position)).frame(width: 42, alignment: .trailing)
            SeekSlider(position: app.player.position, duration: duration, scrubbing: $scrubbing) { app.player.seek(to: $0) }
                .controlSize(.mini)
            Text("-" + Format.duration(max(0, duration - position))).frame(width: 42, alignment: .leading)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

// MARK: Full-window Now Playing

private struct MacNowPlaying: View {
    @Environment(AppModel.self) private var app
    @State private var scrubbing: Double?
    @State private var lyrics: Lyrics?
    @State private var pane: MacShellState.Panel?
    /// Once the listener picks a pane, new tracks stop opening or closing lyrics on their own.
    @State private var didChoosePane = false
    /// Where the large artwork rests, measured from an empty placeholder in the layout.
    @State private var artTarget = CGRect.zero

    private var artworkSource: ArtworkView.Source { app.nowPlayingArtworkSource }

    private var track: Track? {
        if case .track(let t) = app.player.nowPlaying { return t }
        return nil
    }

    private var trackID: ItemID? { track?.id }

    private var nextTrack: Track? {
        let queue = app.player.queue
        return queue.upNext.first ?? queue.remainingContext.first
    }

    var body: some View {
        let isRevealed = app.shell.isNowPlayingRevealed
        ZStack {
            ZStack {
                AmbientBackground(source: artworkSource, isAnimating: app.player.isPlaying)
                    .overlay(Color.black.opacity(0.18))

                HStack(spacing: 40) {
                    player.frame(maxWidth: 440)
                    if let pane {
                        Group {
                            switch pane {
                            case .lyrics:
                                LyricsView(lyrics: lyrics, position: app.player.position) { app.player.seek(to: $0) }
                            case .queue:
                                QueueView()
                            }
                        }
                        .frame(maxWidth: 560, maxHeight: .infinity)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 62)
                .padding(.bottom, 16)
                .opacity(isRevealed ? 1 : 0)
                .animation(isRevealed ? .easeOut(duration: 0.28).delay(0.14) : .easeOut(duration: 0.1), value: isRevealed)
                .allowsHitTesting(isRevealed)
            }
            .clipShape(MacRevealShape(source: app.shell.barArtFrame, progress: isRevealed ? 1 : 0))
            .ignoresSafeArea()

            flyingArtwork(isRevealed: isRevealed)
        }
        .foregroundStyle(.white)
        .tint(.white)
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .topTrailing) {
            Button { app.shell.toggleNowPlaying() } label: {
                Image(systemName: "xmark").font(.callout.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .keyboardShortcut(.cancelAction)
            .padding(10)
            .opacity(isRevealed ? 1 : 0)
            .animation(isRevealed ? .easeOut(duration: 0.2).delay(0.24) : .easeOut(duration: 0.08), value: isRevealed)
            .help("Close Now Playing")
            .accessibilityLabel("Close Now Playing")
        }
        .opacity(app.shell.isNowPlayingLive ? 1 : 0)
        .task(id: trackID) {
            lyrics = nil
            guard let track else { return }
            let loaded = try? await app.library?.lyrics(for: track)
            guard !Task.isCancelled else { return }
            lyrics = loaded
            guard !didChoosePane else { return }
            withAnimation(Motion.morph) {
                if loaded?.isSynced == true { pane = .lyrics } else if pane == .lyrics { pane = nil }
            }
        }
    }

    private var player: some View {
        VStack(spacing: 12) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    artTarget = $0
                    app.shell.nowPlayingArtSide = $0.width
                }
                .frame(maxHeight: .infinity)
            info
            if trackID != nil { MacScrubber(scrubbing: $scrubbing) }
            GlassEffectContainer(spacing: 12) {
                HStack {
                    paneButton(.lyrics, symbol: "quote.bubble").disabled(trackID == nil)
                    Spacer()
                    MacTransportControls(size: .large)
                    Spacer()
                    paneButton(.queue, symbol: "list.bullet").disabled(trackID == nil)
                }
            }
            if let nextTrack {
                Button { app.player.next() } label: {
                    HStack(spacing: 5) {
                        Text("Next").fontWeight(.semibold)
                        Text([nextTrack.title, nextTrack.artist].compactMap { $0 }.joined(separator: " · "))
                            .lineLimit(1)
                            .opacity(0.72)
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Skip to \(nextTrack.title)")
            }
            if case .station = app.player.nowPlaying {
                HStack(spacing: 12) {
                    IdentifyButton()
                    IdentificationBanner()
                }
            }
        }
    }

    /// One piece of artwork that travels between the top bar and its place in this layout. It's
    /// always drawn at full size and transformed, so it stays sharp and never reloads in flight.
    private func flyingArtwork(isRevealed: Bool) -> some View {
        let side = max(artTarget.width, 1)
        return NowPlayingArtwork(cornerRadius: 8)
            // The move animates; the image inside must not fade in along with it.
            .transaction { $0.animation = nil }
            .frame(width: side, height: side)
            .shadow(color: .black.opacity(isRevealed ? 0.38 : 0), radius: 20, y: 10)
            .scaleEffect(isRevealed && !app.player.isPlaying ? 0.88 : 1)
            .animation(.spring(response: 0.55, dampingFraction: 0.62), value: app.player.isPlaying)
            .modifier(MacArtFlight(progress: isRevealed ? 1 : 0, source: app.shell.barArtFrame, target: artTarget))
            .animation(Motion.morph, value: artTarget)
            .opacity(app.shell.isNowPlayingLive && artTarget.width > 0 ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    /// Title, links to the artist and album, and what is actually being played.
    private var info: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(MacPlayerText.title(app)).font(.title3.bold()).lineLimit(2)
            if let track {
                linkText(track.artist, route: track.artistID.map { .artist($0) })
                    .font(.callout.weight(.medium))
                linkText([track.album, track.year.map(String.init)].compactMap { $0 }.joined(separator: " · "),
                         route: track.albumID.map { .album($0) })
                    .font(.callout)
                    .opacity(0.72)
                facts(track).padding(.top, 4)
            } else if let subtitle = MacPlayerText.subtitle(app) {
                Text(subtitle).font(.callout).opacity(0.72).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func linkText(_ text: String?, route: Route?) -> some View {
        if let text, !text.isEmpty {
            if let route {
                Button { app.shell.open(.library(route)) } label: {
                    Text(text).lineLimit(1).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Go to \(text)")
            } else {
                Text(text).lineLimit(1)
            }
        }
    }

    private func facts(_ track: Track) -> some View {
        let detail = Format.formatDetail(track.format)
        let values = [Format.qualityBadge(track.format), detail.isEmpty ? nil : detail, track.genre].compactMap { $0 }
        return HStack(spacing: 5) {
            ForEach(values, id: \.self) { value in
                Text(value)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.14), in: .capsule)
            }
        }
    }

    private func paneButton(_ target: MacShellState.Panel, symbol: String) -> some View {
        Button {
            didChoosePane = true
            withAnimation(Motion.morph) { pane = pane == target ? nil : target }
        } label: {
            Image(systemName: symbol).font(.callout).frame(width: 30, height: 30).contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(pane == target ? .regular.tint(.white.opacity(0.28)).interactive() : .regular.interactive(), in: .circle)
        .help(target.rawValue)
        .accessibilityLabel(target.rawValue)
    }
}

// MARK: Mini sidebar

/// The collapsed sidebar: icons on the same blur as the top bar, which each page draws.
private struct MacSidebarRail: View {
    @Environment(AppModel.self) private var app
    @State private var playlists: [Playlist] = []

    private static let main: [(String, String, MacShellState.Section)] = [
        ("Search", "magnifyingglass", .search),
        ("Home", "house", .home),
        ("Radio", "dot.radiowaves.left.and.right", .radio),
    ]

    private static let library: [(String, String, MacShellState.Section)] = [
        ("Recently Played", "clock.arrow.circlepath", .recentlyPlayed),
        ("Recently Added", "clock", .recentlyAdded),
        ("Artists", "music.microphone", .artists),
        ("Albums", "square.stack", .albums),
        ("Songs", "music.note", .songs),
        ("Favorite Songs", "star", .favorites),
        ("Downloaded", "arrow.down.circle", .downloaded),
    ]

    var body: some View {
        VStack(spacing: 2) {
            MacSidebarToggle()
                .frame(maxWidth: .infinity)
                .padding(.top, MacBarMetrics.height)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Self.main, id: \.0) { item($0.0, symbol: $0.1, section: $0.2) }
                    Divider().padding(.horizontal, 10).padding(.vertical, 3)
                    ForEach(Self.library, id: \.0) { item($0.0, symbol: $0.1, section: $0.2) }
                    if !playlists.isEmpty {
                        Divider().padding(.horizontal, 10).padding(.vertical, 3)
                        ForEach(playlists) { item($0.name, symbol: "music.note.list", section: .playlist($0.id)) }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.never)
        }
        .frame(width: Metrics.macRail)
        .frame(maxHeight: .infinity, alignment: .top)
        .background { Color.clear.contentShape(.rect).gesture(WindowDragGesture()) }
        .task { for await value in app.store.observePlaylists() { playlists = value } }
    }

    private func item(_ title: String, symbol: String, section: MacShellState.Section) -> some View {
        let isSelected = app.shell.section == section
        return Button {
            if !isSelected || !app.shell.path.isEmpty { app.shell.select(section) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.tint)
                .frame(width: MacBarMetrics.railItem, height: MacBarMetrics.railItem)
                .background(.primary.opacity(isSelected ? 0.14 : 0), in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(MacPressStyle())
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The drag handle between the song and progress cells. In AppKit so it doesn't move the window.
private struct MacColumnHandle: NSViewRepresentable {
    let onChange: (CGFloat) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void

    func makeNSView(context: Context) -> MacColumnHandleNSView { MacColumnHandleNSView() }

    func updateNSView(_ view: MacColumnHandleNSView, context: Context) {
        view.onChange = onChange
        view.onEnd = onEnd
        view.onReset = onReset
    }
}

final class MacColumnHandleNSView: NSView {
    var onChange: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    var onReset: (() -> Void)?
    private var startX: CGFloat = 0

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func mouseDown(with event: NSEvent) {
        startX = event.locationInWindow.x
        if event.clickCount == 2 { onReset?() }
    }

    override func mouseDragged(with event: NSEvent) { onChange?(event.locationInWindow.x - startX) }
    override func mouseUp(with event: NSEvent) { onEnd?() }
}

// MARK: Side panel

private struct MacSidePanel: View {
    @Environment(AppModel.self) private var app
    @State private var lyrics: Lyrics?

    private var trackID: ItemID? {
        if case .track(let t) = app.player.nowPlaying { return t.id }
        return nil
    }

    var body: some View {
        @Bindable var shell = app.shell
        VStack(spacing: 6) {
            Picker("Panel", selection: $shell.panel.animation(Motion.page)) {
                ForEach(MacShellState.Panel.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding([.horizontal, .top], 8)

            Group {
                switch shell.panel {
                case .lyrics:
                    LyricsView(lyrics: lyrics, position: app.player.position, fontSize: 20) { app.player.seek(to: $0) }
                        .padding(.horizontal, 16)
                        .frame(maxHeight: .infinity)
                case .queue:
                    QueueView()
                }
            }
            .transition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: trackID) {
            lyrics = nil
            guard case .track(let track) = app.player.nowPlaying else { return }
            lyrics = try? await app.library?.lyrics(for: track)
        }
    }
}

// MARK: Secondary windows

/// An album, artist or playlist in its own window.
public struct MacDetailWindow: View {
    @Environment(AppModel.self) private var app
    let route: Route

    public init(route: Route) { self.route = route }

    public var body: some View {
        NavigationStack {
            RouteDestination(route: route).stereoDestinations()
        }
        .frame(minWidth: 620, minHeight: 480)
        .tint(app.settings.accent.color)
    }
}

/// The Settings window (⌘,).
public struct MacSettingsView: View {
    @Environment(AppModel.self) private var app
    public init() {}

    public var body: some View {
        Group {
            if app.phase == .ready {
                SettingsView()
            } else {
                ContentUnavailableView("Not Signed In", systemImage: "person.crop.circle")
            }
        }
        .frame(width: 560, height: 640)
        .tint(app.settings.accent.color)
    }
}

extension AppModel {
    var nowPlayingArtworkSource: ArtworkView.Source {
        switch player.nowPlaying {
        case .track(let t): .coverArt(t.coverArtID)
        case .station(let s):
            if let art = radioEnrichment?.artworkURL { .url(art, key: "itunes:\(art.absoluteString)") } else { .station(s) }
        case nil: .coverArt(nil)
        }
    }

    /// Plays or pauses whichever device this Mac is controlling.
    func toggleTransport() {
        if remote.isControllingRemote { remote.send(.togglePlayPause) } else { player.togglePlayPause() }
    }

    func adjustVolume(by delta: Float) {
        player.volume = min(max(player.volume + delta, 0), 1)
    }
}
#endif
