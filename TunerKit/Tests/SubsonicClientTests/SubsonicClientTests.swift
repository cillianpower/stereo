import Testing
import Foundation
import TunerModel
@testable import SubsonicClient

/// Routes `rest/<endpoint>` to `Fixtures/<endpoint>.json` and records every request.
final class FixtureTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var overrides: [String: String] = [:]          // endpoint → fixture name
    var unreachableHosts: Set<String> = []

    var requests: [URLRequest] { lock.withLock { _requests } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let url = request.url!
        if unreachableHosts.contains(url.host() ?? "") { throw URLError(.cannotConnectToHost) }
        let endpoint = url.lastPathComponent
        let name = overrides[endpoint] ?? endpoint
        guard let fixture = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            return (Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8),
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        return (try Data(contentsOf: fixture), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private let lan = URL(string: "http://192.168.1.10:4533")!
private let remote = URL(string: "https://music.example.net")!

private func makeLibrary(_ transport: FixtureTransport, urls: [URL] = [lan]) -> SubsonicLibrary {
    SubsonicLibrary(
        configuration: ServerConfiguration(name: "Home", urls: urls, username: "me", credential: .password("sesame")),
        transport: transport
    )
}

private func query(_ request: URLRequest) -> [String: String] {
    let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
}

@Suite struct AlbumInfoTests {
    @Test func combinesOpenSubsonicFieldsAndServerNotes() async throws {
        let transport = FixtureTransport()
        transport.overrides["getAlbum"] = "getAlbumRich"
        let library = makeLibrary(transport)
        let info = try await library.albumInfo(ItemID(source: library.id, raw: "al-1"))
        #expect(info.labels == ["Warp", "Skam"])
        #expect(info.genres == ["IDM", "Ambient"])
        #expect(info.moods == ["Hazy"])
        #expect(info.released == AlbumInfo.ReleaseDate(year: 1998, month: 4, day: 20))
        #expect(info.version == "Remaster")
        #expect(info.notes == "An \"electronic\" landmark & debut.\nReleased in 1998.")
        #expect(info.lastFmURL?.host() == "www.last.fm")
        #expect(info.musicBrainzID == "9f2f4e1a-4bb8-4c0e-9d7f-111111111111")
    }

    @Test func artistBiographyIsReadableText() async throws {
        let library = makeLibrary(FixtureTransport())
        let info = try await library.artistInfo(ItemID(source: library.id, raw: "ar-1"))
        #expect(info.biography == "A \"pioneering\" duo & label.\nFormed in 1987.")
        #expect(info.lastFmURL?.host() == "www.last.fm")
    }

    @Test func aServerWithoutExtrasStillReturnsInfo() async throws {
        let transport = FixtureTransport()
        transport.overrides["getAlbumInfo2"] = "missing"
        let library = makeLibrary(transport)
        let info = try await library.albumInfo(ItemID(source: library.id, raw: "al-1"))
        #expect(info.notes == nil)
        #expect(info.labels.isEmpty)
    }
}

@Suite struct SubsonicAPITests {
    @Test func tokenAuthUsesSaltedMD5() {
        let api = SubsonicAPI(
            config: ServerConfiguration(name: "x", urls: [lan], username: "admin", credential: .password("sesame")),
            transport: FixtureTransport(),
            saltGenerator: { "c19b2d" }
        )
        let url = api.url(base: lan, endpoint: "ping")
        let q = query(URLRequest(url: url))
        // Example from the Subsonic API docs: md5("sesamec19b2d")
        #expect(q["t"] == "26719a1196d2a940705a59634eb18eab")
        #expect(q["s"] == "c19b2d")
        #expect(q["u"] == "admin")
        #expect(q["p"] == nil)
        #expect(q["f"] == "json")
        #expect(url.path() == "/rest/ping")
    }

    @Test func apiKeyAuthOmitsUsername() {
        let api = SubsonicAPI(
            config: ServerConfiguration(name: "x", urls: [lan], username: "admin", credential: .apiKey("KEY")),
            transport: FixtureTransport()
        )
        let q = query(URLRequest(url: api.url(base: lan, endpoint: "ping")))
        #expect(q["apiKey"] == "KEY")
        #expect(q["u"] == nil)
        #expect(q["t"] == nil)
    }

    @Test func serverErrorIsTyped() throws {
        let url = Bundle.module.url(forResource: "auth_failed", withExtension: "json", subdirectory: "Fixtures")!
        #expect(throws: SubsonicError.server(code: 40, message: "Wrong username or password")) {
            _ = try SubsonicAPI.decode(PingBody.self, from: try Data(contentsOf: url))
        }
    }

    @Test func authFailureStillCountsAsReachable() async {
        let t = FixtureTransport()
        t.overrides["ping"] = "auth_failed"
        let api = SubsonicAPI(config: ServerConfiguration(name: "x", urls: [lan], username: "u", credential: .password("p")), transport: t)
        #expect(await api.isReachable(base: lan))
        await #expect(throws: SubsonicError.self) { try await api.ping(base: lan) }
    }
}

@Suite struct SubsonicLibraryTests {
    @Test func albumListMapsFields() async throws {
        let lib = makeLibrary(FixtureTransport())
        let page = try await lib.albums(.recent, page: PageRequest(offset: 0, size: 2))
        #expect(page.items.count == 2)
        #expect(page.hasMore)
        let first = page.items[0]
        #expect(first.name == "Music Has the Right to Children")
        #expect(first.id == ItemID(source: lib.id, raw: "al-1"))
        #expect(first.duration == .seconds(4241))
        #expect(first.lastPlayed != nil)
        #expect(page.items[1].starred != nil)
    }

    @Test func albumDetailMapsTracksAndReplayGain() async throws {
        let lib = makeLibrary(FixtureTransport())
        let detail = try await lib.album(ItemID(source: lib.id, raw: "al-1"))
        #expect(detail.tracks.count == 2)
        let t = detail.tracks[0]
        #expect(t.replayGain.trackGain == -6.5)
        #expect(t.replayGain.albumPeak == 1.0)
        #expect(t.format.codec == "flac")
        #expect(t.format.isLossless)
        #expect(!t.format.isHiRes)
        #expect(detail.tracks[1].format.isHiRes)
        #expect(detail.tracks[1].rating == 5)
    }

    @Test func artistsFlattenIndexes() async throws {
        let lib = makeLibrary(FixtureTransport())
        let artists = try await lib.artists()
        #expect(artists.map(\.name) == ["Aphex Twin", "Boards of Canada"])
    }

    @Test func searchHandlesMissingSections() async throws {
        let lib = makeLibrary(FixtureTransport())
        let r = try await lib.search("boards", limit: 10)
        #expect(r.artists.count == 1)
        #expect(r.albums.isEmpty)
        #expect(r.tracks.first?.duration == .seconds(77))
    }

    @Test func prefersSyncedLyricsAndAppliesOffset() async throws {
        let lib = makeLibrary(FixtureTransport())
        let track = Track(id: ItemID(source: lib.id, raw: "s-1"), title: "x", artist: "y")
        let lyrics = try #require(try await lib.lyrics(for: track))
        #expect(lyrics.isSynced)
        #expect(lyrics.lines.map(\.text) == ["first", "second"])
        #expect(lyrics.lines[0].start == .milliseconds(900))
    }

    @Test func streamOriginalUsesRawFormat() async throws {
        let lib = makeLibrary(FixtureTransport())
        let req = try await lib.streamRequest(for: ItemID(source: lib.id, raw: "s-1"), quality: .original, offset: nil)
        let q = query(req)
        #expect(req.url?.path() == "/rest/stream")
        #expect(q["format"] == "raw")
        #expect(q["id"] == "s-1")
    }

    @Test func transcodedStreamUsesTimeOffsetWhenSupported() async throws {
        let lib = makeLibrary(FixtureTransport())
        let req = try await lib.streamRequest(for: ItemID(source: lib.id, raw: "s-1"),
                                              quality: .transcoded(format: "aac", maxBitRate: 256),
                                              offset: .seconds(42))
        let q = query(req)
        #expect(q["format"] == "aac")
        #expect(q["maxBitRate"] == "256")
        #expect(q["timeOffset"] == "42")
    }

    @Test func rejectsForeignIDs() async {
        let lib = makeLibrary(FixtureTransport())
        await #expect(throws: SubsonicError.invalidID("other:al-1")) {
            _ = try await lib.album(ItemID(source: SourceID("other"), raw: "al-1"))
        }
    }

    @Test func scrobbleSubmission() async throws {
        let t = FixtureTransport()
        let lib = makeLibrary(t)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try await lib.report(.played(ItemID(source: lib.id, raw: "s-1"), at: date))
        let scrobble = try #require(t.requests.last)
        #expect(scrobble.url?.lastPathComponent == "scrobble")
        #expect(query(scrobble)["submission"] == "true")
        #expect(query(scrobble)["time"] == "1700000000000")
    }

    @Test func playQueueRoundTrip() async throws {
        let lib = makeLibrary(FixtureTransport())
        let q = try #require(try await lib.loadPlayQueue())
        #expect(q.tracks.count == 2)
        #expect(q.current == ItemID(source: lib.id, raw: "s-2"))
        #expect(q.position == .milliseconds(61_500))
        #expect(q.changedBy == "Tuner")
    }

    @Test func failsOverToRemoteWhenLANUnreachable() async throws {
        let t = FixtureTransport()
        t.unreachableHosts = ["192.168.1.10"]
        let lib = makeLibrary(t, urls: [lan, remote])
        _ = try await lib.albums(.newest, page: .init())
        #expect(await lib.resolver.current == remote)
    }
}

@Suite struct EndpointResolverTests {
    @Test func prefersEarlierURLEvenIfSlower() async throws {
        let resolver = EndpointResolver(urls: [lan, remote]) { url in
            if url == lan { try? await Task.sleep(for: .milliseconds(100)) }
            return true
        }
        #expect(try await resolver.resolve() == lan)
    }

    @Test func hangingLANDoesNotBlockRemoteBeyondGrace() async throws {
        let resolver = EndpointResolver(urls: [lan, remote], grace: .milliseconds(200)) { url in
            if url == lan { try? await Task.sleep(for: .seconds(10)); return false }
            return true
        }
        let start = ContinuousClock.now
        #expect(try await resolver.resolve() == remote)
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func throwsWhenNothingAnswers() async {
        let resolver = EndpointResolver(urls: [lan, remote]) { _ in false }
        await #expect(throws: SubsonicError.noReachableEndpoint) { try await resolver.resolve() }
    }

    @Test func reprobesAfterInvalidate() async throws {
        let flag = Flag()
        let resolver = EndpointResolver(urls: [lan, remote]) { url in
            url == lan ? await flag.value : true
        }
        await flag.set(true)
        #expect(try await resolver.resolve() == lan)
        await flag.set(false)
        #expect(try await resolver.resolve() == lan)  // cached
        await resolver.invalidate()
        #expect(try await resolver.resolve() == remote)
    }
}

actor Flag {
    var value = false
    func set(_ v: Bool) { value = v }
}
