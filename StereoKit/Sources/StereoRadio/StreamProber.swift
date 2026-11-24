import Foundation
import StereoModel

/// Works out what a user-pasted URL really is: a playlist wrapper (.pls/.m3u), an HLS stream,
/// or a direct Icecast/Shoutcast stream, and reads its name and bitrate from ICY headers.
public struct StreamProber: Sendable {
    private let transport: HTTPTransport

    public init(transport: HTTPTransport = URLSession.shared) { self.transport = transport }

    public func probe(_ url: URL, depth: Int = 0) async throws -> ResolvedStream {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-16383", forHTTPHeaderField: "Range")
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        request.timeoutInterval = 10
        let (data, response) = try await transport.data(for: request)
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased()
        let ext = url.pathExtension.lowercased()
        let text = String(data: data.prefix(16_384), encoding: .utf8)

        let looksLikeHLS = ext == "m3u8" || contentType?.contains("mpegurl") == true && text?.contains("#EXT-X-") == true
        if looksLikeHLS || text?.hasPrefix("#EXTM3U") == true && text?.contains("#EXT-X-") == true {
            return ResolvedStream(url: url, isHLS: true, contentType: contentType)
        }

        let isPlaylist = ["pls", "m3u"].contains(ext)
            || contentType.map { $0.contains("scpls") || $0.contains("mpegurl") } == true
        if isPlaylist, let text, depth < 3, let inner = Self.firstEntry(inPlaylist: text, base: url) {
            return try await probe(inner, depth: depth + 1)
        }

        return ResolvedStream(
            url: url,
            isHLS: false,
            contentType: contentType,
            bitRate: response.value(forHTTPHeaderField: "icy-br").flatMap { Int($0.split(separator: ",").first ?? "") },
            name: response.value(forHTTPHeaderField: "icy-name")
        )
    }

    /// First stream URL in a PLS (`File1=`) or M3U (first non-comment line) playlist.
    public static func firstEntry(inPlaylist text: String, base: URL) -> URL? {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(where: { $0.lowercased() == "[playlist]" }) {
            let files = lines.compactMap { line -> (Int, String)? in
                let lower = line.lowercased()
                guard lower.hasPrefix("file"), let eq = line.firstIndex(of: "=") else { return nil }
                let n = Int(line[line.index(line.startIndex, offsetBy: 4)..<eq]) ?? 0
                return (n, String(line[line.index(after: eq)...]))
            }.sorted { $0.0 < $1.0 }
            return files.lazy.compactMap { URL(string: $0.1) }.first
        }
        return lines.lazy
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .compactMap { URL(string: $0, relativeTo: base)?.absoluteURL }
            .first
    }
}
