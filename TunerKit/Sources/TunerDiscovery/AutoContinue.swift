import Foundation
import TunerModel
import TunerStore

/// Supplies tracks when the queue runs out ("Autoplay"), for `PlayerController.onQueueExhausted`.
///
/// Sources, in order, until there are enough:
/// 1. Navidrome `getSimilarSongs2`, seeded by the last few tracks.
/// 2. ListenBrainz similar artists (needs a recording MBID on a seed) → those artists' local tracks.
/// 3. Offline fallback: more by the seed artists, then the seed genre, from the local index.
///
/// Everything is de-duplicated against the finished queue, a rolling history of recently played
/// tracks, and (by normalised artist + title) against itself, and artists are spread out.
public actor AutoContinue {
    public struct Options: Sendable {
        public var count = 25
        public var seedCount = 3
        public var historyLimit = 300
        /// Never more than this many tracks in a row by one artist.
        public var maxConsecutivePerArtist = 2
        public init() {}
    }

    private let library: LibrarySource
    private let store: LibraryStore
    private let listenBrainz: ListenBrainzClient?
    private let options: Options
    private var history: [ItemID] = []
    private var historySet: Set<ItemID> = []
    private var artistMBIDCache: [String: [String]] = [:]

    public init(library: LibrarySource, store: LibraryStore, listenBrainz: ListenBrainzClient?, options: Options = Options()) {
        self.library = library
        self.store = store
        self.listenBrainz = listenBrainz
        self.options = options
    }

    /// Records tracks as played so later continuations avoid them.
    public func remember(_ tracks: [Track]) {
        for t in tracks where historySet.insert(t.id).inserted { history.append(t.id) }
        if history.count > options.historyLimit {
            let drop = history.count - options.historyLimit
            for id in history.prefix(drop) { historySet.remove(id) }
            history.removeFirst(drop)
        }
    }

    public func nextTracks(after queue: PlayQueue) async -> [Track] {
        let played = queue.context + queue.upNext + [queue.playingFromUpNext].compactMap { $0 }
        remember(played)
        // Seeds = the last tracks actually played (play order, so shuffle is respected), newest first.
        let playOrder = queue.order.compactMap { queue.context.indices.contains($0) ? queue.context[$0] : nil }
        let seeds = Array(playOrder.suffix(options.seedCount).reversed())
        guard !seeds.isEmpty else { return [] }

        var picker = Picker(excluding: historySet, excludingKeys: Set(played.map(Self.dedupKey)), limit: options.count)

        // 1. Server similar songs, interleaved across seeds so the most recent seed leads.
        var perSeed: [[Track]] = []
        for seed in seeds {
            perSeed.append((try? await library.similar(to: seed.id, count: options.count)) ?? [])
        }
        picker.add(Self.interleave(perSeed))

        // 2. ListenBrainz similar artists → local tracks.
        if !picker.isFull, let listenBrainz {
            let artistMBIDs = await seedArtistMBIDs(seeds, client: listenBrainz)
            var lbTracks: [[Track]] = []
            for mbid in artistMBIDs.prefix(2) {
                let similar = (try? await listenBrainz.similarArtists(to: mbid, limit: 15)) ?? []
                for artist in similar.prefix(10) {
                    let local = (try? store.tracks(byArtistName: artist.name, limit: 6)) ?? []
                    if !local.isEmpty { lbTracks.append(local.shuffled()) }
                }
            }
            picker.add(Self.interleave(lbTracks))
        }

        // 3. Offline fallbacks from the local index.
        if !picker.isFull {
            let byArtist = seeds.compactMap(\.artist).uniqued().map { (try? store.tracks(byArtistName: $0, limit: 20)) ?? [] }
            picker.add(Self.interleave(byArtist.map { $0.shuffled() }))
        }
        if !picker.isFull {
            for genre in seeds.compactMap(\.genre).uniqued() {
                picker.add((try? store.tracks(inGenre: genre, limit: 40)) ?? [])
            }
        }

        let result = Self.spreadArtists(picker.picked, maxRun: options.maxConsecutivePerArtist)
        remember(result)
        return result
    }

    /// Artist MBIDs for seed tracks, via their recording MBIDs (Subsonic tracks don't carry artist MBIDs).
    private func seedArtistMBIDs(_ seeds: [Track], client: ListenBrainzClient) async -> [String] {
        var result: [String] = []
        var toLookUp: [String] = []
        for mbid in seeds.compactMap({ $0.musicBrainzID?.lowercased() }) {
            if let cached = artistMBIDCache[mbid] { result += cached } else { toLookUp.append(mbid) }
        }
        if !toLookUp.isEmpty, let recs = try? await client.lookupRecordings(toLookUp) {
            for rec in recs {
                guard let mbid = rec.mbid?.lowercased() else { continue }
                artistMBIDCache[mbid] = rec.artistMBIDs
                result += rec.artistMBIDs
            }
        }
        return result.uniqued()
    }

    // MARK: Helpers

    static func dedupKey(_ t: Track) -> String {
        TextNormalizer.artist(t.artist ?? "") + "|" + TextNormalizer.title(t.title)
    }

    /// Round-robin merge: [a1, b1, c1, a2, b2, …].
    static func interleave(_ lists: [[Track]]) -> [Track] {
        var out: [Track] = []
        let longest = lists.map(\.count).max() ?? 0
        for i in 0..<longest { for list in lists where i < list.count { out.append(list[i]) } }
        return out
    }

    /// Reorders so no artist appears more than `maxRun` times in a row, where possible.
    static func spreadArtists(_ tracks: [Track], maxRun: Int) -> [Track] {
        var pending = tracks
        var out: [Track] = []
        while !pending.isEmpty {
            let lastArtists = out.suffix(maxRun).map { TextNormalizer.artist($0.artist ?? "") }
            let blocked = lastArtists.count == maxRun && Set(lastArtists).count == 1 ? lastArtists.first : nil
            let index = pending.firstIndex { TextNormalizer.artist($0.artist ?? "") != blocked } ?? 0
            out.append(pending.remove(at: index))
        }
        return out
    }

    struct Picker {
        var excluding: Set<ItemID>
        var excludingKeys: Set<String>
        let limit: Int
        var picked: [Track] = []

        init(excluding: Set<ItemID>, excludingKeys: Set<String>, limit: Int) {
            self.excluding = excluding
            self.excludingKeys = excludingKeys
            self.limit = limit
        }

        var isFull: Bool { picked.count >= limit }

        mutating func add(_ tracks: [Track]) {
            for t in tracks where !isFull {
                let key = AutoContinue.dedupKey(t)
                guard !excluding.contains(t.id), !excludingKeys.contains(key) else { continue }
                excluding.insert(t.id)
                excludingKeys.insert(key)
                picked.append(t)
            }
        }
    }
}

extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
