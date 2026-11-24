import SwiftUI
import StereoDiscovery
import StereoModel

/// Apple Music–style Home, built from `HomeFeed` shelves.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var shelves: [HomeShelf] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                if let error = app.syncError, shelves.isEmpty {
                    ContentUnavailableView("Can't Reach Server", systemImage: "wifi.exclamationmark", description: Text(error))
                }
                ForEach(shelves) { shelf in
                    ShelfView(shelf: shelf)
                }
                if loaded, !shelves.contains(where: { $0.kind == .forYou }), app.discovery?.listenBrainzStatus == .notConnected {
                    ListenBrainzPromo()
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .navigationTitle("Home")
        .pageHeader("Home")
        .overlay {
            if !loaded || (shelves.isEmpty && app.syncProgress != nil) {
                ProgressView(app.syncProgress?.phase ?? "Loading…")
            }
        }
        .refreshable {
            await app.sync()
            await reload(force: true)
        }
        .task(id: app.discovery?.listenBrainzStatus) { await reload() }
        // Rebuild when a sync finishes or stations change, so local shelves stay current.
        .onChange(of: app.syncProgress == nil) { _, finished in
            if finished { Task { await reload() } }
        }
        .task {
            for await _ in app.store.observeFavoriteStations() { await reload() }
        }
        // Keeps the Recently Played shelf current as you listen.
        .task {
            var last: [ItemID]?
            for await albums in app.store.observeAlbums(sortedBy: .recentlyPlayed, limit: 24) {
                let ids = albums.map(\.id)
                if let last, last != ids { await reload() }
                last = ids
            }
        }
    }

    private func reload(force: Bool = false) async {
        guard let feed = app.discovery?.homeFeed else { return }
        let next = await feed.shelves(force: force)
        withAnimation(.snappy) { shelves = next }
        loaded = true
    }
}

private struct ShelfView: View {
    @Environment(AppModel.self) private var app
    let shelf: HomeShelf

    var body: some View {
        switch shelf.content {
        case .albums(let albums):
            Shelf(title: shelf.title) { ForEach(albums) { AlbumCard(album: $0, width: Metrics.shelfCard) } }
        case .stations(let stations):
            Shelf(title: shelf.title) {
                ForEach(stations) { station in
                    Button { app.player.play(station) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ArtworkView(.station(station), cornerRadius: Metrics.cardRadius)
                            Text(station.name).font(.caption).lineLimit(1)
                        }
                        .frame(width: Metrics.shelfCard * 0.75)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { StationMenu(station: station) }
                }
            }
        case .tracks(let tracks):
            TrackShelf(title: shelf.title, subtitle: shelf.subtitle, tracks: tracks)
        }
    }
}

/// Songs in a horizontally paged grid of rows, four per column, like Apple Music's "Top Picks".
private struct TrackShelf: View {
    @Environment(AppModel.self) private var app
    let title: String
    let subtitle: String?
    let tracks: [Track]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Metrics.shelfTitle)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Button { app.player.play(tracks, from: .songs) } label: {
                    Label("Play", systemImage: "play.fill").labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .accessibilityLabel("Play \(title)")
            }
            .padding(.horizontal, Metrics.pagePadding)

            ScrollView(.horizontal) {
                LazyHGrid(rows: Array(repeating: GridItem(.fixed(Metrics.shelfRow), spacing: 2), count: min(4, max(tracks.count, 1))), spacing: Metrics.gridSpacing) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        Button { app.player.play(tracks, startAt: index, from: .songs) } label: {
                            HStack(spacing: 10) {
                                ArtworkView(.coverArt(track.coverArtID), cornerRadius: 4, size: Metrics.shelfRowArtwork)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(track.title).lineLimit(1)
                                    Text(track.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(width: Metrics.shelfRowWidth, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { TrackMenu(track: track) }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, Metrics.pagePadding)
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

private struct ListenBrainzPromo: View {
    var body: some View {
        NavigationLink { SettingsView() } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles").font(.title3).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Get recommendations").font(.callout.weight(.semibold))
                    Text("Connect ListenBrainz in Settings for a For You shelf and Weekly Jams from your library.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(Metrics.promoPadding)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: Metrics.promoRadius))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Metrics.pagePadding)
    }
}
