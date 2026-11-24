import Foundation
import StereoModel

public enum RadioBrowserError: Error, Equatable, Sendable {
    case noServers
    case http(status: Int)
}

/// Client for the free Radio Browser API (https://api.radio-browser.info).
///
/// Picks a mirror via DNS (`all.api.radio-browser.info`), remembers it for 24 hours,
/// and rotates to another mirror if one fails.
public actor RadioBrowserClient: StationSource {
    public static let poolHost = "all.api.radio-browser.info"

    private let transport: HTTPTransport
    private let userAgent: String
    private let discoverHosts: @Sendable () async -> [String]
    private var hosts: [String] = []
    private var hostsResolvedAt: Date?
    private var cache: [URL: (Date, Data)] = [:]
    private let cacheLifetime: TimeInterval = 3600

    public init(
        transport: HTTPTransport = URLSession.shared,
        userAgent: String = "Stereo/0.1",
        discoverHosts: (@Sendable () async -> [String])? = nil
    ) {
        self.transport = transport
        self.userAgent = userAgent
        self.discoverHosts = discoverHosts ?? { await RadioBrowserDNS.mirrorHosts(pool: RadioBrowserClient.poolHost) }
    }

    // MARK: Public API

    public func search(_ query: StationQuery) async throws -> [Station] {
        var items: [URLQueryItem] = [
            .init(name: "hidebroken", value: "true"),
            .init(name: "limit", value: String(query.limit)),
        ]
        if let name = query.name, !name.isEmpty { items.append(.init(name: "name", value: name)) }
        if !query.tags.isEmpty { items.append(.init(name: "tagList", value: query.tags.joined(separator: ","))) }
        if let cc = query.countryCode { items.append(.init(name: "countrycode", value: cc)) }
        if let lang = query.language { items.append(.init(name: "language", value: lang)) }
        if let codec = query.codec { items.append(.init(name: "codec", value: codec)) }
        if let min = query.bitrateMin { items.append(.init(name: "bitrateMin", value: String(min))) }
        if let max = query.bitrateMax { items.append(.init(name: "bitrateMax", value: String(max))) }
        if let order = query.order { items.append(.init(name: "order", value: order.rawValue)) }
        if query.reverse { items.append(.init(name: "reverse", value: "true")) }
        return try await stations(path: "json/stations/search", query: items)
    }

    public func topClicked(limit: Int = 50) async throws -> [Station] {
        try await stations(path: "json/stations/topclick/\(limit)", query: [.init(name: "hidebroken", value: "true")])
    }

    public func topVoted(limit: Int = 50) async throws -> [Station] {
        try await stations(path: "json/stations/topvote/\(limit)", query: [.init(name: "hidebroken", value: "true")])
    }

    public func stations(uuids: [String]) async throws -> [Station] {
        guard !uuids.isEmpty else { return [] }
        return try await stations(path: "json/stations/byuuid", query: [.init(name: "uuids", value: uuids.joined(separator: ","))], cached: false)
    }

    public func tags(limit: Int = 100) async throws -> [Facet] {
        let data = try await get(path: "json/tags", query: [
            .init(name: "order", value: "stationcount"), .init(name: "reverse", value: "true"),
            .init(name: "hidebroken", value: "true"), .init(name: "limit", value: String(limit)),
        ])
        return try JSONDecoder().decode([FacetDTO].self, from: data).map { Facet(name: $0.name, code: nil, stationCount: $0.stationcount) }
    }

    public func countries() async throws -> [Facet] {
        let data = try await get(path: "json/countries", query: [
            .init(name: "order", value: "stationcount"), .init(name: "reverse", value: "true"),
            .init(name: "hidebroken", value: "true"),
        ])
        return try JSONDecoder().decode([FacetDTO].self, from: data)
            .map { Facet(name: $0.name, code: $0.iso_3166_1, stationCount: $0.stationcount) }
    }

    /// Registers a play, as the API asks clients to do. Best effort.
    public func recordClick(stationUUID: String) async {
        _ = try? await get(path: "json/url/\(stationUUID)", query: [], cached: false)
    }

    // MARK: Plumbing

    private func stations(path: String, query: [URLQueryItem], cached: Bool = true) async throws -> [Station] {
        let data = try await get(path: path, query: query, cached: cached)
        let dtos = try JSONDecoder().decode([StationDTO].self, from: data)
        return dtos.compactMap(\.station)
    }

    private func currentHosts() async throws -> [String] {
        if let at = hostsResolvedAt, Date().timeIntervalSince(at) < 86_400, !hosts.isEmpty { return hosts }
        var found = await discoverHosts()
        if found.isEmpty { found = [Self.poolHost] }
        hosts = found.shuffled()
        hostsResolvedAt = Date()
        return hosts
    }

    func get(path: String, query: [URLQueryItem], cached: Bool = true) async throws -> Data {
        let hosts = try await currentHosts()
        var lastError: Error = RadioBrowserError.noServers
        for (i, host) in hosts.enumerated() {
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            components.path = "/" + path
            components.queryItems = query.isEmpty ? nil : query
            guard let url = components.url else { continue }

            if cached, let (at, data) = cache[url], Date().timeIntervalSince(at) < cacheLifetime { return data }

            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10
            do {
                let (data, response) = try await transport.data(for: request)
                guard (200..<300).contains(response.statusCode) else { throw RadioBrowserError.http(status: response.statusCode) }
                if i > 0 {
                    // Promote the working mirror so later calls go there first.
                    self.hosts.swapAt(0, i)
                }
                if cached { cache[url] = (Date(), data) }
                return data
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}

public struct Facet: Hashable, Sendable, Identifiable {
    public var name: String
    public var code: String?
    public var stationCount: Int
    public var id: String { code ?? name }
}

struct FacetDTO: Decodable {
    let name: String
    let iso_3166_1: String?
    let stationcount: Int
}

struct StationDTO: Decodable {
    let stationuuid: String
    let name: String
    let url: String
    let url_resolved: String?
    let homepage: String?
    let favicon: String?
    let tags: String?
    let countrycode: String?
    let language: String?
    let codec: String?
    let bitrate: Int?
    let hls: Int?
    let votes: Int?

    var station: Station? {
        let resolved = url_resolved.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        guard let stream = resolved ?? URL(string: url) else { return nil }
        func optionalURL(_ s: String?) -> URL? { s.flatMap { $0.isEmpty ? nil : URL(string: $0) } }
        func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }
        return Station(
            origin: .radioBrowser(uuid: stationuuid),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            streamURL: stream,
            homepage: optionalURL(homepage),
            faviconURL: optionalURL(favicon),
            codec: nonEmpty(codec),
            bitRate: bitrate.flatMap { $0 > 0 ? $0 : nil },
            tags: (tags ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            countryCode: nonEmpty(countrycode),
            language: nonEmpty(language),
            isHLS: hls == 1,
            votes: votes
        )
    }
}
