import AppIntents
import CoreSpotlight
import Foundation
import Observation
import os
import StereoModel
import StereoStore
import StereoUI

/// Keeps Spotlight in step with the local library: updates only what changed after a sync, and
/// removes everything on sign-out so a disconnected library doesn't stay in system search.
@MainActor
final class SpotlightIndexer {
    private let app: AppModel
    private let log = Logger(subsystem: "app.stereo", category: "spotlight")
    private let manifestURL = URL.cachesDirectory.appending(path: "Stereo/spotlight-manifest.json")
    private var manifest: [String: [String: String]] = [:]
    private var work: Task<Void, Never>?
    private static let batchSize = 500

    init(app: AppModel) {
        self.app = app
        if let data = try? Data(contentsOf: manifestURL),
           let saved = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            manifest = saved
        }
    }

    func start() {
        observeSession()
        Task { [weak self, store = app.store] in
            for await _ in store.observeFavoriteStations() { self?.scheduleRefresh() }
        }
        Task { [weak self, store = app.store] in
            for await _ in store.observeRecentStations() { self?.scheduleRefresh() }
        }
    }

    private func observeSession() {
        withObservationTracking {
            _ = app.phase
            _ = app.librarySyncCount
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                switch self.app.phase {
                case .ready: self.scheduleRefresh()
                case .signedOut: self.scheduleClear()
                case .launching: break
                }
                self.observeSession()
            }
        }
    }

    // MARK: Work (one job at a time; a newer job cancels the one before it)

    private func enqueue(_ job: @escaping @MainActor () async -> Void) {
        let previous = work
        previous?.cancel()
        work = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await job()
        }
    }

    private func scheduleRefresh() {
        guard app.phase == .ready, CSSearchableIndex.isIndexingAvailable() else { return }
        enqueue { [weak self] in
            // Let bursts of database changes settle before reading them.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func scheduleClear() {
        // Always enqueue: this cancels a first index that hasn't saved anything to the manifest yet.
        enqueue { [weak self] in
            guard let self, !self.manifest.isEmpty else { return }
            await self.clear()
        }
    }

    private func refresh() async {
        let store = app.store
        let snapshot = await Task.detached(priority: .utility) { try? LibrarySnapshot(store: store) }.value
        guard let snapshot, !Task.isCancelled else { return }
        do {
            try await reconcile(snapshot.albums, kind: "album") { "\($0.name)\u{1F}\($0.artist ?? "")" }
            try await reconcile(snapshot.artists, kind: "artist") { $0.name }
            try await reconcile(snapshot.playlists, kind: "playlist") { $0.name }
            try await reconcile(snapshot.stations, kind: "station") {
                "\($0.name)\u{1F}\($0.station.tags.joined(separator: ","))"
            }
        } catch is CancellationError {
            // A newer job takes over from the saved manifest.
        } catch {
            log.error("indexing failed: \(error.localizedDescription)")
        }
    }

    private func reconcile<Entity: IndexedEntity>(
        _ entities: [Entity], kind: String, signature: (Entity) -> String
    ) async throws where Entity.ID == String {
        let new = Dictionary(entities.map { ($0.id, signature($0)) }, uniquingKeysWith: { first, _ in first })
        var applied = manifest[kind] ?? [:]
        let diff = SearchIndexDiff(old: applied, new: new)
        guard !diff.upserted.isEmpty || !diff.removed.isEmpty else { return }

        if !diff.removed.isEmpty {
            try await CSSearchableIndex.default().deleteAppEntities(identifiedBy: Array(diff.removed), ofType: Entity.self)
            for id in diff.removed { applied[id] = nil }
            commit(applied, kind: kind)
        }
        let changed = entities.filter { diff.upserted.contains($0.id) }
        for start in stride(from: 0, to: changed.count, by: Self.batchSize) {
            try Task.checkCancellation()
            let batch = Array(changed[start..<min(start + Self.batchSize, changed.count)])
            try await CSSearchableIndex.default().indexAppEntities(batch)
            for entity in batch { applied[entity.id] = new[entity.id] }
            commit(applied, kind: kind)
        }
    }

    private func clear() async {
        do {
            try await CSSearchableIndex.default().deleteAppEntities(ofType: AlbumEntity.self)
            try await CSSearchableIndex.default().deleteAppEntities(ofType: ArtistEntity.self)
            try await CSSearchableIndex.default().deleteAppEntities(ofType: PlaylistEntity.self)
            try await CSSearchableIndex.default().deleteAppEntities(ofType: StationEntity.self)
            manifest = [:]
            try? FileManager.default.removeItem(at: manifestURL)
        } catch {
            log.error("clearing the index failed: \(error.localizedDescription)")
        }
    }

    private func commit(_ entries: [String: String], kind: String) {
        manifest[kind] = entries
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: manifestURL, options: .atomic)
    }
}

private struct LibrarySnapshot: Sendable {
    let albums: [AlbumEntity]
    let artists: [ArtistEntity]
    let playlists: [PlaylistEntity]
    let stations: [StationEntity]

    init(store: LibraryStore) throws {
        albums = try store.albums().map(AlbumEntity.init)
        artists = try store.artists().map(ArtistEntity.init)
        playlists = try store.playlists().map(PlaylistEntity.init)
        stations = try store.savedStations().map(StationEntity.init)
    }
}
