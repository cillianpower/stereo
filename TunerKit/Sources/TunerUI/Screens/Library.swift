import SwiftUI
import TunerModel
import TunerStore

public enum Route: Hashable {
    case album(ItemID)
    case artist(ItemID)
    case playlist(ItemID)
    case albums
    case artists
    case playlists
    case favoriteSongs
}

extension View {
    /// Registers every `Route` destination. Apply once per NavigationStack.
    func tunerDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
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
}

// MARK: Library root

struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var recent: [Album] = []

    var body: some View {
        List {
            Section {
                NavigationLink(value: Route.playlists) { Label("Playlists", systemImage: "music.note.list") }
                NavigationLink(value: Route.artists) { Label("Artists", systemImage: "music.microphone") }
                NavigationLink(value: Route.albums) { Label("Albums", systemImage: "square.stack") }
                NavigationLink(value: Route.favoriteSongs) { Label("Favorite Songs", systemImage: "star") }
                NavigationLink { DownloadedView() } label: { Label("Downloaded", systemImage: "arrow.down.circle") }
            }
            .font(.title3)

            if let progress = app.syncProgress {
                Section {
                    HStack {
                        ProgressView()
                        Text("Syncing \(progress.phase)…").foregroundStyle(.secondary)
                        Spacer()
                        if let total = progress.albumsTotal { Text("\(progress.albumsDone)/\(total)").monospacedDigit().foregroundStyle(.secondary) }
                    }
                }
            }

            if !recent.isEmpty {
                Section("Recently Added") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                        ForEach(recent) { AlbumCard(album: $0) }
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(.init(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }
        }
        .navigationTitle("Library")
        .task {
            for await albums in app.store.observeAlbums(sortedBy: .recentlyAdded, limit: 24) { recent = albums }
        }
        .refreshable { await app.sync() }
    }
}

// MARK: Albums

struct AlbumsView: View {
    @Environment(AppModel.self) private var app
    @State private var albums: [Album] = []
    @State private var sort: LibraryStore.AlbumSort = .name
    @State private var filter = ""

    private var shown: [Album] {
        guard !filter.isEmpty else { return albums }
        return albums.filter { $0.name.localizedCaseInsensitiveContains(filter) || ($0.artist ?? "").localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                ForEach(shown) { AlbumCard(album: $0) }
            }
            .padding()
        }
        .overlay {
            if albums.isEmpty {
                if app.syncProgress != nil { ProgressView("Syncing library…") }
                else { ContentUnavailableView("No Albums", systemImage: "square.stack", description: Text("Pull to refresh once your server is reachable.")) }
            }
        }
        .navigationTitle("Albums")
        .searchable(text: $filter, prompt: "Filter albums")
        .toolbar {
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

    var body: some View {
        Group {
            if let detail {
                #if os(macOS)
                VStack(spacing: 0) {
                    macHeader(detail)
                    SongTable(tracks: detail.tracks, showNumber: true, showAlbum: false) { tracks, index in
                        app.player.play(tracks, startAt: index, from: .album(albumID, name: detail.album.name))
                    }
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
        #endif
        .toolbar {
            if let detail {
                DownloadButton(owner: .album(albumID))
                Menu { AlbumMenu(album: detail.album) } label: { Image(systemName: "ellipsis") }
            }
        }
        .task {
            detail = await app.albumDetail(albumID)
            failed = detail == nil
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

    #if os(macOS)
    /// Music.app-style album header: artwork left, details and actions right.
    private func macHeader(_ d: AlbumDetail) -> some View {
        HStack(alignment: .bottom, spacing: 20) {
            ArtworkView(.coverArt(d.album.coverArtID), cornerRadius: 8, size: 200)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            VStack(alignment: .leading, spacing: 6) {
                Text(d.album.name).font(.largeTitle.bold()).lineLimit(2)
                if let artistID = d.album.artistID {
                    NavigationLink(value: Route.artist(artistID)) {
                        Text(d.album.artist ?? "").font(.title2).foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                }
                Text([d.album.genre, d.album.year.map(String.init), d.tracks.first.flatMap { Format.qualityBadge($0.format) },
                      "\(d.tracks.count) songs", Format.longDuration(d.tracks.compactMap(\.duration).reduce(.zero, +))]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button { app.player.play(d.tracks, from: .album(albumID, name: d.album.name)) } label: { Label("Play", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                    Button { app.player.play(d.tracks, from: .album(albumID, name: d.album.name), shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                        .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .padding(.top, 6)
            }
            Spacer()
        }
        .padding(20)
    }
    #endif

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
                    ArtworkView(.coverArt(artist.coverArtID), cornerRadius: 22, size: 44)
                    Text(artist.name)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Artists")
        .searchable(text: $filter, prompt: "Filter artists")
        .task { for await value in app.store.observeArtists() { artists = value } }
    }
}

struct ArtistDetailView: View {
    @Environment(AppModel.self) private var app
    let artistID: ItemID
    @State private var name = ""
    @State private var albums: [Album] = []
    @State private var top: [Track] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !top.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Top Songs").font(.title2.bold())
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
                    Text("Albums").font(.title2.bold()).padding(.horizontal)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                        ForEach(albums) { AlbumCard(album: $0) }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(name)
        .toolbar {
            Button {
                Task {
                    var tracks: [Track] = []
                    for a in albums { if let d = await app.albumDetail(a.id) { tracks += d.tracks } }
                    app.player.play(tracks, from: .artist(artistID, name: name), shuffled: true)
                }
            } label: { Label("Shuffle", systemImage: "shuffle") }
        }
        .task {
            albums = (try? app.store.albums(byArtist: artistID)) ?? []
            name = albums.first?.artist ?? name
            if let detail = try? await app.library?.artist(artistID) {
                name = detail.artist.name
                albums = detail.albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
                top = (try? await app.library?.topSongs(artistName: detail.artist.name)) ?? []
            }
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

                #if os(macOS)
                SongTable(tracks: detail.tracks) { tracks, index in
                    app.player.play(tracks, startAt: index, from: .playlist(playlistID, name: detail.playlist.name))
                }
                .frame(minHeight: 400)
                .listRowInsets(.init())
                #else
                ForEach(Array(detail.tracks.enumerated()), id: \.offset) { index, track in
                    TrackRow(track: track, showArtwork: true) {
                        app.player.play(detail.tracks, startAt: index, from: .playlist(playlistID, name: detail.playlist.name))
                    }
                }
                #endif
            } else {
                ProgressView()
            }
        }
        .listStyle(.plain)
        .navigationTitle(detail?.playlist.name ?? "")
        .toolbar { DownloadButton(owner: .playlist(playlistID)) }
        .task { detail = try? await app.library?.playlist(playlistID) }
    }
}

struct FavoriteSongsView: View {
    @Environment(AppModel.self) private var app
    @State private var tracks: [Track] = []

    var body: some View {
        List(Array(tracks.enumerated()), id: \.element.id) { index, track in
            TrackRow(track: track, showArtwork: true) { app.player.play(tracks, startAt: index, from: .songs) }
        }
        .listStyle(.plain)
        .overlay { if tracks.isEmpty { ContentUnavailableView("No Favorite Songs", systemImage: "star") } }
        .navigationTitle("Favorite Songs")
        .toolbar {
            Button { app.player.play(tracks, from: .songs, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                .disabled(tracks.isEmpty)
        }
        .task { tracks = (try? app.store.starredTracks()) ?? [] }
    }
}
