import Foundation
import StereoModel

/// Parses power-search text like `jazz codec:flac bitrate>=256 country:IE #chill sort:votes`
/// into a `StationQuery`. Unprefixed words become the station-name filter.
public enum StationSearchParser {
    public static func parse(_ text: String, limit: Int = 100) -> StationQuery {
        var query = StationQuery(limit: limit)
        var nameWords: [String] = []

        for token in tokenize(text) {
            let lower = token.lowercased()

            if token.hasPrefix("#"), token.count > 1 {
                query.tags.append(String(token.dropFirst()).lowercased())
                continue
            }
            if let bitrate = parseBitrate(lower) {
                switch bitrate.op {
                case .min: query.bitrateMin = bitrate.value
                case .max: query.bitrateMax = bitrate.value
                }
                continue
            }
            if let colon = token.firstIndex(of: ":") {
                let key = token[..<colon].lowercased()
                let value = String(token[token.index(after: colon)...])
                if !value.isEmpty, apply(key: key, value: value, to: &query) { continue }
            }
            nameWords.append(token)
        }

        if !nameWords.isEmpty { query.name = nameWords.joined(separator: " ") }
        return query
    }

    private static func apply(key: String, value: String, to query: inout StationQuery) -> Bool {
        switch key {
        case "codec", "format":
            query.codec = value.uppercased()
        case "country", "cc":
            guard value.count == 2 else { return false }
            query.countryCode = value.uppercased()
        case "lang", "language":
            query.language = value.lowercased()
        case "tag", "genre":
            query.tags.append(value.lowercased())
        case "sort", "order":
            switch value.lowercased() {
            case "votes", "popular": query.order = .votes; query.reverse = true
            case "clicks", "trending": query.order = .clickcount; query.reverse = true
            case "bitrate", "quality": query.order = .bitrate; query.reverse = true
            case "name": query.order = .name; query.reverse = false
            case "random", "shuffle": query.order = .random
            default: return false
            }
        default:
            return false
        }
        return true
    }

    private enum BitrateOp { case min, max }

    /// `bitrate>=256`, `bitrate>256`, `br<=128`, `bitrate:320`, `kbps>=128`, with an optional `k`/`kbps` suffix.
    private static func parseBitrate(_ token: String) -> (op: BitrateOp, value: Int)? {
        let keys = ["bitrate", "kbps", "br"]
        guard let key = keys.first(where: { token.hasPrefix($0) }) else { return nil }
        var rest = token.dropFirst(key.count)
        let op: BitrateOp
        var exclusive = false
        if rest.hasPrefix(">=") { op = .min; rest = rest.dropFirst(2) }
        else if rest.hasPrefix("<=") { op = .max; rest = rest.dropFirst(2) }
        else if rest.hasPrefix(">") { op = .min; exclusive = true; rest = rest.dropFirst() }
        else if rest.hasPrefix("<") { op = .max; exclusive = true; rest = rest.dropFirst() }
        else if rest.hasPrefix(":") || rest.hasPrefix("=") { op = .min; rest = rest.dropFirst() }
        else { return nil }
        var digits = String(rest)
        for suffix in ["kbps", "kb", "k"] where digits.hasSuffix(suffix) {
            digits.removeLast(suffix.count)
            break
        }
        guard var value = Int(digits) else { return nil }
        if exclusive { value += (op == .min ? 1 : -1) }
        return (op, value)
    }

    /// Splits on whitespace, keeping "quoted phrases" together.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in text {
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch.isWhitespace && !inQuotes {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
