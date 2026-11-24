import SwiftUI
import StereoModel
import StereoStore

public enum Route: Hashable, Codable, Sendable {
    case album(ItemID)
    case artist(ItemID)
    case playlist(ItemID)
    case albums
    case artists
    case playlists
    case favoriteSongs
}

struct RouteDestination: View {
    let route: Route
    /// The Mac's main window: it has a fixed back button in the top bar, so the player never shifts.
    var isInMainWindow = false
    #if os(macOS)
    @Environment(AppModel.self) private var app
    #endif

    var body: some View {
        page
            #if os(macOS)
            // Pushed pages don't inherit the stack's side inset, so they keep clear of the mini sidebar here.
            .safeAreaPadding(.leading, isInMainWindow ? app.shell.railWidth : 0)
            .navigationBarBackButtonHidden(isInMainWindow)
            .environment(\.usesAlbumHero, isInMainWindow)
            #else
            .pageTopFade()
            #endif
    }

    @ViewBuilder
    private var page: some View {
        switch route {
        case .album(let id): AlbumDetailView(albumID: id)
        case .artist(let id): ArtistDetailView(artistID: id)
        case .playlist(let id): PlaylistDetailView(playlistID: id)
        case .albums: AlbumsView()
        case .artists: ArtistsView()
        case .playlists: PlaylistsView()
        case .favoriteSongs: FavoriteSongsView()
        }
    }
}

extension View {
    /// Registers every `Route` destination. Apply once per NavigationStack.
    func stereoDestinations(isInMainWindow: Bool = false) -> some View {
        navigationDestination(for: Route.self) { RouteDestination(route: $0, isInMainWindow: isInMainWindow) }
    }
}

// MARK: Library root

struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var recent: [Album] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                VStack(spacing: 0) {
                    NavigationLink(value: Route.playlists) { rowLabel("Playlists", symbol: "music.note.list") }
                    rowDivider
                    NavigationLink(value: Route.artists) { rowLabel("Artists", symbol: "music.microphone") }
                    rowDivider
                    NavigationLink(value: Route.albums) { rowLabel("Albums", symbol: "square.stack") }
                    rowDivider
                    NavigationLink {
                        AlbumsView(title: "Recently Played", initialSort: .recentlyPlayed).pageTopFade()
                    } label: { rowLabel("Recently Played", symbol: "clock.arrow.circlepath") }
                    rowDivider
                    NavigationLink(value: Route.favoriteSongs) { rowLabel("Favorite Songs", symbol: "star") }
                    rowDivider
                    NavigationLink { DownloadedView().pageTopFade() } label: { rowLabel("Downloaded", symbol: "arrow.down.circle") }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 14))

                if let progress = app.syncProgress {
                    HStack {
                        ProgressView()
                        Text("Syncing \(progress.phase)…").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        if let total = progress.albumsTotal {
                            Text("\(progress.albumsDone)/\(total)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }

                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Recently Added").font(.headline)
                            Spacer()
                            NavigationLink("See All") {
                                AlbumsView(title: "Recently Added", initialSort: .recentlyAdded).pageTopFade()
                            }
                            .font(.subheadline)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Metrics.gridSpacing)], spacing: Metrics.gridRowSpacing) {
                            ForEach(recent) { AlbumCard(album: $0) }
                        }
                    }
                }
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .navigationTitle("Library")
        .task {
            for await albums in app.store.observeAlbums(sortedBy: .recentlyAdded, limit: Self.recentLimit) { recent = albums }
        }
        .refreshable { await app.sync() }
    }

    private static let recentLimit = 12

    private var rowDivider: some View {
        Divider().padding(.leading, 36)
    }

    private func rowLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 24)
            Text(title).font(.subheadline.weight(.medium))
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(height: 44)
        .contentShape(.rect)
    }
}

// MARK: Albums

struct AlbumsView: View {
    @Environment(AppModel.self) private var app
    @State private var albums: [Album] = []
    @State private var sort: LibraryStore.AlbumSort
    @State private var filter = ""
    private let title: String

    init(title: String = "Albums", initialSort: LibraryStore.AlbumSort = .name) {
        self.title = title
        _sort = State(initialValue: initialSort)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                Text("Title").tag(LibraryStore.AlbumSort.name)
                Text("Artist").tag(LibraryStore.AlbumSort.artist)
                Text("Recently Added").tag(LibraryStore.AlbumSort.recentlyAdded)
                Text("Recently Played").tag(LibraryStore.AlbumSort.recentlyPlayed)
                Text("Year").tag(LibraryStore.AlbumSort.year)
            }
        } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
    }

    private var shown: [Album] {
        guard !filter.isEmpty else { return albums }
        return albums.filter { $0.name.localizedCaseInsensitiveContains(filter) || ($0.artist ?? "").localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.cardMinimum), spacing: Metrics.gridSpacing)], spacing: Metrics.gridRowSpacing) {
                ForEach(shown) { AlbumCard(album: $0) }
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .overlay {
            if albums.isEmpty {
                if app.syncProgress != nil { ProgressView("Syncing library…") }
                else if sort == .recentlyPlayed { ContentUnavailableView("Nothing Played Yet", systemImage: "clock.arrow.circlepath", description: Text("Albums you play will appear here.")) }
                else { ContentUnavailableView("No Albums", systemImage: "square.stack", description: Text("Pull to refresh once your server is reachable.")) }
            }
        }
        .navigationTitle(title)
        #if os(macOS)
        .pageHeader(title) {
            MacFilterField(text: $filter, prompt: "Filter albums")
            sortMenu
                .labelStyle(.iconOnly)
                .menuStyle(.button)
                .buttonStyle(.glass)
                .menuIndicator(.hidden)
                .fixedSize()
        }
        #else
        .searchable(text: $filter, prompt: "Filter albums")
        .toolbar { sortMenu }
        #endif
        .task(id: sort) {
            for await value in app.store.observeAlbums(sortedBy: sort) { albums = value }
        }
        .refreshable { await app.sync() }
    }
}

struct AlbumDetailView: View {
    @Environment(AppModel.self) private var app
    let albumID: ItemID
    @State private var detail: AlbumDetail?
    @State private var failed = false
    @State private var info: AlbumInfo?

    var body: some View {
        Group {
            if let detail {
                #if os(macOS)
                MacCollectionPage(
                    coverArtID: detail.album.coverArtID,
                    title: detail.album.name,
                    artist: detail.album.artist,
                    artistID: detail.album.artistID,
                    details: [detail.album.genre, detail.album.year.map(String.init), detail.tracks.first.flatMap { Format.qualityBadge($0.format) },
                              "\(detail.tracks.count) songs", Format.longDuration(detail.tracks.compactMap(\.duration).reduce(.zero, +))]
                        .compactMap { $0 }.joined(separator: " · "),
                    tracks: detail.tracks,
                    albumID: albumID,
                    info: info,
                    actions: AnyView(Group {
                        DownloadButton(owner: .album(albumID)).buttonStyle(.glass)
                        Menu { AlbumMenu(album: detail.album) } label: {
                            Image(systemName: "ellipsis").frame(width: Metrics.actionIcon, height: Metrics.actionIcon)
                        }
                            .menuStyle(.button)
                            .buttonStyle(.glass)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .accessibilityLabel("More")
                    })
                ) { index, shuffled in
                    app.player.play(detail.tracks, startAt: index, from: .album(albumID, name: detail.album.name), shuffled: shuffled)
                }
                #else
                List {
                    header(detail)
                        .listRowSeparator(.hidden)
                        .listRowInsets(.init())
                    ForEach(discs(detail), id: \.0) { disc, tracks in
                        Section {
                            ForEach(tracks) { track in
                                TrackRow(track: track, showNumber: true) {
                                    let index = detail.tracks.firstIndex(of: track) ?? 0
                                    app.player.play(detail.tracks, startAt: index, from: .album(albumID, name: detail.album.name))
                                }
                            }
                        } header: {
                            if discs(detail).count > 1 { Text("Disc \(disc)") }
                        }
                    }
                    footer(detail).listRowSeparator(.hidden)
                    if let notes = info?.notes {
                        AboutBlurb(title: "About", text: notes).listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                #endif
            } else if failed {
                ContentUnavailableView("Album Unavailable", systemImage: "wifi.exclamationmark",
                                       description: Text("It isn't downloaded and the server can't be reached."))
            } else {
                ProgressView()
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .navigationTitle(detail?.album.name ?? "")
        #endif
        #if !os(macOS)
        .toolbar {
            if let detail {
                DownloadButton(owner: .album(albumID))
                Menu { AlbumMenu(album: detail.album) } label: { Image(systemName: "ellipsis") }
            }
        }
        #endif
        .task {
            detail = await app.albumDetail(albumID)
            failed = detail == nil
            let loaded = await app.albumInfo(albumID)
            withAnimation(Motion.page) { info = loaded }
        }
    }

    private func discs(_ d: AlbumDetail) -> [(Int, [Track])] {
        Dictionary(grouping: d.tracks) { $0.discNumber ?? 1 }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    @ViewBuilder
    private func header(_ d: AlbumDetail) -> some View {
        VStack(spacing: 14) {
            ArtworkView(.coverArt(d.album.coverArtID), cornerRadius: 10)
                .frame(maxWidth: 300)
                .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
                .padding(.top, 8)
            VStack(spacing: 4) {
                Text(d.album.name).font(.title2.bold()).multilineTextAlignment(.center)
                if let artistID = d.album.artistID {
                    NavigationLink(value: Route.artist(artistID)) {
                        Text(d.album.artist ?? "").font(.title3).foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                }
                Text([d.album.genre, d.album.year.map(String.init), d.tracks.first.flatMap { Format.qualityBadge($0.format) }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button {
                    app.player.play(d.tracks, from: .album(albumID, name: d.album.name))
                } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity) }
                Button {
                    app.player.play(d.tracks, from: .album(albumID, name: d.album.name), shuffled: true)
                } label: { Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func footer(_ d: AlbumDetail) -> some View {
        let total = d.tracks.compactMap(\.duration).reduce(Duration.zero, +)
        return Text("\(d.tracks.count) songs, \(Format.longDuration(total) ?? "")")
            .font(.footnote).foregroundStyle(.secondary)
            .padding(.top, 8)
    }
}

// MARK: Artists

struct ArtistsView: View {
    @Environment(AppModel.self) private var app
    @State private var artists: [Artist] = []
    @State private var filter = ""

    var body: some View {
        List(artists.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }) { artist in
            NavigationLink(value: Route.artist(artist.id)) {
                HStack(spacing: 12) {
                    ArtworkView(.coverArt(artist.coverArtID), cornerRadius: Metrics.listArtwork / 2, size: Metrics.listArtwork)
                    Text(artist.name)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Artists")
        #if os(macOS)
        .pageHeader("Artists") { MacFilterField(text: $filter, prompt: "Filter artists") }
        #else
        .searchable(text: $filter, prompt: "Filter artists")
        #endif
        .task { for await value in app.store.observeArtists() { artists = value } }
    }
}

struct ArtistDetailView: View {
    @Environment(AppModel.self) private var app
    let artistID: ItemID
    @State private var name = ""
    @State private var albums: [Album] = []
    @State private var top: [Track] = []
    @State private var info: ArtistInfo?

    private var shuffleButton: some View {
        Button {
            Task {
                var tracks: [Track] = []
                for a in albums { if let d = await app.albumDetail(a.id) { tracks += d.tracks } }
                app.player.play(tracks, from: .artist(artistID, name: name), shuffled: true)
            }
        } label: { Label("Shuffle", systemImage: "shuffle") }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !top.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Top Songs").font(Metrics.shelfTitle)
                        ForEach(top.prefix(5)) { track in
                            TrackRow(track: track, showArtwork: true) {
                                app.player.play(top, startAt: top.firstIndex(of: track) ?? 0, from: .artist(artistID, name: name))
                            }
                            Divider()
                        }
                    }
                    .padding(.horizontal)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Albums").font(Metrics.shelfTitle).padding(.horizontal)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.cardMinimum), spacing: Metrics.gridSpacing)], spacing: Metrics.gridRowSpacing) {
                        ForEach(albums) { AlbumCard(album: $0) }
                    }
                    .padding(.horizontal)
                }
                if let biography = info?.biography {
                    AboutBlurb(title: name.isEmpty ? "About" : "About \(name)", text: biography)
                        .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(name)
        #if os(macOS)
        .pageHeader(name) { shuffleButton.buttonStyle(.glass) }
        #else
        .toolbar { shuffleButton }
        #endif
        .task {
            albums = (try? app.store.albums(byArtist: artistID)) ?? []
            name = albums.first?.artist ?? name
            if let detail = try? await app.library?.artist(artistID) {
                name = detail.artist.name
                albums = detail.albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
                top = (try? await app.library?.topSongs(artistName: detail.artist.name)) ?? []
            }
        }
        .task(id: artistID) {
            let loaded = await app.artistInfo(artistID)
            withAnimation(Motion.page) { info = loaded }
        }
    }
}

// MARK: Playlists

struct PlaylistsView: View {
    @Environment(AppModel.self) private var app
    @State private var playlists: [Playlist] = []

    var body: some View {
        List(playlists) { p in
            NavigationLink(value: Route.playlist(p.id)) {
                HStack(spacing: 12) {
                    ArtworkView(.coverArt(p.coverArtID), cornerRadius: 6, size: 56)
                    VStack(alignment: .leading) {
                        Text(p.name)
                        Text("\(p.songCount ?? 0) songs").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay { if playlists.isEmpty { ContentUnavailableView("No Playlists", systemImage: "music.note.list") } }
        .navigationTitle("Playlists")
        .task { for await value in app.store.observePlaylists() { playlists = value } }
    }
}

struct PlaylistDetailView: View {
    @Environment(AppModel.self) private var app
    let playlistID: ItemID
    @State private var detail: PlaylistDetail?

    var body: some View {
        content
            .navigationTitle(detail?.playlist.name ?? "")
            #if !os(macOS)
            .toolbar { DownloadButton(owner: .playlist(playlistID)) }
            #endif
            .task(id: playlistID) { detail = try? await app.library?.playlist(playlistID) }
    }

    #if os(macOS)
    @ViewBuilder
    private var content: some View {
        if let detail {
            MacCollectionPage(
                coverArtID: detail.playlist.coverArtID,
                title: detail.playlist.name,
                details: ["\(detail.tracks.count) songs", Format.longDuration(detail.tracks.compactMap(\.duration).reduce(.zero, +))]
                    .compactMap { $0 }.joined(separator: " · "),
                tracks: detail.tracks,
                showsTrackArtwork: true,
                actions: AnyView(DownloadButton(owner: .playlist(playlistID)).buttonStyle(.glass))
            ) { index, shuffled in
                app.player.play(detail.tracks, startAt: index, from: .playlist(playlistID, name: detail.playlist.name), shuffled: shuffled)
            }
        } else {
            ProgressView()
        }
    }
    #else
    private var content: some View {
        List {
            if let detail {
                HStack(spacing: 12) {
                    Button { app.player.play(detail.tracks, from: .playlist(playlistID, name: detail.playlist.name)) } label: {
                        Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    Button { app.player.play(detail.tracks, from: .playlist(playlistID, name: detail.playlist.name), shuffled: true) } label: {
                        Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .listRowSeparator(.hidden)

                ForEach(Array(detail.tracks.enumerated()), id: \.offset) { index, track in
                    TrackRow(track: track, showArtwork: true) {
                        app.player.play(detail.tracks, startAt: index, from: .playlist(playlistID, name: detail.playlist.name))
                    }
                }
            } else {
                ProgressView()
            }
        }
        .listStyle(.plain)
    }
    #endif
}

struct FavoriteSongsView: View {
    @Environment(AppModel.self) private var app
    @State private var tracks: [Track] = []

    private var shuffleButton: some View {
        Button { app.player.play(tracks, from: .songs, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
            .disabled(tracks.isEmpty)
    }

    @ViewBuilder
    private var songs: some View {
        #if os(macOS)
        SongTable(tracks: tracks) { rows, index in app.player.play(rows, startAt: index, from: .songs) }
        #else
        List(Array(tracks.enumerated()), id: \.element.id) { index, track in
            TrackRow(track: track, showArtwork: true) { app.player.play(tracks, startAt: index, from: .songs) }
        }
        .listStyle(.plain)
        #endif
    }

    var body: some View {
        songs
        .overlay { if tracks.isEmpty { ContentUnavailableView("No Favorite Songs", systemImage: "star") } }
        .navigationTitle("Favorite Songs")
        #if os(macOS)
        .pageHeader("Favorite Songs") { shuffleButton.buttonStyle(.glass) }
        #else
        .toolbar { shuffleButton }
        #endif
        .task { tracks = (try? app.store.starredTracks()) ?? [] }
    }
}
