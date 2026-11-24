import Foundation

/// Splits a Shoutcast/Icecast byte stream (requested with `Icy-MetaData: 1`) into audio bytes and
/// metadata blocks. Every `metaInterval` audio bytes the server inserts one length byte (×16) followed
/// by that many bytes of metadata, e.g. `StreamTitle='Artist - Title';StreamUrl='';`, null-padded.
public struct ICYDemuxer: Sendable {
    public struct Output: Sendable, Equatable {
        public var audio: Data
        /// Metadata dictionaries in the order they appeared (empty blocks are skipped).
        public var metadata: [[String: String]]
    }

    private enum State: Sendable {
        case audio(remaining: Int)
        case length
        case metadata(remaining: Int, buffer: Data)
    }

    public let metaInterval: Int
    private var state: State

    public init(metaInterval: Int) {
        precondition(metaInterval > 0)
        self.metaInterval = metaInterval
        self.state = .audio(remaining: metaInterval)
    }

    public mutating func consume(_ chunk: Data) -> Output {
        var audio = Data()
        audio.reserveCapacity(chunk.count)
        var metadata: [[String: String]] = []
        var index = chunk.startIndex

        while index < chunk.endIndex {
            switch state {
            case .audio(let remaining):
                let take = min(remaining, chunk.endIndex - index)
                audio.append(chunk[index..<(index + take)])
                index += take
                state = remaining - take == 0 ? .length : .audio(remaining: remaining - take)

            case .length:
                let length = Int(chunk[index]) * 16
                index += 1
                state = length == 0 ? .audio(remaining: metaInterval) : .metadata(remaining: length, buffer: Data())

            case .metadata(let remaining, var buffer):
                let take = min(remaining, chunk.endIndex - index)
                buffer.append(chunk[index..<(index + take)])
                index += take
                if remaining - take == 0 {
                    let parsed = Self.parse(buffer)
                    if !parsed.isEmpty { metadata.append(parsed) }
                    state = .audio(remaining: metaInterval)
                } else {
                    state = .metadata(remaining: remaining - take, buffer: buffer)
                }
            }
        }
        return Output(audio: audio, metadata: metadata)
    }

    /// Parses `Key='value';Key2='value2';`. Values may contain `'` and `;`, so we split on `';`.
    public static func parse(_ block: Data) -> [String: String] {
        let trimmed = block.prefix { $0 != 0 }
        // Most stations send UTF-8; many legacy ones send Latin-1.
        guard let text = String(data: trimmed, encoding: .utf8) ?? String(data: trimmed, encoding: .isoLatin1) else { return [:] }
        var result: [String: String] = [:]
        var rest = Substring(text)
        while let eq = rest.range(of: "='") {
            let key = rest[..<eq.lowerBound].trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ";")))
            rest = rest[eq.upperBound...]
            let end = rest.range(of: "';") ?? rest.range(of: "'", options: .backwards)
            let value = end.map { String(rest[..<$0.lowerBound]) } ?? String(rest)
            if !key.isEmpty { result[key] = value }
            rest = end.map { rest[$0.upperBound...] } ?? ""
        }
        return result
    }
}
