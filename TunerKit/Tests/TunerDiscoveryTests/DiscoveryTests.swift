import Foundation
import Testing
import TunerModel
import TunerStore
@testable import TunerDiscovery

// MARK: Fakes

/// Routes requests to fixture files by path suffix and records them.
final class LBTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var routes: [(String, String, Int)] = []   // (path contains, fixture name, status)
    var fail = false
    var requests: [URLRequest] { lock.withLock { _requests } }

    func route(_ path: String, _ fixture: String, status: Int = 200) { routes.append((path, fixture, status)) }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let url = request.url!
        if fail { throw URLError(.notConnectedToInternet) }
        for (path, fixture, status) in routes where url.path().contains(path) {
            let data = fixture.isEmpty ? Data() :
                try Data(contentsOf: Bundle.module.url(forResource: fixture, withExtension: "json", subdirectory: "Fixtures")!)
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
    }
}

private let src = SourceID("nav")
private func iid(_ raw: String) -> ItemID { ItemID(source: src, raw: raw) }

private func track(_ raw: String, _ title: String, artist: String, album: String = "Album", mbid: String? = nil, genre: String? = nil) -> Track {
    Track(id: iid(raw), title: title, artist: artist, album: album, albumID: iid("al-\(album)"), genre: genre,
          duration: .seconds(200), musicBrainzID: mbid)
}

/// Library with a handful of known tracks spread over albums.
private func seededStore() throws -> LibraryStore {
    let store = try LibraryStore.inMemory()
    let groups: [(String, String, [Track])] = [
        ("Music Has the Right to Children", "Boards of Canada", [
            track("boc1", "Roygbiv", artist: "Boards of Canada", album: "Music Has the Right to Children", mbid: "AAAAAAAA-0000-4000-8000-000000000001", genre: "Electronic"),
            track("boc2", "Aquarius", artist: "Boards of Canada", album: "Music Has the Right to Children", genre: "Electronic"),
            track("boc3", "Turquoise Hexagon Sun", artist: "Boards of Canada", album: "Music Has the Right to Children", genre: "Electronic"),
        ]),
        ("Dummy", "Portishead", [track("ph1", "Strangers", artist: "Portishead", album: "Dummy", genre: "Trip Hop")]),
        ("Selected Ambient Works 85-92", "Aphex Twin", [
            track("at1", "Xtal", artist: "Aphex Twin", album: "Selected Ambient Works 85-92", genre: "Electronic"),
            track("at2", "Tha", artist: "Aphex Twin", album: "Selected Ambient Works 85-92", genre: "Electronic"),
            track("at3", "Pulsewidth", artist: "Aphex Twin", album: "Selected Ambient Works 85-92", genre: "Electronic"),
        ]),
        ("Ágætis byrjun", "Sigur Rós", [track("sr1", "Svefn-g-englar", artist: "Sigur Rós", album: "Ágætis byrjun", genre: "Post-Rock")]),
        ("Rounds", "Four Tet", [track("ft1", "She Moves She", artist: "Four Tet", album: "Rounds", genre: "Electronic")]),
    ]
    for (name, artist, tracks) in groups {
        let album = Album(id: iid("al-\(name)"), name: name, artist: artist, songCount: tracks.count)
        try store.upsert(AlbumDetail(album: album, tracks: tracks))
    }
    return store
}

actor FakeLibrary: LibrarySource {
    nonisolated let id = src
    var similarResponses: [ItemID: [Track]] = [:]
    var similarCalls: [ItemID] = []
    var frequentCalls = 0

    func setSimilar(_ tracks: [Track], for id: ItemID) { similarResponses[id] = tracks }

    func similar(to track: ItemID, count: Int) async throws -> [Track] {
        similarCalls.append(track)
        return similarResponses[track] ?? []
    }
    func albums(_ list: AlbumListKind, page: PageRequest) async throws -> Page<Album> {
        if list == .frequent { frequentCalls += 1 }
        return Page(items: [Album(id: iid("al-Dummy"), name: "Dummy", artist: "Portishead")], request: page)
    }
    func capabilities() async throws -> LibraryCapabilities { [] }
    func album(_ id: ItemID) async throws -> AlbumDetail { fatalError() }
    func artists() async throws -> [Artist] { [] }
    func artist(_ id: ItemID) async throws -> ArtistDetail { fatalError() }
    func playlists() async throws -> [Playlist] { [] }
    func playlist(_ id: ItemID) async throws -> PlaylistDetail { fatalError() }
    func search(_ query: String, limit: Int) async throws -> SearchResults { .init() }
    func streamRequest(for track: ItemID, quality: StreamQuality, offset: Duration?) async throws -> URLRequest { fatalError() }
    func coverArtURL(_ coverArtID: String, size: Int) async throws -> URL { fatalError() }
    func lyrics(for track: Track) async throws -> Lyrics? { nil }
    func setStarred(_ starred: Bool, _ target: StarTarget) async throws {}
    func report(_ event: PlaybackEvent) async throws {}
    func savePlayQueue(_ tracks: [ItemID], current: ItemID?, position: Duration) async throws {}
    func loadPlayQueue() async throws -> SavedPlayQueue? { nil }
}

private func lbClient(_ t: LBTransport, token: String? = "secret") -> ListenBrainzClient {
    ListenBrainzClient(token: token, transport: t, userAgent: "Tuner/test")
}

// MARK: Client

@Suite struct ListenBrainzClientTests {
    @Test func validateTokenSendsAuthHeader() async throws {
        let t = LBTransport()
        t.route("validate-token", "validate-token")
        let user = try await lbClient(t).validateToken()
        #expect(user == "tuneruser")
        let req = try #require(t.requests.first)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Token secret")
        #expect(req.value(forHTTPHeaderField: "User-Agent") == "Tuner/test")
        #expect(req.url?.host() == "api.listenbrainz.org")
    }

    @Test func invalidAndMissingTokens() async {
        let t = LBTransport()
        t.route("validate-token", "validate-token-invalid")
        await #expect(throws: ListenBrainzError.invalidToken) { try await lbClient(t).validateToken() }
        await #expect(throws: ListenBrainzError.missingToken) { try await lbClient(t, token: nil).validateToken() }
    }

    @Test func createdForPlaylistsParseKindAndDate() async throws {
        let t = LBTransport()
        t.route("playlists/createdfor", "createdfor")
        let lists = try await lbClient(t).createdForPlaylists(user: "tuneruser")
        #expect(lists.count == 3)
        #expect(lists.map(\.kind) == [.weeklyJams, .weeklyJams, .weeklyExploration])
        #expect(lists[1].id == "22222222-2222-4222-8222-222222222222")
        #expect(lists[1].date! > lists[0].date!)
        #expect(t.requests.first?.url?.path() == "/1/user/tuneruser/playlists/createdfor")
    }

    @Test func playlistTracksHandleStringOrArrayIdentifiers() async throws {
        let t = LBTransport()
        t.route("/1/playlist/", "playlist-jams")
        let recs = try await lbClient(t).playlistRecordings("22222222-2222-4222-8222-222222222222")
        #expect(recs.count == 3)
        #expect(recs[0].mbid == "aaaaaaaa-0000-4000-8000-000000000001")
        #expect(recs[0].artistMBIDs == ["69158f97-4c07-4c4e-baf8-4e4ab1ed666e"])
        #expect(recs[1].mbid == "bbbbbbbb-0000-4000-8000-000000000002")   // single-string identifier
        #expect(recs[1].artist == "Portishead")
    }

    @Test func recommendationsAndEmpty204() async throws {
        let t = LBTransport()
        t.route("cf/recommendation", "cf-recommendations")
        let recs = try await lbClient(t).recommendations(user: "tuneruser", count: 3)
        #expect(recs.map(\.recordingMBID).first == "aaaaaaaa-0000-4000-8000-000000000001")
        #expect(recs.first?.score == 0.93)

        let empty = LBTransport()
        empty.route("cf/recommendation", "", status: 204)
        #expect(try await lbClient(empty).recommendations(user: "new").isEmpty)
    }

    @Test func lookupPostsBatchAndDropsUnknown() async throws {
        let t = LBTransport()
        t.route("recording-mbid-lookup", "recording-lookup")
        let recs = try await lbClient(t).lookupRecordings(["eeeeeeee-0000-4000-8000-000000000005", "ffffffff-0000-4000-8000-000000000006"])
        #expect(recs.count == 1)
        #expect(recs[0].title == "Xtal")
        #expect(recs[0].artistMBIDs == ["f22942a1-6f70-4f48-866e-238cb2308fbd"])
        let req = try #require(t.requests.first)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.host() == "labs.api.listenbrainz.org")
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [[String: String]]
        #expect(body.count == 2)
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)  // never send the token to labs
    }

    @Test func similarArtistsExcludeReferenceArtist() async throws {
        let t = LBTransport()
        t.route("similar-artists", "similar-artists")
        let similar = try await lbClient(t).similarArtists(to: "69158f97-4c07-4c4e-baf8-4e4ab1ed666e")
        #expect(similar.map(\.name) == ["Aphex Twin", "Four Tet"])
        let q = URLComponents(url: t.requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(q.contains { $0.name == "algorithm" && $0.value == ListenBrainzClient.similarArtistsAlgorithm })
    }

    @Test func httpErrorsAreTyped() async {
        let t = LBTransport()
        t.route("validate-token", "", status: 401)
        await #expect(throws: ListenBrainzError.invalidToken) { try await lbClient(t).validateToken() }
        let r = LBTransport()
        r.route("similar-artists", "", status: 429)
        await #expect(throws: ListenBrainzError.rateLimited(retryAfter: nil)) { try await lbClient(r).similarArtists(to: "x") }
    }
}

// MARK: Matching

@Suite struct LibraryMatcherTests {
    @Test func prefersMBIDCaseInsensitively() throws {
        let matcher = LibraryMatcher(store: try seededStore())
        // Wrong title on purpose: MBID must win.
        let hit = matcher.match(LBRecording(mbid: "aaaaaaaa-0000-4000-8000-000000000001", title: "Something Else", artist: "Nobody"))
        #expect(hit?.id == iid("boc1"))
    }

    @Test func fuzzyMatchesDecoratedTitlesAndDiacritics() throws {
        let matcher = LibraryMatcher(store: try seededStore())
        #expect(matcher.match(LBRecording(mbid: nil, title: "Strangers (Remastered)", artist: "Portishead"))?.id == iid("ph1"))
        #expect(matcher.match(LBRecording(mbid: nil, title: "Svefn-g-englar", artist: "Sigur Ros"))?.id == iid("sr1"))
        #expect(matcher.match(LBRecording(mbid: nil, title: "Xtal - 2008 Remaster", artist: "Aphex Twin feat. Nobody"))?.id == iid("at1"))
    }

    @Test func noFalsePositivesAcrossArtists() throws {
        let matcher = LibraryMatcher(store: try seededStore())
        #expect(matcher.match(LBRecording(mbid: nil, title: "Strangers", artist: "The Kinks")) == nil)
        #expect(matcher.match(LBRecording(mbid: nil, title: "Strange", artist: "Portishead")) == nil)
    }

    @Test func batchDeduplicates() throws {
        let matcher = LibraryMatcher(store: try seededStore())
        let recs = [
            LBRecording(mbid: "aaaaaaaa-0000-4000-8000-000000000001", title: "Roygbiv", artist: "Boards of Canada"),
            LBRecording(mbid: nil, title: "Roygbiv", artist: "Boards of Canada"),
            LBRecording(mbid: nil, title: "Nope", artist: "Nobody"),
        ]
        #expect(matcher.match(recs).map(\.id) == [iid("boc1")])
    }

    @Test func normalizer() {
        #expect(TextNormalizer.title("Heroes (2017 Remaster)") == "heroes")
        #expect(TextNormalizer.title("Song - Radio Edit") == "song")
        #expect(TextNormalizer.title("Ágætis Byrjun") == "agaetis byrjun")
        #expect(TextNormalizer.artist("The Beatles") == "beatles")
        #expect(TextNormalizer.artist("Simon & Garfunkel") == "simon and garfunkel")
    }
}

// MARK: Auto-continue

@Suite struct AutoContinueTests {
    @Test func usesServerSimilarSongsAndDeduplicates() async throws {
        let store = try seededStore()
        let lib = FakeLibrary()
        let boc1 = try #require(try store.tracks(ids: [iid("boc1")]).first)
        let at1 = try #require(try store.tracks(ids: [iid("at1")]).first)
        let at2 = try #require(try store.tracks(ids: [iid("at2")]).first)
        let ph1 = try #require(try store.tracks(ids: [iid("ph1")]).first)
        // Server returns: something already in the queue, a duplicate (same artist+title, other ID), and new tracks.
        let dupe = Track(id: iid("dup-xtal"), title: "Xtal", artist: "Aphex Twin")
        await lib.setSimilar([boc1, at1, dupe, at2, ph1], for: boc1.id)

        let auto = AutoContinue(library: lib, store: store, listenBrainz: nil)
        let queue = PlayQueue(tracks: [boc1])
        let next = await auto.nextTracks(after: queue)
        #expect(!next.contains { $0.id == boc1.id })
        #expect(next.filter { $0.title == "Xtal" }.count == 1)
        #expect(Array(next.prefix(3)).map(\.id).contains(at1.id))
        #expect(next.contains { $0.id == ph1.id })
    }

    @Test func historyPreventsRepeatsAcrossContinuations() async throws {
        let store = try seededStore()
        let lib = FakeLibrary()
        let boc1 = try #require(try store.tracks(ids: [iid("boc1")]).first)
        let at1 = try #require(try store.tracks(ids: [iid("at1")]).first)
        await lib.setSimilar([at1], for: boc1.id)
        await lib.setSimilar([boc1], for: at1.id)

        var options = AutoContinue.Options()
        options.count = 1
        let auto = AutoContinue(library: lib, store: store, listenBrainz: nil, options: options)
        #expect(await auto.nextTracks(after: PlayQueue(tracks: [boc1])).map(\.id) == [at1.id])
        // Next continuation is seeded by at1; the server suggests boc1, which was just played.
        let second = await auto.nextTracks(after: PlayQueue(tracks: [at1]))
        #expect(!second.contains { $0.id == boc1.id })
        #expect(!second.isEmpty)   // filled from the local fallbacks instead
    }

    @Test func fallsBackToListenBrainzSimilarArtists() async throws {
        let store = try seededStore()
        let lib = FakeLibrary()   // server has no similar songs
        let t = LBTransport()
        t.route("recording-mbid-lookup", "recording-lookup-boc")
        t.route("similar-artists", "similar-artists")
        // Seed's recording MBID resolves to Boards of Canada → similar: Aphex Twin, Four Tet.
        let boc1 = try #require(try store.tracks(ids: [iid("boc1")]).first)

        var options = AutoContinue.Options()
        options.count = 4
        let auto = AutoContinue(library: lib, store: store, listenBrainz: lbClient(t), options: options)
        let next = await auto.nextTracks(after: PlayQueue(tracks: [boc1]))
        let artists = Set(next.map(\.artist))
        #expect(artists.contains("Aphex Twin"))
        #expect(artists.contains("Four Tet"))
        #expect(t.requests.contains { $0.url?.path().contains("similar-artists") == true })
    }

    @Test func offlineFallbackUsesSameArtistThenGenre() async throws {
        let store = try seededStore()
        let lib = FakeLibrary()
        let t = LBTransport()
        t.fail = true
        let at1 = try #require(try store.tracks(ids: [iid("at1")]).first)
        let auto = AutoContinue(library: lib, store: store, listenBrainz: lbClient(t))
        let next = await auto.nextTracks(after: PlayQueue(tracks: [at1]))
        #expect(next.contains { $0.id == iid("at2") })
        #expect(next.contains { $0.genre == "Electronic" && $0.artist != "Aphex Twin" })
        #expect(!next.contains { $0.id == at1.id })
    }

    @Test func spreadsArtists() {
        let a = (0..<4).map { track("a\($0)", "A\($0)", artist: "A") }
        let b = (0..<2).map { track("b\($0)", "B\($0)", artist: "B") }
        let spread = AutoContinue.spreadArtists(a + b, maxRun: 2)
        let runs = spread.map(\.artist!)
        for i in 2..<runs.count { #expect(!(runs[i] == runs[i - 1] && runs[i] == runs[i - 2]) || !runs.contains("B")) }
        #expect(spread.count == 6)
        #expect(Array(runs.prefix(3)) == ["A", "A", "B"])
    }

    @Test func seedsFollowShuffledPlayOrder() async throws {
        let store = try seededStore()
        let lib = FakeLibrary()
        let tracks = try store.tracks(ids: [iid("boc1"), iid("boc2"), iid("boc3"), iid("ph1")])
        var queue = PlayQueue(tracks: tracks, shuffled: true)
        while queue.advance() != nil {}
        var options = AutoContinue.Options()
        options.seedCount = 1
        let auto = AutoContinue(library: lib, store: store, listenBrainz: nil, options: options)
        _ = await auto.nextTracks(after: queue)
        let lastPlayed = queue.context[queue.order.last!]
        #expect(await lib.similarCalls == [lastPlayed.id])
    }
}

// MARK: Home feed

@Suite struct HomeFeedTests {
    func lbTransport() -> LBTransport {
        let t = LBTransport()
        t.route("playlists/createdfor", "createdfor")
        t.route("/1/playlist/2222", "playlist-jams")
        t.route("/1/playlist/3333", "playlist-exploration")
        t.route("cf/recommendation", "cf-recommendations")
        t.route("recording-mbid-lookup", "recording-lookup")
        return t
    }

    @Test func buildsForYouAndWeeklyShelvesFromLibraryMatches() async throws {
        let store = try seededStore()
        let t = lbTransport()
        let feed = HomeFeed(store: store, library: FakeLibrary(), listenBrainz: lbClient(t), user: "tuneruser")
        let shelves = await feed.shelves()
        let kinds = shelves.map(\.kind)
        #expect(kinds.first == .forYou)
        #expect(kinds.contains(.weeklyJams))
        #expect(kinds.contains(.weeklyExploration))
        #expect(kinds.contains(.heavyRotation))
        #expect(kinds.contains(.newInLibrary))

        guard case .tracks(let forYou) = shelves[0].content else { Issue.record("not tracks"); return }
        // MBID hit (Roygbiv) + lookup + fuzzy (Xtal); the unknown MBID is dropped.
        #expect(forYou.map(\.id) == [iid("boc1"), iid("at1")])

        let jams = try #require(shelves.first { $0.kind == .weeklyJams })
        guard case .tracks(let jamTracks) = jams.content else { return }
        #expect(jamTracks.map(\.id) == [iid("boc1"), iid("ph1")])   // newest Weekly Jams; "Not In Library" skipped
        #expect(t.requests.contains { $0.url?.path().contains("22222222") == true })
        #expect(!t.requests.contains { $0.url?.path().contains("11111111") == true })  // older week not fetched
    }

    @Test func cachesListenBrainzAndServerShelves() async throws {
        let store = try seededStore()
        let t = lbTransport()
        let lib = FakeLibrary()
        let feed = HomeFeed(store: store, library: lib, listenBrainz: lbClient(t), user: "tuneruser")
        _ = await feed.shelves()
        let first = t.requests.count
        _ = await feed.shelves()
        #expect(t.requests.count == first)
        #expect(await lib.frequentCalls == 1)
        _ = await feed.shelves(force: true)
        #expect(t.requests.count > first)
        #expect(await lib.frequentCalls == 2)
    }

    @Test func persistedForYouSurvivesRestartAndOffline() async throws {
        let store = try seededStore()
        let online = HomeFeed(store: store, library: nil, listenBrainz: lbClient(lbTransport()), user: "tuneruser")
        _ = await online.shelves()

        let offline = LBTransport()
        offline.fail = true
        let restarted = HomeFeed(store: store, library: nil, listenBrainz: lbClient(offline), user: "tuneruser")
        let shelves = await restarted.shelves()
        #expect(shelves.first?.kind == .forYou)
        #expect(offline.requests.isEmpty)   // served from the persisted cache
    }

    @Test func failureDoesNotCacheEmptiness() async throws {
        let store = try seededStore()
        let t = LBTransport()
        t.fail = true
        let feed = HomeFeed(store: store, library: nil, listenBrainz: lbClient(t), user: "tuneruser")
        #expect(await feed.shelves().allSatisfy { $0.kind != .forYou })
        let before = t.requests.count
        _ = await feed.shelves()
        #expect(t.requests.count > before)   // retried, not cached as "nothing"
    }

    @Test func withoutListenBrainzOnlyLocalShelves() async throws {
        let store = try seededStore()
        let shelves = await HomeFeed(store: store, library: nil, listenBrainz: nil, user: nil).shelves()
        #expect(shelves.map(\.kind) == [.newInLibrary])
    }
}

// MARK: Live (opt-in)

@Suite(.enabled(if: ProcessInfo.processInfo.environment["TUNER_LB_LIVE"] == "1"))
struct ListenBrainzLiveTests {
    @Test func similarArtistsForBoardsOfCanada() async throws {
        let client = ListenBrainzClient(token: nil, userAgent: "Tuner/0.1 (integration test)")
        let similar = try await client.similarArtists(to: "69158f97-4c07-4c4e-baf8-4e4ab1ed666e", limit: 30)
        #expect(similar.count >= 10)
        #expect(similar.contains { $0.name == "Aphex Twin" })
    }

    @Test func recordingLookup() async throws {
        let client = ListenBrainzClient(token: nil, userAgent: "Tuner/0.1 (integration test)")
        let recs = try await client.lookupRecordings(["e97f805a-ab48-4c52-855e-07049142113d"])
        #expect(recs.first?.title == "Strangers")
        #expect(recs.first?.artist == "Portishead")
    }
}
