import Foundation

/// Identifies a configured source (e.g. one Navidrome server, or Radio Browser).
public struct SourceID: Hashable, Codable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let radioBrowser = SourceID("radio-browser")
    public static let customStations = SourceID("custom-stations")
}

/// A source-namespaced identifier. Raw IDs are only unique within their source.
public struct ItemID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let source: SourceID
    public let raw: String

    public init(source: SourceID, raw: String) {
        self.source = source
        self.raw = raw
    }

    public var description: String { "\(source.rawValue):\(raw)" }

    /// Parses the `source:raw` form produced by `description`.
    public init?(string: String) {
        guard let idx = string.firstIndex(of: ":") else { return nil }
        let source = String(string[..<idx])
        let raw = String(string[string.index(after: idx)...])
        guard !source.isEmpty, !raw.isEmpty else { return nil }
        self.init(source: SourceID(source), raw: raw)
    }
}
