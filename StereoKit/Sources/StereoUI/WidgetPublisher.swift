import CoreGraphics
import Foundation
import Observation
import os
import StereoModel
import StereoPlayback
import StereoRadio
import StereoStore
import StereoWidgetData
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Keeps the widget snapshot in the App Group current and reloads only the widgets whose content
/// changed. WidgetKit doesn't budget reloads while the app is in the foreground or playing audio,
/// which covers every Now Playing change.
@MainActor
final class WidgetPublisher {
    private static let tileLimit = 12
    private static let nowPlayingPixels = 600, nowPlayingMax = 400
    private static let tilePixels = 300, tileMax = 240

    private unowned let app: AppModel
    private let store: WidgetSnapshotStore
    private let log = Logger(subsystem: "app.stereo", category: "widgets")
    private var written: WidgetSnapshot
    private var recentAlbums: [Album] = []
    private var favoriteStations: [Station] = []
    private var flushTask: Task<Void, Never>?
    private var isDirty = false
    private var observers: [Task<Void, Never>] = []

    init(app: AppModel, store: WidgetSnapshotStore) {
        self.app = app
        self.store = store
        written = store.read()
    }

    func start() {
        observePlayer()
        observers.append(Task { [weak self, store = app.store] in
            for await albums in store.observeAlbums(sortedBy: .recentlyPlayed, limit: Self.tileLimit) {
                self?.recentAlbums = albums
                self?.setNeedsFlush()
            }
        })
        observers.append(Task { [weak self, store = app.store] in
            for await stations in store.observeFavoriteStations() {
                self?.favoriteStations = Array(stations.prefix(Self.tileLimit))
                self?.setNeedsFlush()
            }
        })
    }

    private func observePlayer() {
        withObservationTracking {
            _ = app.player.nowPlaying
            _ = app.player.status
            _ = app.player.streamTitle
            _ = app.radioEnrichment
            _ = app.player.position
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.needsFlushForPlayerChange() { self.setNeedsFlush() }
                self.observePlayer()
            }
        }
    }

    private var lastPlayerKey: PlayerKey?
    private var lastPosition: (seconds: TimeInterval, at: Date) = (0, .distantPast)

    private struct PlayerKey: Equatable {
        var item: PlayableItem?
        var status: PlayerController.Status
        var title: StreamTitle?
        var enrichment: EnrichedTitle?
    }

    /// Position ticks several times a second, but the widget extrapolates it, so only a jump
    /// (a seek) or a real state change is worth a write.
    private func needsFlushForPlayerChange() -> Bool {
        let player = app.player
        let key = PlayerKey(item: player.nowPlaying, status: player.status, title: player.streamTitle,
                            enrichment: app.radioEnrichment)
        let now = Date.now
        let expected = lastPosition.seconds + (player.isPlaying ? now.timeIntervalSince(lastPosition.at) : 0)
        let jumped = abs(player.position - expected) > 2
        lastPosition = (player.position, now)
        defer { lastPlayerKey = key }
        return key != lastPlayerKey || jumped
    }

    /// Coalesces bursts (a track change touches item, status and title at once) into one write.
    private func setNeedsFlush() {
        isDirty = true
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            while let self, self.isDirty {
                self.isDirty = false
                await self.flush()
            }
            self?.flushTask = nil
        }
    }

    private func flush() async {
        let snapshot = WidgetSnapshot(
            nowPlaying: await nowPlaying(),
            recentAlbums: await tiles(recentAlbums.map { album in
                (album.id.description, album.name, album.artist, .coverArt(album.coverArtID))
            }),
            stations: await tiles(favoriteStations.map { station in
                (station.id, station.name, station.tags.first?.capitalized, .station(station))
            }))

        var changed: [String] = []
        if !Self.sameNowPlaying(written.nowPlaying, snapshot.nowPlaying) { changed.append(WidgetKind.nowPlaying) }
        if written.recentAlbums != snapshot.recentAlbums { changed.append(WidgetKind.recentAlbums) }
        if written.stations != snapshot.stations { changed.append(WidgetKind.stations) }
        guard !changed.isEmpty else { return }

        do {
            try store.write(snapshot)
            written = snapshot
        } catch {
            log.error("widget snapshot write failed: \(error.localizedDescription)")
            return
        }
        #if canImport(WidgetKit)
        for kind in changed { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
        #endif
    }

    private static func sameNowPlaying(_ a: WidgetSnapshot.NowPlaying?, _ b: WidgetSnapshot.NowPlaying?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): a.isSameDisplay(as: b)
        default: false
        }
    }

    private func nowPlaying() async -> WidgetSnapshot.NowPlaying? {
        let player = app.player
        guard let item = player.nowPlaying else { return nil }
        let title: String, subtitle: String?, source: ArtworkView.Source
        switch item {
        case .track(let track):
            title = track.title
            subtitle = track.artist
            source = .coverArt(track.coverArtID)
        case .station(let station):
            let enriched = app.radioEnrichment
            title = enriched?.title ?? player.streamTitle?.title ?? station.name
            subtitle = enriched?.artist ?? player.streamTitle?.artist ?? station.name
            if let url = enriched?.artworkURL {
                source = .url(url, key: "enriched:\(url.absoluteString)")
            } else {
                source = .station(station)
            }
        }
        let kind: WidgetSnapshot.NowPlaying.Kind = if case .track = item { .track } else { .station }
        let isPlaying = player.isPlaying, elapsed = player.position, duration = player.duration
        let artwork = await saveArtwork(source, pixels: Self.nowPlayingPixels, maxPixel: Self.nowPlayingMax)
        return .init(kind: kind, title: title, subtitle: subtitle, artwork: artwork, isPlaying: isPlaying,
                     elapsed: elapsed, duration: kind == .track ? duration : nil, capturedAt: .now)
    }

    private func tiles(_ items: [(id: String, title: String, subtitle: String?, source: ArtworkView.Source)]) async -> [WidgetSnapshot.Tile] {
        var result: [WidgetSnapshot.Tile] = []
        for item in items {
            let artwork = await saveArtwork(item.source, pixels: Self.tilePixels, maxPixel: Self.tileMax)
            result.append(.init(id: item.id, title: item.title, subtitle: item.subtitle, artwork: artwork))
        }
        return result
    }

    /// Returns the file name once the art is in the App Group. Art that can't load yet (offline)
    /// comes back nil and is retried on the next flush.
    private func saveArtwork(_ source: ArtworkView.Source, pixels: Int, maxPixel: Int) async -> String? {
        guard let key = source.cacheKey else { return nil }
        let name = WidgetSnapshotStore.artworkName(for: key, size: maxPixel)
        if store.hasArtwork(name) { return name }
        guard let image = await app.artworkImage(for: source, pixels: pixels) else { return nil }
        let store = store
        let saved = await Task.detached(priority: .utility) {
            store.saveArtwork(image, named: name, maxPixel: maxPixel)
        }.value
        return saved ? name : nil
    }
}
