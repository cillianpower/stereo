import Testing
import Foundation
import TunerModel
@testable import RadioBrowserClient

final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var failingHosts: Set<String> = []
    var body = Data()
    var requests: [URLRequest] { lock.withLock { _requests } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let url = request.url!
        if failingHosts.contains(url.host() ?? "") { throw URLError(.cannotConnectToHost) }
        return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private let stationsJSON = Data("""
[{"changeuuid":"x","stationuuid":"961e1a5b-0601-11e8-ae97-52543be04c81","name":" Radio Paradise Main Mix (FLAC) ",
  "url":"http://stream.radioparadise.com/flac","url_resolved":"https://stream.radioparadise.com/flac",
  "homepage":"https://radioparadise.com/","favicon":"https://radioparadise.com/favicon.ico","tags":"eclectic,rock, indie",
  "countrycode":"US","language":"english","codec":"FLAC","bitrate":0,"hls":0,"votes":9001,"lastcheckok":1},
 {"stationuuid":"b","name":"HLS One","url":"https://example.com/live.m3u8","url_resolved":"","favicon":"","tags":"",
  "countrycode":"","codec":"AAC","bitrate":128,"hls":1,"votes":3}]
""".utf8)

@Suite struct RadioBrowserClientTests {
    @Test func searchBuildsQueryAndMapsStations() async throws {
        let t = StubTransport()
        t.body = stationsJSON
        let client = RadioBrowserClient(transport: t, userAgent: "Tuner/test", discoverHosts: { ["de1.api.radio-browser.info"] })
        let stations = try await client.search(StationQuery(name: "paradise", tags: ["rock", "indie"], codec: "FLAC", bitrateMin: 256, order: .votes, reverse: true))

        let req = try #require(t.requests.first)
        let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        let q = Dictionary(uniqueKeysWithValues: comps.queryItems!.map { ($0.name, $0.value!) })
        #expect(comps.host == "de1.api.radio-browser.info")
        #expect(comps.path == "/json/stations/search")
        #expect(q["name"] == "paradise")
        #expect(q["tagList"] == "rock,indie")
        #expect(q["bitrateMin"] == "256")
        #expect(q["order"] == "votes")
        #expect(q["hidebroken"] == "true")
        #expect(req.value(forHTTPHeaderField: "User-Agent") == "Tuner/test")

        #expect(stations.count == 2)
        let rp = stations[0]
        #expect(rp.name == "Radio Paradise Main Mix (FLAC)")
        #expect(rp.streamURL.absoluteString == "https://stream.radioparadise.com/flac")
        #expect(rp.tags == ["eclectic", "rock", "indie"])
        #expect(rp.bitRate == nil)
        #expect(rp.origin == .radioBrowser(uuid: "961e1a5b-0601-11e8-ae97-52543be04c81"))

        let hls = stations[1]
        #expect(hls.isHLS)
        #expect(hls.streamURL.absoluteString == "https://example.com/live.m3u8")
        #expect(hls.faviconURL == nil)
        #expect(hls.countryCode == nil)
    }

    @Test func rotatesToWorkingMirror() async throws {
        let t = StubTransport()
        t.body = Data("[]".utf8)
        t.failingHosts = ["a.api.radio-browser.info"]
        let client = RadioBrowserClient(transport: t, discoverHosts: { ["a.api.radio-browser.info", "b.api.radio-browser.info"] })
        // Order is shuffled, so run a few times; it must always succeed.
        for _ in 0..<3 { _ = try await client.topVoted(limit: 5 + Int.random(in: 0...100)) }
        #expect(t.requests.contains { $0.url?.host() == "b.api.radio-browser.info" })
    }

    @Test func cachesRepeatQueries() async throws {
        let t = StubTransport()
        t.body = Data("[]".utf8)
        let client = RadioBrowserClient(transport: t, discoverHosts: { ["x.api.radio-browser.info"] })
        _ = try await client.topClicked(limit: 10)
        _ = try await client.topClicked(limit: 10)
        #expect(t.requests.count == 1)
    }
}
