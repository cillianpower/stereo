import Foundation
import Testing
import StereoModel
@testable import StereoRadio

final class CannedTransport: HTTPTransport, @unchecked Sendable {
    var responses: [String: (body: String, headers: [String: String])] = [:]   // keyed by URL string
    private(set) var count = 0

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        let key = request.url!.absoluteString
        let match: (body: String, headers: [String: String]) = responses.first { key.hasPrefix($0.key) }?.value ?? (body: "", headers: [:])
        return (Data(match.body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: match.headers)!)
    }
}

@Suite struct StreamProberTests {
    @Test func unwrapsPLSThenReadsICYHeaders() async throws {
        let t = CannedTransport()
        t.responses["https://example.com/listen.pls"] = ("""
            [playlist]
            NumberOfEntries=2
            File2=https://backup.example.com/stream
            File1=https://ice.example.com/stream
            Title1=Example FM
            """, ["Content-Type": "audio/x-scpls"])
        t.responses["https://ice.example.com/stream"] = ("", ["Content-Type": "audio/mpeg", "icy-br": "320", "icy-name": "Example FM"])
        let resolved = try await StreamProber(transport: t).probe(URL(string: "https://example.com/listen.pls")!)
        #expect(resolved.url.absoluteString == "https://ice.example.com/stream")
        #expect(resolved.bitRate == 320)
        #expect(resolved.name == "Example FM")
        #expect(!resolved.isHLS)
    }

    @Test func detectsHLS() async throws {
        let t = CannedTransport()
        t.responses["https://example.com/live.m3u8"] = ("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=128000\nchunklist.m3u8", ["Content-Type": "application/vnd.apple.mpegurl"])
        let resolved = try await StreamProber(transport: t).probe(URL(string: "https://example.com/live.m3u8")!)
        #expect(resolved.isHLS)
    }

    @Test func m3uRelativeEntry() {
        let url = StreamProber.firstEntry(inPlaylist: "#EXTM3U\n#EXTINF:-1,Foo\nstream.mp3\n", base: URL(string: "http://h.example/radio/list.m3u")!)
        #expect(url?.absoluteString == "http://h.example/radio/stream.mp3")
    }
}

@Suite struct EnricherTests {
    @Test func normalizeStripsDecorations() {
        #expect(NowPlayingEnricher.normalize("Heroes (2017 Remaster)") == "Heroes")
        #expect(NowPlayingEnricher.normalize("Song [Explicit]") == "Song")
        #expect(NowPlayingEnricher.normalize("Song (Radio Edit)") == "Song")
        #expect(NowPlayingEnricher.normalize("Wish You Were Here - Remastered 2011") == "Wish You Were Here")
        #expect(NowPlayingEnricher.normalize("(Untitled)") == "(Untitled)")
    }

    @Test func picksMatchingArtistAndUpsizesArtwork() async {
        let t = CannedTransport()
        t.responses["https://itunes.apple.com/search"] = ("""
            {"resultCount":2,"results":[
              {"artistName":"Some Cover Band","trackName":"Roygbiv","collectionName":"Covers","artworkUrl100":"https://is1.example/a/100x100bb.jpg"},
              {"artistName":"Boards of Canada","trackName":"Roygbiv","collectionName":"Music Has the Right to Children","artworkUrl100":"https://is1.example/b/100x100bb.jpg"}
            ]}
            """, [:])
        let enricher = NowPlayingEnricher(transport: t)
        let r = await enricher.enrich(StreamTitle(raw: "Boards of Canada - Roygbiv"))
        #expect(r?.album == "Music Has the Right to Children")
        #expect(r?.artworkURL?.absoluteString == "https://is1.example/b/600x600bb.jpg")
        _ = await enricher.enrich(StreamTitle(raw: "Boards of Canada - Roygbiv"))
        #expect(t.count == 1)  // cached
    }

    @Test func skipsStationIdents() async {
        let enricher = NowPlayingEnricher(transport: CannedTransport())
        #expect(await enricher.enrich(StreamTitle(raw: "Radio Paradise - commercial free"), stationName: nil) != nil)
        #expect(await enricher.enrich(StreamTitle(raw: "You're listening to KEXP"), stationName: "KEXP") == nil)
        #expect(await enricher.enrich(StreamTitle(raw: "Jingle"), stationName: nil) == nil)
    }
}
