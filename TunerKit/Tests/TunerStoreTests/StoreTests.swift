import Foundation
import Testing
import TunerModel
@testable import TunerStore

private let src = SourceID("nav")
private func iid(_ raw: String) -> ItemID { ItemID(source: src, raw: raw) }

private func makeAlbum(_ n: Int, name: String? = nil, artist: String = "Artist", plays: Int? = nil, lastPlayed: Date? = nil) -> Album {
    Album(id: iid("al\(n)"), name: name ?? "Album \(n)", artist: artist, artistID: iid("ar1"), year: 2000 + n,
          songCount: 2, created: Date(timeIntervalSince1970: Double(n) * 1000), playCount: plays, lastPlayed: lastPlayed)
}

private func makeDetail(_ a: Album, titles: [String]) -> AlbumDetail {
    AlbumDetail(album: a, tracks: titles.enumerated().map { i, t in
        Track(id: iid("\(a.id.raw)-t\(i)"), title: t, artist: a.artist, album: a.name, albumID: a.id, trackNumber: i + 1,
              duration: .seconds(200), format: AudioFormat(codec: "flac", sampleRate: 44_100, bitDepth: 16),
              replayGain: ReplayGain(trackGain: -5, albumGain: -6))
    })
}

@Suite struct IntentQueryTests {
    private func station(_ name: String) -> Station {
        Station(origin: .custom(UUID()), name: name, streamURL: URL(string: "https://radio.example/\(name)")!)
    }

    @Test func randomTracksRespectsLimitAndHasNoDuplicates() throws {
        let store = try LibraryStore.inMemory()
        try store.upsert(makeDetail(makeAlbum(1), titles: ["A", "B", "C", "D"]))
        let sample = try store.randomTracks(limit: 3)
        #expect(sample.count == 3)
        #expect(Set(sample.map(\.id)).count == 3)
    }

    @Test func savedStationsListsFavoritesInOrderThenRecents() throws {
        let store = try LibraryStore.inMemory()
        let first = station("First"), second = station("Second"), recent = station("Recent")
        try store.markPlayed(recent)
        try store.setFavorite(true, station: first)
        try store.setFavorite(true, station: second)
        #expect(try store.savedStations().map(\.name) == ["First", "Second", "Recent"])
    }
}

@Suite struct LibraryStoreTests {
    @Test func albumRoundTripWithTracks() throws {
        let store = try LibraryStore.inMemory()
        let a = makeAlbum(1, name: "Geogaddi", artist: "Boards of Canada")
        try store.upsert(makeDetail(a, titles: ["Ready Lets Go", "Music Is Math"]))
        let loaded = try #require(try store.album(a.id))
        #expect(loaded.album.name == "Geogaddi")
        #expect(loaded.tracks.map(\.title) == ["Ready Lets Go", "Music Is Math"])
        #expect(loaded.tracks[0].replayGain.albumGain == -6)
        #expect(loaded.tracks[0].format.codec == "flac")
        #expect(loaded.tracks[0].duration == .seconds(200))
    }

    @Test func reupsertReplacesTrackList() throws {
        let store = try LibraryStore.inMemory()
        let a = makeAlbum(1)
        try store.upsert(makeDetail(a, titles: ["one", "two", "three"]))
        try store.upsert(makeDetail(a, titles: ["one"]))
        #expect(try store.album(a.id)?.tracks.count == 1)
        #expect(try store.counts().tracks == 1)
    }

    @Test func ftsPrefixSearchIgnoresDiacritics() throws {
        let store = try LibraryStore.inMemory()
        try store.replaceArtists([Artist(id: iid("ar1"), name: "Boards of Canada"), Artist(id: iid("ar2"), name: "Sigur Rós")])
        try store.upsert(makeDetail(makeAlbum(1, name: "Ágætis byrjun", artist: "Sigur Rós"), titles: ["Svefn-g-englar", "Starálfur"]))
        let r1 = try store.search("boa can")
        #expect(r1.artists.map(\.name) == ["Boards of Canada"])
        let r2 = try store.search("sigur ros")
        #expect(r2.artists.map(\.name) == ["Sigur Rós"])
        #expect(r2.albums.count == 1)
        #expect(r2.tracks.count == 2)
        let r3 = try store.search("staralf")
        #expect(r3.tracks.map(\.title) == ["Starálfur"])
        #expect(try store.search("   ").isEmpty)
    }

    @Test func sortsAndShelves() throws {
        let store = try LibraryStore.inMemory()
        let old = Date().addingTimeInterval(-200 * 86_400)
        try store.upsert(albums: [
            makeAlbum(1, name: "b", plays: 50, lastPlayed: old),
            makeAlbum(2, name: "A", plays: 1, lastPlayed: Date()),
            makeAlbum(3, name: "c"),
        ])
        #expect(try store.albums(sortedBy: .name).map(\.name) == ["A", "b", "c"])
        #expect(try store.albums(sortedBy: .recentlyAdded).first?.name == "c")
        #expect(try store.albums(sortedBy: .recentlyPlayed).map(\.name) == ["A", "b"])
        #expect(try store.rediscoverAlbums().map(\.name) == ["b"])
    }

    @Test func removesStaleAlbumsAndCascadesTracks() throws {
        let store = try LibraryStore.inMemory()
        let t0 = Date(timeIntervalSince1970: 1000), t1 = Date(timeIntervalSince1970: 2000)
        try store.upsert(makeDetail(makeAlbum(1), titles: ["x"]), syncedAt: t0)
        try store.upsert(makeDetail(makeAlbum(2), titles: ["y"]), syncedAt: t1)
        #expect(try store.removeAlbums(syncedBefore: t1) == 1)
        #expect(try store.counts().albums == 1)
        #expect(try store.counts().tracks == 1)
    }

    @Test func findTrackForRadioTitle() throws {
        let store = try LibraryStore.inMemory()
        try store.upsert(makeDetail(makeAlbum(1, artist: "Boards of Canada"), titles: ["Roygbiv", "Aquarius"]))
        #expect(try store.findTrack(artist: "Boards of Canada", title: "Roygbiv")?.title == "Roygbiv")
        #expect(try store.findTrack(artist: "Nobody", title: "Nothing") == nil)
    }
}

@Suite struct StationStoreTests {
    func station(_ n: Int) -> Station {
        Station(origin: .radioBrowser(uuid: "uuid-\(n)"), name: "Station \(n)", streamURL: URL(string: "https://s\(n).example/stream")!)
    }

    @Test func favoritesKeepOrderAndCanMove() throws {
        let store = try LibraryStore.inMemory()
        let (a, b, c) = (station(1), station(2), station(3))
        for s in [a, b, c] { try store.setFavorite(true, station: s) }
        #expect(try store.favoriteStations().map(\.name) == ["Station 1", "Station 2", "Station 3"])
        try store.moveFavorite(c, between: a, and: b)
        #expect(try store.favoriteStations().map(\.name) == ["Station 1", "Station 3", "Station 2"])
        try store.setFavorite(false, station: a)
        #expect(try store.favoriteStations().count == 2)
        #expect(try !store.isFavorite(a))
    }

    @Test func recentsAndCustom() throws {
        let store = try LibraryStore.inMemory()
        let custom = Station(origin: .custom(UUID()), name: "Mine", streamURL: URL(string: "http://x/y.mp3")!)
        try store.saveCustomStation(custom)
        try store.markPlayed(station(1))
        try store.markPlayed(custom)
        #expect(try store.customStations().map(\.name) == ["Mine"])
        #expect(try store.recentStations().map(\.name) == ["Mine", "Station 1"])
    }

    @Test func observationEmitsChanges() async throws {
        let store = try LibraryStore.inMemory()
        var iterator = store.observeFavoriteStations().makeAsyncIterator()
        #expect(await iterator.next()?.isEmpty == true)
        try store.setFavorite(true, station: station(1))
        #expect(await iterator.next()?.count == 1)
    }
}

/// In-memory fake server for sync tests.
actor FakeLibrary: LibrarySource {
    nonisolated let id = src
    var albumsByID: [ItemID: AlbumDetail] = [:]
    var detailFetches = 0

    init(albumCount: Int) {
        for n in 0..<albumCount {
            let a = makeAlbum(n)
            albumsByID[a.id] = makeDetail(a, titles: ["t"])
        }
    }

    func add(_ n: Int) { let a = makeAlbum(n); albumsByID[a.id] = makeDetail(a, titles: ["new"]) }
    func remove(_ n: Int) { albumsByID[iid("al\(n)")] = nil }
    func fetchCount() -> Int { detailFetches }

    func capabilities() async throws -> LibraryCapabilities { [] }
    func albums(_ list: AlbumListKind, page: PageRequest) async throws -> Page<Album> {
        let all = albumsByID.values.map(\.album)
        let sorted = list == .newest ? all.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) } : all.sorted { $0.name < $1.name }
        let slice = sorted.dropFirst(page.offset).prefix(page.size)
        return Page(items: Array(slice), request: page)
    }
    func album(_ id: ItemID) async throws -> AlbumDetail { detailFetches += 1; return albumsByID[id]! }
    func artists() async throws -> [Artist] { [Artist(id: iid("ar1"), name: "Artist")] }
    func artist(_ id: ItemID) async throws -> ArtistDetail { fatalError() }
    func playlists() async throws -> [Playlist] { [] }
    func playlist(_ id: ItemID) async throws -> PlaylistDetail { fatalError() }
    func search(_ query: String, limit: Int) async throws -> SearchResults { .init() }
    func streamRequest(for track: ItemID, quality: StreamQuality, offset: Duration?) async throws -> URLRequest { fatalError() }
    func coverArtURL(_ coverArtID: String, size: Int) async throws -> URL { fatalError() }
    func lyrics(for track: Track) async throws -> Lyrics? { nil }
    func similar(to track: ItemID, count: Int) async throws -> [Track] { [] }
    func setStarred(_ starred: Bool, _ target: StarTarget) async throws {}
    func report(_ event: PlaybackEvent) async throws {}
    func savePlayQueue(_ tracks: [ItemID], current: ItemID?, position: Duration) async throws {}
    func loadPlayQueue() async throws -> SavedPlayQueue? { nil }
}

@Suite struct LibrarySyncerTests {
    @Test func fullSyncPagesAndFetchesEveryAlbum() async throws {
        let store = try LibraryStore.inMemory()
        let server = FakeLibrary(albumCount: 1234)
        let syncer = LibrarySyncer(source: server, store: store)
        try await syncer.sync(force: true)
        let counts = try store.counts()
        #expect(counts.albums == 1234)
        #expect(counts.tracks == 1234)
        #expect(await syncer.needsFullSync() == false)
    }

    @Test func fullSyncRemovesDeletedAlbums() async throws {
        let store = try LibraryStore.inMemory()
        let server = FakeLibrary(albumCount: 10)
        let syncer = LibrarySyncer(source: server, store: store)
        try await syncer.sync(force: true)
        await server.remove(3)
        try await Task.sleep(for: .milliseconds(5))
        try await syncer.sync(force: true)
        #expect(try store.counts().albums == 9)
    }

    @Test func deltaSyncOnlyFetchesNewAlbums() async throws {
        let store = try LibraryStore.inMemory()
        let server = FakeLibrary(albumCount: 50)
        let syncer = LibrarySyncer(source: server, store: store)
        try await syncer.sync(force: true)
        let before = await server.fetchCount()
        await server.add(100)
        try await syncer.sync()
        #expect(await server.fetchCount() - before == 1)
        #expect(try store.counts().albums == 51)
        #expect(try store.album(iid("al100"))?.tracks.first?.title == "new")
    }
}

@Suite struct RecentlyPlayedTests {
    @Test func startingAnAlbumMovesItToTheFront() throws {
        let store = try LibraryStore.inMemory()
        let older = makeAlbum(1, lastPlayed: Date(timeIntervalSince1970: 1000))
        let newer = makeAlbum(2, lastPlayed: Date(timeIntervalSince1970: 2000))
        let never = makeAlbum(3)
        try store.upsert(albums: [older, newer, never])
        #expect(try store.albums(sortedBy: .recentlyPlayed).map(\.id) == [newer.id, older.id])

        try store.markPlayed(album: never.id, at: Date(timeIntervalSince1970: 3000))
        try store.markPlayed(album: older.id, at: Date(timeIntervalSince1970: 4000))
        #expect(try store.albums(sortedBy: .recentlyPlayed).map(\.id) == [older.id, never.id, newer.id])
    }

    @Test func aServerRefreshKeepsTheNewestPlayDate() throws {
        let store = try LibraryStore.inMemory()
        let album = makeAlbum(1)
        try store.upsert(makeDetail(album, titles: ["A"]))
        let played = Date(timeIntervalSince1970: 5000)
        try store.markPlayed(album: album.id, at: played)

        try store.upsert(makeDetail(album, titles: ["A"]))       // server hasn't seen the play
        #expect(try store.album(album.id)?.album.lastPlayed == played)
        try store.upsert(albums: [makeAlbum(1, lastPlayed: Date(timeIntervalSince1970: 1000))])
        #expect(try store.album(album.id)?.album.lastPlayed == played)

        let later = Date(timeIntervalSince1970: 9000)
        try store.upsert(albums: [makeAlbum(1, lastPlayed: later)])
        #expect(try store.album(album.id)?.album.lastPlayed == later)
    }
}
