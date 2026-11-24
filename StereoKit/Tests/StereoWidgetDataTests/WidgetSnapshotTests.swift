import CoreGraphics
import Foundation
import Testing
@testable import StereoWidgetData

@Suite struct WidgetSnapshotTests {
    private func store() -> WidgetSnapshotStore {
        WidgetSnapshotStore(directory: FileManager.default.temporaryDirectory.appending(path: "widgets-\(UUID().uuidString)"))
    }

    private func image(side: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return try #require(context.makeImage())
    }

    private func nowPlaying(elapsed: TimeInterval = 30, at date: Date = Date(timeIntervalSince1970: 1_000_000),
                            playing: Bool = true) -> WidgetSnapshot.NowPlaying {
        .init(kind: .track, title: "Song", subtitle: "Artist", artwork: nil, isPlaying: playing,
              elapsed: elapsed, duration: 200, capturedAt: date)
    }

    @Test func missingSnapshotReadsAsEmpty() {
        #expect(store().read() == .empty)
    }

    @Test func roundTripsAndRemovesUnreferencedArtwork() throws {
        let store = store()
        let old = WidgetSnapshotStore.artworkName(for: "cover:old", size: 300)
        let kept = WidgetSnapshotStore.artworkName(for: "cover:kept", size: 300)
        #expect(store.saveArtwork(try image(side: 50), named: old, maxPixel: 300))
        #expect(store.saveArtwork(try image(side: 50), named: kept, maxPixel: 300))

        let snapshot = WidgetSnapshot(
            nowPlaying: nowPlaying(),
            recentAlbums: [.init(id: "al-1", title: "Album", subtitle: "Artist", artwork: kept)],
            stations: [.init(id: "st-1", title: "Station", subtitle: nil, artwork: nil)])
        try store.write(snapshot)

        #expect(store.read() == snapshot)
        #expect(store.hasArtwork(kept))
        #expect(!store.hasArtwork(old))
    }

    @Test func artworkIsDownscaledForWidgets() throws {
        let store = store()
        let name = WidgetSnapshotStore.artworkName(for: "cover:big", size: 1200)
        #expect(store.saveArtwork(try image(side: 1200), named: name, maxPixel: 300))
        let loaded = try #require(store.loadArtwork(name, maxPixel: 1200))
        #expect(max(loaded.width, loaded.height) == 300)
    }

    @Test func positionDriftDoesNotCountAsAChange() {
        let base = nowPlaying()
        // Ten seconds later, ten seconds further in: same start time.
        let later = nowPlaying(elapsed: 40, at: base.capturedAt.addingTimeInterval(10))
        #expect(base.isSameDisplay(as: later))

        // A seek moves the implied start time.
        let seeked = nowPlaying(elapsed: 120, at: base.capturedAt.addingTimeInterval(10))
        #expect(!base.isSameDisplay(as: seeked))

        var paused = base
        paused.isPlaying = false
        #expect(!base.isSameDisplay(as: paused))
    }

    @Test func progressIntervalOnlyWhilePlaying() throws {
        let interval = try #require(nowPlaying().progressInterval)
        #expect(interval.lowerBound == Date(timeIntervalSince1970: 1_000_000 - 30))
        #expect(interval.upperBound.timeIntervalSince(interval.lowerBound) == 200)
        #expect(nowPlaying(playing: false).progressInterval == nil)
    }
}
