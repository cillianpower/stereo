import Foundation
import SubsonicClient
import StereoDownloads
import StereoModel
import StereoStore

extension AppModel {
    static let downloadQualityKey = "downloadQuality"

    /// Quality for new pins (Settings → Downloads). Defaults to originals.
    var downloadQuality: StreamQuality {
        let raw = UserDefaults.standard.string(forKey: Self.downloadQualityKey)
        return raw.flatMap(AppSettings.QualityOption.init(rawValue:))?.quality ?? .original
    }

    /// One manager (and one background URLSession) for the app's lifetime; reconnects just swap
    /// its source. Creating a second background session with the same identifier is an error.
    func attachDownloads(to library: SubsonicLibrary) -> DownloadManager {
        if let downloads {
            Task { await downloads.setSource(library) }
            return downloads
        }
        let support = URL.applicationSupportDirectory.appending(path: "Stereo", directoryHint: .isDirectory)
        let identifier = (Bundle.main.bundleIdentifier ?? "app.stereo") + ".downloads"
        let transport = URLSessionDownloadTransport.background(
            identifier: identifier, staging: support.appending(path: "DownloadStaging"))
        let manager = DownloadManager(source: library, store: store,
                                      directory: support.appending(path: "Downloads"), transport: transport)
        downloads = manager
        Task { await manager.start() }
        return manager
    }

    /// Sign-out pauses transfers but keeps files: the same server usually comes back.
    func detachDownloads() {
        guard let downloads else { return }
        Task { await downloads.setSource(nil) }
    }

    public func download(_ owner: PinOwner) async throws {
        guard let downloads else { throw DownloadError.noSource }
        switch owner {
        case .album(let id): try await downloads.pin(album: id, quality: downloadQuality)
        case .playlist(let id): try await downloads.pin(playlist: id, quality: downloadQuality)
        case .track(let id):
            guard let track = try store.tracks(ids: [id]).first else { throw DownloadError.noSource }
            try await downloads.pin(track: track, quality: downloadQuality)
        }
    }

    public func removeDownload(_ owner: PinOwner) async {
        try? await downloads?.unpin(owner)
    }

    public func retryFailedDownloads() async {
        await downloads?.retryFailed()
    }

    public func removeAllDownloads() async {
        await downloads?.deleteAll()
    }

    /// Plays a pinned album or playlist from the local index, so it works with no network.
    public func playDownloaded(_ pin: Pin, shuffled: Bool = false) {
        let ids = (try? store.pinnedTrackIDs(pin.owner)) ?? []
        let tracks = (try? store.tracks(ids: ids)) ?? []
        guard !tracks.isEmpty else { return }
        let context: QueueContext = switch pin.owner {
        case .album(let id): .album(id, name: pin.name)
        case .playlist(let id): .playlist(id, name: pin.name)
        case .track: .songs
        }
        player.play(tracks, from: context, shuffled: shuffled)
    }
}
