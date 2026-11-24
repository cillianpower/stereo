import Foundation
import StereoModel

/// What we found out about a radio title.
public struct EnrichedTitle: Hashable, Sendable {
    public var artist: String?
    public var title: String
    public var album: String?
    public var artworkURL: URL?
}

/// Looks up artwork for ICY titles with the iTunes Search API (no key needed) and caches results
/// by normalised title, so a song that comes round again costs no request.
public actor NowPlayingEnricher {
    private let transport: HTTPTransport
    private var cache: [String: EnrichedTitle?] = [:]
    private let maxCache = 500

    public init(transport: HTTPTransport = URLSession.shared) { self.transport = transport }

    public func enrich(_ streamTitle: StreamTitle, stationName: String? = nil) async -> EnrichedTitle? {
        guard let title = streamTitle.title.map(Self.normalize), !title.isEmpty else { return nil }
        let artist = streamTitle.artist.map(Self.normalize)
        // Many stations put their own name or a slogan in StreamTitle between songs.
        if artist == nil, let stationName, title.localizedCaseInsensitiveContains(stationName) { return nil }
        // Without an "Artist - " part, short ad/ident markers are almost never songs.
        if artist == nil, Self.isProbablyNotASong(title) { return nil }

        let key = "\(artist ?? "")|\(title)".lowercased()
        if let cached = cache[key] { return cached }

        let result = await lookup(artist: artist, title: title)
        if cache.count > maxCache { cache.removeAll(keepingCapacity: true) }
        cache[key] = result
        return result
    }

    private func lookup(artist: String?, title: String) async -> EnrichedTitle? {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [
            .init(name: "term", value: [artist, title].compactMap { $0 }.joined(separator: " ")),
            .init(name: "entity", value: "song"),
            .init(name: "limit", value: "5"),
        ]
        guard let url = c.url, let (data, response) = try? await transport.data(for: URLRequest(url: url)),
              response.statusCode == 200,
              let decoded = try? JSONDecoder().decode(ITunesResponse.self, from: data) else {
            return EnrichedTitle(artist: artist, title: title)
        }
        // Prefer a result whose artist actually matches, so a cover version doesn't win.
        let best = decoded.results.first { r in
            guard let artist else { return true }
            return r.artistName.localizedCaseInsensitiveContains(artist) || artist.localizedCaseInsensitiveContains(r.artistName)
        } ?? (artist == nil ? decoded.results.first : nil)

        guard let best else { return EnrichedTitle(artist: artist, title: title) }
        let art = best.artworkUrl100.flatMap { URL(string: $0.replacingOccurrences(of: "100x100bb", with: "600x600bb")) }
        return EnrichedTitle(artist: artist ?? best.artistName, title: title, album: best.collectionName, artworkURL: art)
    }

    /// Strips decorations that break matching: "(Radio Edit)", "[Explicit]", "- Remastered 2011".
    public static func normalize(_ s: String) -> String {
        var out = s
        let patterns = [
            #"\s*[\(\[][^\)\]]*(edit|remaster|explicit|clean|version|mix|live|mono|stereo)[^\)\]]*[\)\]]"#,
            #"\s+-\s+(\d{4}\s+)?remaster(ed)?(\s+\d{4})?.*$"#,
        ]
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isProbablyNotASong(_ title: String) -> Bool {
        let lower = title.lowercased()
        let markers = ["advert", "commercial", "jingle", "station id", "news", "weather", "traffic"]
        return lower.count < 2 || markers.contains { lower == $0 || lower.hasPrefix($0 + " ") }
    }
}

struct ITunesResponse: Decodable {
    struct Result: Decodable {
        let artistName: String
        let trackName: String?
        let collectionName: String?
        let artworkUrl100: String?
    }
    let results: [Result]
}
