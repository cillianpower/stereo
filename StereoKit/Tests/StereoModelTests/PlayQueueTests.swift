import Testing
import Foundation
@testable import StereoModel

private let src = SourceID("test")
private func tracks(_ n: Int) -> [Track] {
    (0..<n).map { Track(id: ItemID(source: src, raw: "t\($0)"), title: "Track \($0)") }
}

@Suite struct PlayQueueTests {
    @Test func linearPlayback() {
        var q = PlayQueue(tracks: tracks(3))
        #expect(q.current?.title == "Track 0")
        #expect(q.peekNext?.title == "Track 1")
        #expect(q.advance()?.title == "Track 1")
        #expect(q.advance()?.title == "Track 2")
        #expect(q.advance() == nil)
        #expect(q.current == nil)
    }

    @Test func startAtIndex() {
        let q = PlayQueue(tracks: tracks(5), startAt: 3)
        #expect(q.current?.title == "Track 3")
        #expect(q.remainingContext.map(\.title) == ["Track 4"])
    }

    @Test func upNextPlaysBeforeContextAndIsConsumed() {
        var q = PlayQueue(tracks: tracks(3))
        let extra = Track(id: ItemID(source: src, raw: "x"), title: "Extra")
        q.addToQueue([extra])
        #expect(q.peekNext == extra)
        #expect(q.advance() == extra)
        #expect(q.upNext.isEmpty)
        #expect(q.advance()?.title == "Track 1")
        #expect(q.advance()?.title == "Track 2")
    }

    @Test func playNextGoesToFrontOfUpNext() {
        var q = PlayQueue(tracks: tracks(2))
        let a = Track(id: ItemID(source: src, raw: "a"), title: "A")
        let b = Track(id: ItemID(source: src, raw: "b"), title: "B")
        q.addToQueue([a])
        q.playNext([b])
        #expect(q.upNext == [b, a])
    }

    @Test func repeatAllWraps() {
        var q = PlayQueue(tracks: tracks(2))
        q.repeatMode = .all
        q.advance()
        #expect(q.peekNext?.title == "Track 0")
        #expect(q.advance()?.title == "Track 0")
    }

    @Test func repeatOneRepeatsUnlessUserSkips() {
        var q = PlayQueue(tracks: tracks(2))
        q.repeatMode = .one
        #expect(q.advance()?.title == "Track 0")
        #expect(q.advance(userInitiated: true)?.title == "Track 1")
    }

    @Test func shuffleKeepsCurrentFirstAndContainsAll() {
        let all = tracks(50)
        let q = PlayQueue(tracks: all, startAt: 10, shuffled: true)
        #expect(q.current?.title == "Track 10")
        #expect(Set(q.remainingContext.map(\.id)).count == 49)
    }

    @Test func toggleShuffleMidQueuePreservesCurrent() {
        var q = PlayQueue(tracks: tracks(20), startAt: 5)
        q.setShuffle(true)
        #expect(q.current?.title == "Track 5")
        #expect(q.remainingContext.count == 14)
        q.setShuffle(false)
        #expect(q.current?.title == "Track 5")
        #expect(q.peekNext?.title == "Track 6")
    }

    @Test func previousStepsBack() {
        var q = PlayQueue(tracks: tracks(3), startAt: 2)
        #expect(q.previous()?.title == "Track 1")
        #expect(q.previous()?.title == "Track 0")
        #expect(q.previous()?.title == "Track 0")
    }

    @Test func moveUpNext() {
        var q = PlayQueue(tracks: tracks(1))
        let items = (0..<4).map { Track(id: ItemID(source: src, raw: "u\($0)"), title: "U\($0)") }
        q.addToQueue(items)
        q.moveUpNext(from: [0], to: 3)
        #expect(q.upNext.map(\.title) == ["U1", "U2", "U0", "U3"])
    }
}

@Suite struct ModelTests {
    @Test func itemIDRoundTrip() {
        let id = ItemID(source: SourceID("nav"), raw: "abc:def")
        #expect(ItemID(string: id.description) == id)
    }

    @Test func streamTitleParsing() {
        let t = StreamTitle(raw: "Boards of Canada - Roygbiv - Live")
        #expect(t.artist == "Boards of Canada")
        #expect(t.title == "Roygbiv - Live")
        #expect(StreamTitle(raw: "Station jingle").artist == nil)
    }

    @Test func activeLyricLine() {
        let lyrics = Lyrics(lines: [
            .init(start: .seconds(0), text: "a"),
            .init(start: .seconds(5), text: "b"),
            .init(start: .seconds(10), text: "c"),
        ], isSynced: true)
        #expect(lyrics.activeLineIndex(at: .seconds(7)) == 1)
        #expect(lyrics.activeLineIndex(at: .seconds(11)) == 2)
    }

    @Test func formatBadges() {
        #expect(AudioFormat(codec: "flac", sampleRate: 96_000, bitDepth: 24).isHiRes)
        #expect(!AudioFormat(codec: "flac", sampleRate: 44_100, bitDepth: 16).isHiRes)
        #expect(!AudioFormat(codec: "mp3").isLossless)
    }
}
