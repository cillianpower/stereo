import Foundation

/// Extra album details a server can provide beyond what the library index stores.
public struct AlbumInfo: Hashable, Codable, Sendable {
    public struct ReleaseDate: Hashable, Codable, Sendable {
        public var year: Int?
        public var month: Int?
        public var day: Int?
        public init(year: Int? = nil, month: Int? = nil, day: Int? = nil) {
            self.year = year; self.month = month; self.day = day
        }
    }

    public var notes: String?
    public var lastFmURL: URL?
    public var musicBrainzID: String?
    public var labels: [String]
    public var releaseTypes: [String]
    public var genres: [String]
    public var moods: [String]
    public var released: ReleaseDate?
    public var version: String?
    public var isCompilation: Bool

    public init(notes: String? = nil, lastFmURL: URL? = nil, musicBrainzID: String? = nil, labels: [String] = [],
                releaseTypes: [String] = [], genres: [String] = [], moods: [String] = [],
                released: ReleaseDate? = nil, version: String? = nil, isCompilation: Bool = false) {
        self.notes = notes; self.lastFmURL = lastFmURL; self.musicBrainzID = musicBrainzID; self.labels = labels
        self.releaseTypes = releaseTypes; self.genres = genres; self.moods = moods; self.released = released
        self.version = version; self.isCompilation = isCompilation
    }

    public var musicBrainzURL: URL? {
        musicBrainzID.flatMap { URL(string: "https://musicbrainz.org/release/\($0)") }
    }

    /// Server notes are HTML, usually ending in a "Read more on Last.fm" link. Returns readable text.
    public static func plainText(fromHTML html: String?) -> String? {
        guard var text = html else { return nil }
        text = text.replacingOccurrences(of: "<a\\b[^>]*>\\s*Read more[^<]*</a>\\.?", with: "",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<br\\s*/?>|</p>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"),
                                    ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
