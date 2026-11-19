import RadioBrowserClient
import SwiftUI
import TunerModel
import TunerRadio

// Home lives in Screens/Discovery/HomeView.swift (driven by TunerDiscovery.HomeFeed).

// MARK: Search

struct SearchView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var results = SearchResults()
    @State private var scope: Scope = .library

    enum Scope: String, CaseIterable { case library = "Library", radio = "Radio" }

    var body: some View {
        Group {
            switch scope {
            case .library: libraryResults
            case .radio: RadioSearchResults(query: query)
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: scope == .library ? "Artists, albums, songs" : "Stations — try #jazz codec:flac")
        .searchScopes($scope) { ForEach(Scope.allCases, id: \.self) { Text($0.rawValue) } }
        .task(id: query) {
            guard scope == .library else { return }
            // Local FTS is instant; the server only fills gaps (e.g. before the first sync finishes).
            results = (try? app.store.search(query)) ?? SearchResults()
            if results.isEmpty, query.count > 2, let lib = app.library {
                try? await Task.sleep(for: .milliseconds(300))
                if let remote = try? await lib.search(query, limit: 20), !Task.isCancelled { results = remote }
            }
        }
    }

    private var libraryResults: some View {
        List {
            if !results.artists.isEmpty {
                Section("Artists") {
                    ForEach(results.artists) { a in
                        NavigationLink(value: Route.artist(a.id)) { Label(a.name, systemImage: "music.microphone") }
                    }
                }
            }
            if !results.albums.isEmpty {
                Section("Albums") {
                    ForEach(results.albums) { album in
                        NavigationLink(value: Route.album(album.id)) {
                            HStack(spacing: 12) {
                                ArtworkView(.coverArt(album.coverArtID), cornerRadius: 4, size: 44)
                                VStack(alignment: .leading) {
                                    Text(album.name).lineLimit(1)
                                    Text(album.artist ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            if !results.tracks.isEmpty {
                Section("Songs") {
                    ForEach(results.tracks) { track in
                        TrackRow(track: track, showArtwork: true) { app.player.play([track], from: .search) }
                    }
                }
            }
        }
        .overlay {
            if query.isEmpty {
                ContentUnavailableView("Search Your Library", systemImage: "magnifyingglass")
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}

// MARK: Radio

struct RadioView: View {
    @Environment(AppModel.self) private var app
    @State private var favorites: [Station] = []
    @State private var recents: [Station] = []
    @State private var popular: [Station] = []
    @State private var tags: [Facet] = []
    @State private var query = ""
    @State private var addingCustom = false

    var body: some View {
        Group {
            if query.isEmpty { browse } else { RadioSearchResults(query: query) }
        }
        .navigationTitle("Radio")
        .searchable(text: $query, prompt: "Stations — try #jazz bitrate>=256")
        .toolbar {
            Button { addingCustom = true } label: { Label("Add Station URL", systemImage: "plus") }
        }
        .sheet(isPresented: $addingCustom) { AddStationSheet() }
        .task { for await v in app.store.observeFavoriteStations() { favorites = v } }
        .task { for await v in app.store.observeRecentStations(limit: 10) { recents = v } }
        .task {
            popular = (try? await app.radioBrowser.topVoted(limit: 30)) ?? []
            tags = (try? await app.radioBrowser.tags(limit: 24)) ?? []
        }
    }

    private var browse: some View {
        List {
            if let enrichment = app.radioEnrichment, case .station = app.player.nowPlaying {
                Section("Now Playing") { RadioNowPlayingCard(enrichment: enrichment) }
            }
            if !favorites.isEmpty {
                Section("Favorites") { ForEach(favorites) { StationRow(station: $0) } }
            }
            Section {
                NavigationLink { IdentifiedSongsView() } label: { Label("Identified Songs", systemImage: "shazam.logo") }
            }
            if !recents.isEmpty {
                Section("Recently Played") { ForEach(recents) { StationRow(station: $0) } }
            }
            if !tags.isEmpty {
                Section("Genres") {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(tags) { tag in
                                Button("#\(tag.name)") { query = "#\(tag.name)" }
                                    .buttonStyle(.bordered)
                                    .buttonBorderShape(.capsule)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
            Section("Popular") {
                if popular.isEmpty { ProgressView() }
                ForEach(popular) { StationRow(station: $0) }
            }
        }
    }
}

struct RadioNowPlayingCard: View {
    @Environment(AppModel.self) private var app
    let enrichment: EnrichedTitle

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(.url(enrichment.artworkURL, key: "itunes:\(enrichment.artworkURL?.absoluteString ?? enrichment.title)"),
                        cornerRadius: 6, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(enrichment.title).font(.headline).lineLimit(1)
                Text([enrichment.artist, enrichment.album].compactMap { $0 }.joined(separator: " — "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let match = app.radioLibraryMatch {
                Button { app.player.play([match], from: .search) } label: {
                    Label("In Library", systemImage: "music.note.house")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }
}

struct RadioSearchResults: View {
    @Environment(AppModel.self) private var app
    let query: String
    @State private var stations: [Station] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List(stations) { StationRow(station: $0) }
            .overlay {
                if loading && stations.isEmpty { ProgressView() }
                else if let error { ContentUnavailableView("Radio Browser Unavailable", systemImage: "wifi.exclamationmark", description: Text(error)) }
                else if stations.isEmpty, !query.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .task(id: query) {
                guard !query.isEmpty else { stations = []; return }
                try? await Task.sleep(for: .milliseconds(350))   // debounce typing
                guard !Task.isCancelled else { return }
                loading = true
                defer { loading = false }
                var q = StationSearchParser.parse(query, limit: 100)
                if q.order == nil { q.order = .votes; q.reverse = true }
                do {
                    stations = try await app.radioBrowser.search(q)
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
            }
    }
}

struct AddStationSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var name = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Stream or playlist URL", text: $urlText)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                    TextField("Name (optional)", text: $name)
                } footer: {
                    Text("Direct Icecast/Shoutcast streams, .pls and .m3u playlists, and HLS all work. Format and bitrate are detected automatically.")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Station")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else {
                        Button("Add") { add() }.disabled(URL(string: urlText)?.scheme == nil)
                    }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 260)
    }

    private func add() {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)) else { return }
        working = true
        Task {
            do {
                let station = try await app.addCustomStation(url: url, name: name)
                app.player.play(station)
                dismiss()
            } catch {
                self.error = "Couldn't open that stream: \(error.localizedDescription)"
            }
            working = false
        }
    }
}
