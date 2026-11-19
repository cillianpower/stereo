import Foundation

public enum PlayableItem: Hashable, Sendable {
    case track(Track)
    case station(Station)

    public var title: String {
        switch self {
        case .track(let t): t.title
        case .station(let s): s.name
        }
    }
}

public enum RepeatMode: String, Codable, Sendable { case off, all, one }

/// Where the current context came from, e.g. "Playing from <album>".
public enum QueueContext: Hashable, Codable, Sendable {
    case album(ItemID, name: String)
    case playlist(ItemID, name: String)
    case artist(ItemID, name: String)
    case songs
    case search
    case radio(seed: ItemID)
}

/// An Apple Music–style queue: a context list (optionally shuffled) plus a separate "Up Next" list.
///
/// `Up Next` items play before the rest of the context and are consumed as they play.
public struct PlayQueue: Hashable, Sendable {
    public private(set) var context: [Track] = []
    public private(set) var contextSource: QueueContext?
    /// Playback order as indices into `context`; identity when not shuffled.
    public private(set) var order: [Int] = []
    /// Position in `order` of the current context track.
    public private(set) var orderPosition: Int = 0
    public private(set) var upNext: [Track] = []
    /// The track that came from Up Next and is playing now, if any.
    public private(set) var playingFromUpNext: Track?
    public private(set) var isShuffled = false
    public var repeatMode: RepeatMode = .off

    public init() {}

    public init(tracks: [Track], startAt index: Int = 0, source: QueueContext? = nil, shuffled: Bool = false) {
        replace(with: tracks, startAt: index, source: source, shuffled: shuffled)
    }

    public var current: Track? {
        if let playingFromUpNext { return playingFromUpNext }
        guard order.indices.contains(orderPosition) else { return nil }
        return context[order[orderPosition]]
    }

    public var isEmpty: Bool { current == nil }

    /// Context tracks after the current one, in play order.
    public var remainingContext: [Track] {
        let start = playingFromUpNext == nil ? orderPosition + 1 : orderPosition
        guard start < order.count else { return [] }
        return order[start...].map { context[$0] }
    }

    public mutating func replace(with tracks: [Track], startAt index: Int = 0, source: QueueContext? = nil, shuffled: Bool = false) {
        context = tracks
        contextSource = source
        playingFromUpNext = nil
        let start = tracks.indices.contains(index) ? index : 0
        if shuffled {
            isShuffled = true
            var rest = Array(tracks.indices).filter { $0 != start }
            rest.shuffle()
            order = tracks.isEmpty ? [] : [start] + rest
            orderPosition = 0
        } else {
            isShuffled = false
            order = Array(tracks.indices)
            orderPosition = start
        }
    }

    public mutating func playNext(_ tracks: [Track]) { upNext.insert(contentsOf: tracks, at: 0) }
    public mutating func addToQueue(_ tracks: [Track]) { upNext.append(contentsOf: tracks) }

    public mutating func removeFromUpNext(at offsets: IndexSet) {
        for i in offsets.sorted(by: >) where upNext.indices.contains(i) { upNext.remove(at: i) }
    }

    public mutating func moveUpNext(from source: IndexSet, to destination: Int) {
        let moving = source.sorted().map { upNext[$0] }
        var remaining = upNext.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let adjusted = destination - source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: min(max(adjusted, 0), remaining.count))
        upNext = remaining
    }

    /// The track that would play after the current one, without advancing. Used for gapless pre-scheduling.
    public var peekNext: Track? {
        if repeatMode == .one { return current }
        if let first = upNext.first { return first }
        let nextPos = playingFromUpNext == nil ? orderPosition + 1 : orderPosition
        if nextPos < order.count { return context[order[nextPos]] }
        if repeatMode == .all, let first = order.first { return context[first] }
        return nil
    }

    /// Advances to the next track. Returns the new current track, or nil at the end of the queue.
    /// `userInitiated` skips ignore repeat-one.
    @discardableResult
    public mutating func advance(userInitiated: Bool = false) -> Track? {
        if repeatMode == .one, !userInitiated, current != nil { return current }
        if !upNext.isEmpty {
            if playingFromUpNext == nil { orderPosition += 1 }
            playingFromUpNext = upNext.removeFirst()
            return playingFromUpNext
        }
        if playingFromUpNext != nil {
            playingFromUpNext = nil
            if orderPosition < order.count { return current }
        } else {
            orderPosition += 1
        }
        if orderPosition >= order.count {
            if repeatMode == .all, !order.isEmpty {
                orderPosition = 0
                return current
            }
            orderPosition = order.count
            return nil
        }
        return current
    }

    /// Goes back one context track. Up Next history is not kept, as in Apple Music.
    @discardableResult
    public mutating func previous() -> Track? {
        if playingFromUpNext != nil {
            playingFromUpNext = nil
            orderPosition = max(orderPosition - 1, 0)
            return current
        }
        if orderPosition > 0 { orderPosition -= 1 }
        else if repeatMode == .all, !order.isEmpty { orderPosition = order.count - 1 }
        return current
    }

    /// Jump to a track in the remaining context list.
    public mutating func jump(toContextTrack id: ItemID) {
        guard let pos = order.firstIndex(where: { context[$0].id == id }) else { return }
        playingFromUpNext = nil
        orderPosition = pos
    }

    /// Toggles shuffle, keeping already-played tracks and the current (or next, while
    /// playing from Up Next) context track in place.
    public mutating func setShuffle(_ on: Bool) {
        guard on != isShuffled else { return }
        isShuffled = on
        guard order.indices.contains(orderPosition) else {
            // Past the end: just reorder for the next pass.
            order = on ? context.indices.shuffled() : Array(context.indices)
            return
        }
        let anchor = order[orderPosition]
        if on {
            let played = Array(order[..<orderPosition])
            let playedSet = Set(played)
            let rest = context.indices.filter { $0 != anchor && !playedSet.contains($0) }.shuffled()
            order = played + [anchor] + rest
        } else {
            order = Array(context.indices)
            orderPosition = anchor
        }
    }
}
