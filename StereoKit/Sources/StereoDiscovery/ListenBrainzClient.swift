import Foundation
import StereoModel

public enum ListenBrainzError: Error, Equatable, Sendable, LocalizedError {
    case missingToken
    case invalidToken
    case http(status: Int)
    case rateLimited(retryAfter: TimeInterval?)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken: "Add your ListenBrainz token in Settings."
        case .invalidToken: "That ListenBrainz token isn't valid."
        case .http(let status): "ListenBrainz returned HTTP \(status)."
        case .rateLimited: "ListenBrainz is rate limiting requests. Try again shortly."
        case .malformed(let detail): "Unexpected ListenBrainz response: \(detail)"
        }
    }
}

/// A recording ListenBrainz suggested, with whatever metadata it gave us.
public struct LBRecording: Hashable, Codable, Sendable {
    public var mbid: String?
    public var title: String
    public var artist: String?
    public var album: String?
    public var artistMBIDs: [String]

    public init(mbid: String?, title: String, artist: String?, album: String? = nil, artistMBIDs: [String] = []) {
        self.mbid = mbid
        self.title = title
        self.artist = artist
        self.album = album
        self.artistMBIDs = artistMBIDs
    }
}

public struct LBRecommendation: Hashable, Codable, Sendable {
    public var recordingMBID: String
    public var score: Double?
}

public struct LBSimilarArtist: Hashable, Codable, Sendable {
    public var mbid: String
    public var name: String
    public var score: Double
}

/// A "Created for you" playlist (Weekly Jams, Weekly Exploration, Daily Jams…).
public struct LBPlaylistSummary: Hashable, Codable, Sendable, Identifiable {
    public enum Kind: Hashable, Codable, Sendable {
        case weeklyJams, weeklyExploration, dailyJams
        case other(String)

        init(sourcePatch: String?, title: String) {
            let key = (sourcePatch ?? title).lowercased()
            if key.contains("weekly-jams") || key.contains("weekly jams") { self = .weeklyJams }
            else if key.contains("exploration") { self = .weeklyExploration }
            else if key.contains("daily-jams") || key.contains("daily jams") { self = .dailyJams }
            else { self = .other(sourcePatch ?? title) }
        }
    }

    public var id: String          // playlist MBID
    public var title: String
    public var kind: Kind
    public var date: Date?
}

/// Read-only ListenBrainz client: token check, "Created for you" playlists, collaborative-filtering
/// recommendations, recording lookup and similar artists. Listens are not submitted — Navidrome
/// already scrobbles to ListenBrainz server-side.
///
/// Endpoints (checked 2026-11-19):
/// - `GET /1/validate-token` — documented (Core API).
/// - `GET /1/user/{user}/playlists/createdfor`, `GET /1/playlist/{mbid}` — documented (Playlists API).
/// - `GET /1/cf/recommendation/user/{user}/recording` — documented, flagged experimental by LB.
/// - `POST labs.api.listenbrainz.org/recording-mbid-lookup/json` — verified live.
/// - `GET labs.api.listenbrainz.org/similar-artists/json` — verified live; the `algorithm` value is the
///   one the labs viewer currently offers and may change (see `similarArtistsAlgorithm`).
public actor ListenBrainzClient {
    public static let defaultAPI = URL(string: "https://api.listenbrainz.org")!
    public static let defaultLabs = URL(string: "https://labs.api.listenbrainz.org")!
    /// The only similar-artists dataset live on labs as of 2026-11. Overridable if LB rotates it.
    public static let similarArtistsAlgorithm =
        "session_based_days_1800_session_300_contribution_3_threshold_10_limit_100_filter_True_skip_30"

    private let transport: HTTPTransport
    private let api: URL
    private let labs: URL
    private let userAgent: String
    private var token: String?
    public var algorithm: String

    public init(token: String?, transport: HTTPTransport = URLSession.shared, userAgent: String = "Stereo/0.1",
                api: URL = ListenBrainzClient.defaultAPI, labs: URL = ListenBrainzClient.defaultLabs,
                algorithm: String = ListenBrainzClient.similarArtistsAlgorithm) {
        self.token = token
        self.transport = transport
        self.userAgent = userAgent
        self.api = api
        self.labs = labs
        self.algorithm = algorithm
    }

    public func setToken(_ token: String?) { self.token = token }

    // MARK: Account

    /// Returns the user name the token belongs to.
    public func validateToken() async throws -> String {
        guard token != nil else { throw ListenBrainzError.missingToken }
        let data = try await get(api, "1/validate-token", authenticated: true)
        struct Body: Decodable { let valid: Bool?; let user_name: String? }
        let body = try decode(Body.self, data)
        guard body.valid == true, let user = body.user_name else { throw ListenBrainzError.invalidToken }
        return user
    }

    // MARK: Created for you

    public func createdForPlaylists(user: String, count: Int = 25) async throws -> [LBPlaylistSummary] {
        let data = try await get(api, "1/user/\(user.pathEscaped)/playlists/createdfor",
                                 query: [.init(name: "count", value: String(count))])
        let body = try decode(PlaylistsEnvelope.self, data)
        return body.playlists.compactMap { wrapper in
            let p = wrapper.playlist
            guard let id = p.identifier.flatMap(Self.mbid(fromURL:)) else { return nil }
            let patch = p.extension?.playlist?.additional_metadata?.algorithm_metadata?.source_patch
            return LBPlaylistSummary(id: id, title: p.title ?? "Playlist", kind: .init(sourcePatch: patch, title: p.title ?? ""),
                                     date: p.date.flatMap(Self.parseDate))
        }
    }

    public func playlistRecordings(_ playlistMBID: String) async throws -> [LBRecording] {
        let data = try await get(api, "1/playlist/\(playlistMBID.pathEscaped)", authenticated: token != nil)
        let body = try decode(PlaylistEnvelope.self, data)
        return (body.playlist.track ?? []).compactMap { t in
            guard let title = t.title else { return nil }
            let mbid = t.identifier?.values.lazy.compactMap(Self.mbid(fromURL:)).first
            let artists = t.extension?.track?.additional_metadata?.artists?.compactMap(\.artist_mbid) ?? []
            return LBRecording(mbid: mbid, title: title, artist: t.creator, album: t.album, artistMBIDs: artists)
        }
    }

    // MARK: Recommendations

    /// Collaborative-filtering recommendations (MBIDs only). Empty when LB has none yet (HTTP 204).
    public func recommendations(user: String, count: Int = 100) async throws -> [LBRecommendation] {
        let data = try await get(api, "1/cf/recommendation/user/\(user.pathEscaped)/recording",
                                 query: [.init(name: "count", value: String(count))], authenticated: token != nil)
        guard !data.isEmpty else { return [] }
        struct Body: Decodable {
            struct Payload: Decodable {
                struct Item: Decodable { let recording_mbid: String; let score: Double? }
                let mbids: [Item]?
            }
            let payload: Payload?
        }
        return (try decode(Body.self, data).payload?.mbids ?? []).map { LBRecommendation(recordingMBID: $0.recording_mbid, score: $0.score) }
    }

    /// Resolves recording MBIDs to titles and artists in one request. Unknown MBIDs are dropped.
    public func lookupRecordings(_ mbids: [String]) async throws -> [LBRecording] {
        guard !mbids.isEmpty else { return [] }
        var results: [LBRecording] = []
        for chunk in stride(from: 0, to: mbids.count, by: 100).map({ Array(mbids[$0..<min($0 + 100, mbids.count)]) }) {
            let body = try JSONSerialization.data(withJSONObject: chunk.map { ["recording_mbid": $0] })
            let data = try await post(labs, "recording-mbid-lookup/json", body: body)
            struct Row: Decodable {
                struct Credit: Decodable { let artist_mbid: String? }
                let recording_mbid: String?
                let recording_name: String?
                let artist_credit_name: String?
                let release_name: String?
                let artists: [Credit]?
                let artist_credit_mbids: [String]?
            }
            for row in try decode([Row].self, data) {
                guard let mbid = row.recording_mbid, let name = row.recording_name else { continue }
                let artistMBIDs = row.artists?.compactMap(\.artist_mbid) ?? row.artist_credit_mbids ?? []
                results.append(LBRecording(mbid: mbid, title: name, artist: row.artist_credit_name,
                                           album: row.release_name, artistMBIDs: artistMBIDs))
            }
        }
        return results
    }

    // MARK: Similar artists

    public func similarArtists(to artistMBID: String, limit: Int = 25) async throws -> [LBSimilarArtist] {
        let data = try await get(labs, "similar-artists/json", query: [
            .init(name: "artist_mbids", value: artistMBID),
            .init(name: "algorithm", value: algorithm),
        ])
        struct Row: Decodable { let artist_mbid: String?; let name: String?; let score: Double? }
        // Labs returns a flat list; older deployments wrapped it as [[…]] — accept both.
        let rows: [Row]
        if let flat = try? JSONDecoder().decode([Row].self, from: data) { rows = flat }
        else { rows = try decode([[Row]].self, data).flatMap { $0 } }
        return rows.compactMap { r in
            guard let mbid = r.artist_mbid, let name = r.name, mbid != artistMBID else { return nil }
            return LBSimilarArtist(mbid: mbid, name: name, score: r.score ?? 0)
        }
        .prefix(limit).map { $0 }
    }

    // MARK: Plumbing

    private func get(_ base: URL, _ path: String, query: [URLQueryItem] = [], authenticated: Bool = false) async throws -> Data {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        return try await send(&request, authenticated: authenticated)
    }

    private func post(_ base: URL, _ path: String, body: Data) async throws -> Data {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(&request, authenticated: false)
    }

    private func send(_ request: inout URLRequest, authenticated: Bool) async throws -> Data {
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated, let token { request.setValue("Token \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await transport.data(for: request)
        switch response.statusCode {
        case 200..<300: return response.statusCode == 204 ? Data() : data
        case 401: throw ListenBrainzError.invalidToken
        case 429:
            let retry = response.value(forHTTPHeaderField: "X-RateLimit-Reset-In").flatMap(TimeInterval.init)
                ?? response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw ListenBrainzError.rateLimited(retryAfter: retry)
        default: throw ListenBrainzError.http(status: response.statusCode)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw ListenBrainzError.malformed(String(describing: error)) }
    }

    /// `https://listenbrainz.org/playlist/<mbid>` or `https://musicbrainz.org/recording/<mbid>` → `<mbid>`.
    static func mbid(fromURL string: String) -> String? {
        let last = string.split(separator: "/").last.map(String.init) ?? string
        return UUID(uuidString: last) != nil ? last.lowercased() : nil
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: JSPF wire types

struct PlaylistsEnvelope: Decodable {
    struct Wrapper: Decodable { let playlist: JSPFPlaylist }
    let playlists: [Wrapper]
}

struct PlaylistEnvelope: Decodable { let playlist: JSPFPlaylist }

struct JSPFPlaylist: Decodable {
    struct Extension: Decodable {
        struct PlaylistExt: Decodable {
            struct Additional: Decodable {
                struct Algorithm: Decodable { let source_patch: String? }
                let algorithm_metadata: Algorithm?
            }
            let additional_metadata: Additional?
        }
        let playlist: PlaylistExt?
        enum CodingKeys: String, CodingKey { case playlist = "https://musicbrainz.org/doc/jspf#playlist" }
    }
    let title: String?
    let identifier: String?
    let date: String?
    let `extension`: Extension?
    let track: [JSPFTrack]?
}

struct JSPFTrack: Decodable {
    struct Extension: Decodable {
        struct TrackExt: Decodable {
            struct Additional: Decodable {
                struct Artist: Decodable { let artist_mbid: String? }
                let artists: [Artist]?
            }
            let additional_metadata: Additional?
        }
        let track: TrackExt?
        enum CodingKeys: String, CodingKey { case track = "https://musicbrainz.org/doc/jspf#track" }
    }
    let title: String?
    let creator: String?
    let album: String?
    /// LB has sent both a single string and an array here over time.
    let identifier: StringOrArray?
    let `extension`: Extension?
}

struct StringOrArray: Decodable {
    let values: [String]
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { values = [s] }
        else { values = try c.decode([String].self) }
    }
}

extension String {
    var pathEscaped: String { addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? self }
}
