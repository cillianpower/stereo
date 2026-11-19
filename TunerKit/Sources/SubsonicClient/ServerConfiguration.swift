import Foundation
import TunerModel

/// One Navidrome/OpenSubsonic server, reachable at one or more URLs (e.g. LAN first, then remote).
public struct ServerConfiguration: Hashable, Codable, Sendable {
    public enum Credential: Hashable, Codable, Sendable {
        case password(String)
        case apiKey(String)
    }

    public var id: SourceID
    public var name: String
    /// Tried in order; the first that answers `ping` wins.
    public var urls: [URL]
    public var username: String
    public var credential: Credential

    public init(id: SourceID = SourceID("navidrome"), name: String, urls: [URL], username: String, credential: Credential) {
        self.id = id
        self.name = name
        self.urls = urls
        self.username = username
        self.credential = credential
    }
}

public enum SubsonicError: Error, Equatable, Sendable, LocalizedError {
    case noReachableEndpoint
    case http(status: Int)
    case server(code: Int, message: String)
    case malformedResponse(String)
    case invalidID(String)

    public var errorDescription: String? {
        switch self {
        case .noReachableEndpoint: "The server couldn't be reached at any configured address."
        case .http(let status): "The server returned HTTP \(status)."
        case .server(let code, let message): Self.describe(code: code, message: message)
        case .malformedResponse(let detail): "Unexpected response from server: \(detail)"
        case .invalidID(let id): "Invalid item ID \(id)."
        }
    }

    private static func describe(code: Int, message: String) -> String {
        switch code {
        case 40: "Wrong username or password."
        case 41: "This server doesn't support token authentication."
        case 44: "Invalid API key."
        case 50: "Not authorized for this action."
        case 70: "Not found."
        default: message.isEmpty ? "Server error \(code)." : message
        }
    }

    public var isAuthenticationFailure: Bool {
        if case .server(let code, _) = self { return [40, 41, 42, 43, 44].contains(code) }
        return false
    }
}
