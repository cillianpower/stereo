import Foundation

public struct Station: Identifiable, Hashable, Codable, Sendable {
    public enum Origin: Hashable, Codable, Sendable {
        case radioBrowser(uuid: String)
        case custom(UUID)
    }

    public var origin: Origin
    public var name: String
    public var streamURL: URL
    public var homepage: URL?
    public var faviconURL: URL?
    public var codec: String?
    public var bitRate: Int?
    public var tags: [String]
    public var countryCode: String?
    public var language: String?
    public var isHLS: Bool
    public var votes: Int?

    public var id: String {
        switch origin {
        case .radioBrowser(let uuid): "rb:\(uuid)"
        case .custom(let uuid): "custom:\(uuid.uuidString)"
        }
    }

    public init(
        origin: Origin, name: String, streamURL: URL, homepage: URL? = nil, faviconURL: URL? = nil,
        codec: String? = nil, bitRate: Int? = nil, tags: [String] = [], countryCode: String? = nil,
        language: String? = nil, isHLS: Bool = false, votes: Int? = nil
    ) {
        self.origin = origin; self.name = name; self.streamURL = streamURL; self.homepage = homepage
        self.faviconURL = faviconURL; self.codec = codec; self.bitRate = bitRate; self.tags = tags
        self.countryCode = countryCode; self.language = language; self.isHLS = isHLS; self.votes = votes
    }
}

/// A station's stream after unwrapping playlists and probing headers.
public struct ResolvedStream: Hashable, Sendable {
    public var url: URL
    public var isHLS: Bool
    public var contentType: String?
    public var bitRate: Int?
    public var name: String?

    public init(url: URL, isHLS: Bool, contentType: String? = nil, bitRate: Int? = nil, name: String? = nil) {
        self.url = url; self.isHLS = isHLS; self.contentType = contentType; self.bitRate = bitRate; self.name = name
    }
}

/// What a station is currently playing, parsed from ICY metadata.
public struct StreamTitle: Hashable, Sendable {
    public var raw: String
    public var artist: String?
    public var title: String?

    public init(raw: String) {
        self.raw = raw
        let parts = raw.components(separatedBy: " - ")
        if parts.count >= 2 {
            artist = parts[0].trimmingCharacters(in: .whitespaces)
            title = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
        } else {
            artist = nil
            title = raw.trimmingCharacters(in: .whitespaces)
        }
        if artist?.isEmpty == true { artist = nil }
        if title?.isEmpty == true { title = nil }
    }
}
