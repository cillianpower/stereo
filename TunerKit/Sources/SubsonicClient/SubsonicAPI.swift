import CryptoKit
import Foundation
import TunerModel

/// Low-level OpenSubsonic request builder and decoder. `SubsonicLibrary` maps its results to domain types.
public struct SubsonicAPI: Sendable {
    public static let apiVersion = "1.16.1"
    public static let clientName = "Tuner"

    let config: ServerConfiguration
    let transport: HTTPTransport
    let saltGenerator: @Sendable () -> String

    public init(
        config: ServerConfiguration,
        transport: HTTPTransport,
        saltGenerator: @escaping @Sendable () -> String = { Self.randomSalt() }
    ) {
        self.config = config
        self.transport = transport
        self.saltGenerator = saltGenerator
    }

    public static func randomSalt() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<12).map { _ in chars.randomElement()! })
    }

    static func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Auth + protocol parameters appended to every request.
    func authQueryItems() -> [URLQueryItem] {
        var items: [URLQueryItem] = [
            .init(name: "v", value: Self.apiVersion),
            .init(name: "c", value: Self.clientName),
            .init(name: "f", value: "json"),
        ]
        switch config.credential {
        case .apiKey(let key):
            items.append(.init(name: "apiKey", value: key))
        case .password(let password):
            let salt = saltGenerator()
            items.append(contentsOf: [
                .init(name: "u", value: config.username),
                .init(name: "t", value: Self.md5Hex(password + salt)),
                .init(name: "s", value: salt),
            ])
        }
        return items
    }

    /// Builds a `rest/<endpoint>` URL. Used directly for `stream` and `getCoverArt`, which aren't JSON.
    public func url(base: URL, endpoint: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: base.appending(path: "rest/\(endpoint)"), resolvingAgainstBaseURL: false)!
        components.queryItems = query + authQueryItems()
        return components.url!
    }

    func request<Body: Decodable>(_ type: Body.Type, base: URL, endpoint: String, query: [URLQueryItem] = [],
                                  timeout: TimeInterval = 20) async throws -> Body {
        var req = URLRequest(url: url(base: base, endpoint: endpoint, query: query))
        req.timeoutInterval = timeout
        let (data, response) = try await transport.data(for: req)
        guard (200..<300).contains(response.statusCode) else {
            throw SubsonicError.http(status: response.statusCode)
        }
        return try Self.decode(type, from: data)
    }

    static func decode<Body: Decodable>(_ type: Body.Type, from data: Data) throws -> Body {
        let decoder = JSONDecoder.subsonic
        let status: ResponseStatus
        do {
            status = try decoder.decode(Envelope<ResponseStatus>.self, from: data).response
        } catch {
            throw SubsonicError.malformedResponse("missing subsonic-response envelope")
        }
        if status.status != "ok" {
            throw SubsonicError.server(code: status.error?.code ?? 0, message: status.error?.message ?? "")
        }
        do {
            return try decoder.decode(Envelope<Body>.self, from: data).response
        } catch {
            throw SubsonicError.malformedResponse(String(describing: error))
        }
    }

    /// Reachability probe: true if a Subsonic server answers at `base`, even if it rejects the credentials.
    /// Auth failures then surface as real errors from the next request instead of "unreachable".
    public func isReachable(base: URL, timeout: TimeInterval = 4) async -> Bool {
        var req = URLRequest(url: url(base: base, endpoint: "ping"))
        req.timeoutInterval = timeout
        guard let (data, response) = try? await transport.data(for: req),
              (200..<300).contains(response.statusCode) else { return false }
        return (try? JSONDecoder.subsonic.decode(Envelope<ResponseStatus>.self, from: data)) != nil
    }

    /// Full check used by sign-in: reachable and credentials accepted.
    public func ping(base: URL, timeout: TimeInterval = 8) async throws {
        _ = try await request(PingBody.self, base: base, endpoint: "ping", timeout: timeout)
    }
}
