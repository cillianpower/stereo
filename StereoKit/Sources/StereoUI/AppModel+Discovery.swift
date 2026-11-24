import Foundation
import Observation
import SubsonicClient
import StereoDiscovery
import StereoModel
import StereoStore

/// Discovery features for one connected server: ListenBrainz, the Home feed and autoplay.
@MainActor
@Observable
public final class DiscoveryServices {
    public enum ListenBrainzStatus: Equatable {
        case notConnected
        case connected(user: String)
        case failed(String)
    }

    public private(set) var listenBrainzStatus: ListenBrainzStatus = .notConnected

    @ObservationIgnored let libraryID: SourceID
    @ObservationIgnored public private(set) var homeFeed: HomeFeed
    @ObservationIgnored public private(set) var autoContinue: AutoContinue
    @ObservationIgnored private(set) var listenBrainz: ListenBrainzClient?
    @ObservationIgnored private let library: SubsonicLibrary
    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let settings: AppSettings

    static let tokenAccount = "listenbrainz.token"
    static let userAgent = "Stereo/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1")"

    init(library: SubsonicLibrary, store: LibraryStore, settings: AppSettings) {
        self.library = library
        self.store = store
        self.settings = settings
        libraryID = library.id

        var client: ListenBrainzClient?
        if let token = Keychain.get(Self.tokenAccount), let user = settings.listenBrainzUser {
            client = ListenBrainzClient(token: token, userAgent: Self.userAgent)
            listenBrainzStatus = .connected(user: user)
        }
        listenBrainz = client
        homeFeed = HomeFeed(store: store, library: library, listenBrainz: client, user: settings.listenBrainzUser)
        autoContinue = AutoContinue(library: library, store: store, listenBrainz: client)
    }

    /// Validates the token, then stores it (Keychain) and its user name.
    public func connectListenBrainz(token raw: String) async {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = ListenBrainzClient(token: token, userAgent: Self.userAgent)
        do {
            let user = try await client.validateToken()
            Keychain.set(token, for: Self.tokenAccount)
            settings.listenBrainzUser = user
            apply(client, user: user)
            listenBrainzStatus = .connected(user: user)
        } catch {
            listenBrainzStatus = .failed(error.localizedDescription)
        }
    }

    public func disconnectListenBrainz() {
        Keychain.delete(Self.tokenAccount)
        settings.listenBrainzUser = nil
        apply(nil, user: nil)
        listenBrainzStatus = .notConnected
    }

    private func apply(_ client: ListenBrainzClient?, user: String?) {
        listenBrainz = client
        let feed = homeFeed
        Task { await feed.setListenBrainz(client, user: user) }
        autoContinue = AutoContinue(library: library, store: store, listenBrainz: client)
    }
}

extension AppModel {
    /// Called from `connect`. Reuses the existing services when reconnecting to the same server
    /// (e.g. after a settings change), so autoplay history and Home caches survive.
    func configureDiscovery(library: SubsonicLibrary) {
        if discovery?.libraryID != library.id {
            discovery = DiscoveryServices(library: library, store: store, settings: settings)
        }
        player.onQueueExhausted = { [weak self] queue in
            guard let self, self.settings.autoplayEnabled, let discovery = self.discovery else { return [] }
            return await discovery.autoContinue.nextTracks(after: queue)
        }
    }

    func tearDownDiscovery() {
        player.onQueueExhausted = nil
        discovery = nil
    }
}
