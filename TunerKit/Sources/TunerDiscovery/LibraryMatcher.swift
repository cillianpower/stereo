import Foundation
import TunerModel
import TunerStore

/// Maps ListenBrainz recordings to tracks in the local library: recording MBID first,
/// then normalised artist + title.
public struct LibraryMatcher: Sendable {
    let store: LibraryStore

    public init(store: LibraryStore) { self.store = store }

    public func match(_ recordings: [LBRecording]) -> [Track] {
        let byMBID = (try? store.tracks(musicBrainzIDs: recordings.compactMap(\.mbid))) ?? [:]
        var seen = Set<ItemID>()
        var out: [Track] = []
        for rec in recordings {
            let hit = rec.mbid.flatMap { byMBID[$0.lowercased()] } ?? fuzzyMatch(rec)
            if let hit, seen.insert(hit.id).inserted { out.append(hit) }
        }
        return out
    }

    public func match(_ recording: LBRecording) -> Track? { match([recording]).first }

    func fuzzyMatch(_ rec: LBRecording) -> Track? {
        let title = TextNormalizer.title(rec.title)
        guard !title.isEmpty else { return nil }
        let artist = rec.artist.map(TextNormalizer.artist)
        // Search on the cleaned title; drop "and" since the local title may spell it "&".
        let searchText = title.split(separator: " ").filter { $0 != "and" }.joined(separator: " ")
        let candidates = (try? store.trackCandidates(title: searchText.isEmpty ? title : searchText)) ?? []
        return candidates.first { track in
            guard TextNormalizer.title(track.title) == title else { return false }
            guard let artist, !artist.isEmpty else { return true }
            let local = TextNormalizer.artist(track.artist ?? "")
            return local == artist || local.contains(artist) || artist.contains(local) && !local.isEmpty
        }
    }
}

/// Case-, diacritic- and decoration-insensitive keys for comparing titles and artists across sources.
public enum TextNormalizer {
    public static func title(_ s: String) -> String {
        var t = s
        // "(Remastered 2011)", "[Explicit]", "(feat. X)", "- 2011 Remaster", "- Radio Edit"
        t = t.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+-\s+.*(remaster|edit|version|mix|live|mono|stereo).*$"#, with: "",
                                   options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\s+(feat\.?|ft\.?|featuring)\s+.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return key(t)
    }

    public static func artist(_ s: String) -> String {
        var a = s.replacingOccurrences(of: #"\s+(feat\.?|ft\.?|featuring|with|x)\s+.*$"#, with: "",
                                       options: [.regularExpression, .caseInsensitive])
        a = a.replacingOccurrences(of: #"^the\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
        return key(a)
    }

    static func key(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "æ", with: "ae")
            .replacingOccurrences(of: "ø", with: "o")
            .replacingOccurrences(of: "ß", with: "ss")
        let kept = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }
}
