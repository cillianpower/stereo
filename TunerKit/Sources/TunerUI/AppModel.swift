import Foundation
import Network
import Observation
import os
import RadioBrowserClient
import SubsonicClient
import TunerModel
import TunerPlayback
import TunerRadio
import TunerStore
import TunerSync
import TunerSystem

/// Composition root: builds every service once and exposes app-level actions to the views.
@MainActor
@Observable
public final class AppModel {
    public enum Phase: Equatable { case launching, signedOut, ready }

    public private(set) var phase: Phase = .launching
    public private(set) var server: ServerConfiguration?
    public private(set) var syncProgress: LibrarySyncer.Progress?
    public private(set) var syncError: String?
    public private(set) var isOnExpensiveNetwork = false

    /// Artwork and album for the station's current song, plus the matching track in your library.
    public private(set) var radioEnrichment: EnrichedTitle?
    public private(set) var radioLibraryMatch: Track?

    public let settings: AppSettings
    public let player: PlayerController
    public let store: LibraryStore
    public let radioBrowser: RadioBrowserClient
    public let artwork: ArtworkPipeline

    @ObservationIgnored public private(set) var library: SubsonicLibrary?
    @ObservationIgnored private var syncer: LibrarySyncer?
    @ObservationIgnored private let enricher = NowPlayingEnricher()
    @ObservationIgnored private let prober = StreamProber()
    @ObservationIgnored private let trackCache: TrackCache
    @ObservationIgnored private var bridge: NowPlayingBridge?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private let expensive = OSAllocatedUnfairLock(initialState: false)
    @ObservationIgnored private let log = Logger(subsystem: "app.tuner", category: "app")
    #if os(iOS) || os(tvOS)
    @ObservationIgnored private var audioSession: AudioSessionCoordinator?
    #endif
    // iCloud sync of app-owned state (see AppModel+Sync.swift).
    public internal(set) var cloudSyncStatus: SyncStatus = .notStarted
    @ObservationIgnored var cloudSync: AppStateSync?
    @ObservationIgnored var settingsMirror: SettingsMirror?

    private static let serverDefaultsKey = "server.v1"

    public init() {
        let support = URL.applicationSupportDirectory.appending(path: "Tuner", directoryHint: .isDirectory)
        let caches = URL.cachesDirectory.appending(path: "Tuner", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        settings = AppSettings()
        player = PlayerController()
        radioBrowser = RadioBrowserClient(userAgent: "Tuner/\(Bundle.main.shortVersion)")
        artwork = ArtworkPipeline(directory: caches.appending(path: "Artwork"))
        trackCache = TrackCache(directory: caches.appending(path: "Audio"),
                                limitBytes: Int64(settings.cacheLimitGB) * 1_073_741_824)
        do {
            store = try LibraryStore(path: support.appending(path: "library.sqlite").path())
        } catch {
            // A corrupt cache must never brick the app: it's rebuilt from the server.
            Logger(subsystem: "app.tuner", category: "app").error("store open failed, using memory: \(error)")
            store = try! LibraryStore.inMemory()
        }

        player.replayGain = settings.replayGainSettings
        player.onStationStarted = { [weak self] station in self?.stationStarted(station) }
        #if os(iOS) || os(tvOS)
        audioSession = AudioSessionCoordinator(player: player)
        #endif
        bridge = NowPlayingBridge(player: player) { [weak self] item in
            await self?.artworkURL(for: item, size: 600)
        }
        startNetworkMonitor()
        observeRadioTitles()
        startAppStateSync()
    }

    // MARK: Session

    public func start() async {
        guard phase == .launching else { return }
        if let data = UserDefaults.standard.data(forKey: Self.serverDefaultsKey),
           var config = try? JSONDecoder().decode(ServerConfiguration.self, from: data),
           let secret = Keychain.get(config.id.rawValue) {
            config.credential = config.credential.withSecret(secret)
            connect(config)
        } else {
            #if DEBUG
            // Development convenience: TUNER_DEV_URL / TUNER_DEV_USER / TUNER_DEV_PASS sign in automatically.
            let env = ProcessInfo.processInfo.environment
            if let raw = env["TUNER_DEV_URL"], let url = URL(string: raw), let user = env["TUNER_DEV_USER"], let pass = env["TUNER_DEV_PASS"] {
                do {
                    try await signIn(name: "Dev", urls: [url], username: user, password: pass)
                    return
                } catch {
                    log.error("dev sign-in failed: \(error.localizedDescription)")
                }
            }
            #endif
            phase = .signedOut
        }
    }

    /// Verifies the server and credentials, then stores them (secret in the Keychain).
    public func signIn(name: String, urls: [URL], username: String, password: String) async throws {
        let config = ServerConfiguration(name: name, urls: urls, username: username, credential: .password(password))
        let candidate = SubsonicLibrary(configuration: config)
        try await candidate.verify()

        var stored = config
        stored.credential = .password("")   // secret lives in the Keychain, not UserDefaults
        UserDefaults.standard.set(try JSONEncoder().encode(stored), forKey: Self.serverDefaultsKey)
        Keychain.set(password, for: config.id.rawValue)
        connect(config, library: candidate)
    }

    public func signOut() {
        player.stop()
        if let server { Keychain.delete(server.id.rawValue) }
        UserDefaults.standard.removeObject(forKey: Self.serverDefaultsKey)
        library = nil
        syncer = nil
        server = nil
        player.library = nil
        player.resolver = nil
        phase = .signedOut
    }

    private func connect(_ config: ServerConfiguration, library existing: SubsonicLibrary? = nil) {
        let lib = existing ?? SubsonicLibrary(configuration: config)
        server = config
        library = lib
        player.library = lib
        let lock = expensive
        let settings = settings
        // Read quality on the main actor once per resolve; settings are main-actor state.
        let wifi = settings.wifiQuality.quality, cell = settings.cellularQuality.quality
        player.resolver = LibraryTrackResolver(library: lib, cache: trackCache, quality: {
            lock.withLock { $0 } ? cell : wifi
        })
        syncer = LibrarySyncer(source: lib, store: store)
        phase = .ready
        Task { await sync() }
    }

    /// Call after changing quality settings so new tracks use them.
    public func applyPlaybackSettings() {
        player.replayGain = settings.replayGainSettings
        if let server { connect(server, library: library) }
    }

    // MARK: Library

    public func sync(full: Bool = false) async {
        guard let syncer else { return }
        syncError = nil
        do {
            try await syncer.sync(force: full) { [weak self] progress in
                Task { @MainActor in self?.syncProgress = progress }
            }
        } catch {
            syncError = error.localizedDescription
            log.error("sync failed: \(error.localizedDescription)")
        }
        syncProgress = nil
    }

    /// Album with tracks: local index first (instant, offline), then refreshed from the server.
    public func albumDetail(_ id: ItemID) async -> AlbumDetail? {
        if let local = try? store.album(id), !local.tracks.isEmpty {
            Task { await refreshAlbum(id) }
            return local
        }
        return await refreshAlbum(id)
    }

    @discardableResult
    private func refreshAlbum(_ id: ItemID) async -> AlbumDetail? {
        guard let library, let detail = try? await library.album(id) else { return nil }
        try? store.upsert(detail)
        return detail
    }

    public func play(album id: ItemID, shuffled: Bool = false, startAt index: Int = 0) async {
        guard let detail = await albumDetail(id) else { return }
        player.play(detail.tracks, startAt: index, from: .album(id, name: detail.album.name), shuffled: shuffled)
    }

    public func toggleStar(_ track: Track) {
        let newValue: Date? = track.starred == nil ? Date() : nil
        try? store.setStarred(newValue, track: track.id)
        Task {
            do { try await library?.setStarred(newValue != nil, .track(track.id)) }
            catch { try? store.setStarred(track.starred, track: track.id) }   // roll back
        }
    }

    public func toggleStar(_ album: Album) {
        let newValue: Date? = album.starred == nil ? Date() : nil
        try? store.setStarred(newValue, album: album.id)
        Task {
            do { try await library?.setStarred(newValue != nil, .album(album.id)) }
            catch { try? store.setStarred(album.starred, album: album.id) }
        }
    }

    /// Smart shuffle: continue from a track with similar songs from the server.
    public func startRadio(from track: Track) async {
        guard let library, let similar = try? await library.similar(to: track.id, count: 50), !similar.isEmpty else { return }
        player.play([track] + similar, from: .radio(seed: track.id))
    }

    // MARK: Artwork

    public func coverArtURL(_ coverArtID: String, size: Int) async -> URL? {
        try? await library?.coverArtURL(coverArtID, size: size)
    }

    public func artworkURL(for item: PlayableItem, size: Int) async -> URL? {
        switch item {
        case .track(let t):
            guard let id = t.coverArtID else { return nil }
            return await coverArtURL(id, size: size)
        case .station(let s): return radioEnrichment?.artworkURL ?? s.faviconURL
        }
    }

    // MARK: Radio

    public func addCustomStation(url: URL, name: String?) async throws -> Station {
        let resolved = try await prober.probe(url)
        let station = Station(
            origin: .custom(UUID()),
            name: name?.nonEmpty ?? resolved.name ?? url.host() ?? "Custom Station",
            streamURL: resolved.url,
            codec: resolved.contentType.flatMap(Self.codec(forContentType:)),
            bitRate: resolved.bitRate,
            isHLS: resolved.isHLS
        )
        try store.saveCustomStation(station)
        return station
    }

    static func codec(forContentType type: String) -> String? {
        if type.contains("mpeg") { return "MP3" }
        if type.contains("aac") { return "AAC" }
        if type.contains("ogg") { return "OGG" }
        if type.contains("flac") { return "FLAC" }
        return nil
    }

    private func stationStarted(_ station: Station) {
        radioEnrichment = nil
        radioLibraryMatch = nil
        try? store.markPlayed(station)
        if case .radioBrowser(let uuid) = station.origin {
            Task { await radioBrowser.recordClick(stationUUID: uuid) }
        }
    }

    private func observeRadioTitles() {
        withObservationTracking {
            _ = player.streamTitle
        } onChange: { [weak self] in
            Task { @MainActor in
                await self?.radioTitleChanged()
                self?.observeRadioTitles()
            }
        }
    }

    private func radioTitleChanged() async {
        guard let title = player.streamTitle, case .station(let station) = player.nowPlaying else {
            radioEnrichment = nil
            radioLibraryMatch = nil
            return
        }
        // Debounce: some stations send the title twice or flap during transitions.
        try? await Task.sleep(for: .seconds(2))
        guard player.streamTitle == title else { return }
        radioEnrichment = await enricher.enrich(title, stationName: station.name)
        let searchTitle = radioEnrichment?.title ?? title.title ?? title.raw
        radioLibraryMatch = try? store.findTrack(artist: radioEnrichment?.artist ?? title.artist, title: searchTitle)
    }

    // MARK: Network

    private func startNetworkMonitor() {
        let lock = expensive
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let isExpensive = path.isExpensive || path.isConstrained
            lock.withLock { $0 = isExpensive }
            Task { @MainActor in
                guard let self else { return }
                self.isOnExpensiveNetwork = isExpensive
                // LAN vs remote may have changed: re-probe server URLs on the next request.
                await self.library?.resolver.invalidate()
                await self.player.flushPendingScrobbles()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "tuner.path"))
    }
}

extension ServerConfiguration.Credential {
    func withSecret(_ secret: String) -> Self {
        switch self {
        case .password: .password(secret)
        case .apiKey: .apiKey(secret)
        }
    }
}

extension String {
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1" }
}
