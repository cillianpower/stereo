import AppIntents
import Foundation
import StereoUI

/// Siri phrases use `.applicationName`, so they follow the app's display name.
struct StereoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayPlaylistIntent(), phrases: [
            "Play \(\.$playlist) in \(.applicationName)",
            "Play a playlist in \(.applicationName)",
        ], shortTitle: "Play Playlist", systemImageName: "music.note.list")

        AppShortcut(intent: PlayStationIntent(), phrases: [
            "Play \(\.$station) on \(.applicationName)",
            "Play the radio in \(.applicationName)",
        ], shortTitle: "Play Station", systemImageName: "dot.radiowaves.left.and.right")

        AppShortcut(intent: PlayAlbumIntent(), phrases: [
            "Play an album in \(.applicationName)",
        ], shortTitle: "Play Album", systemImageName: "square.stack")

        AppShortcut(intent: PlayArtistIntent(), phrases: [
            "Play an artist in \(.applicationName)",
        ], shortTitle: "Play Artist", systemImageName: "music.mic")

        AppShortcut(intent: ShuffleLibraryIntent(), phrases: [
            "Shuffle my library in \(.applicationName)",
            "Shuffle \(.applicationName)",
        ], shortTitle: "Shuffle Library", systemImageName: "shuffle")

        AppShortcut(intent: TogglePlaybackIntent(), phrases: [
            "Play or pause \(.applicationName)",
        ], shortTitle: "Play or Pause", systemImageName: "playpause")

        AppShortcut(intent: IdentifySongIntent(), phrases: [
            "What's playing in \(.applicationName)",
            "Identify this song in \(.applicationName)",
        ], shortTitle: "Identify Song", systemImageName: "shazam.logo")
    }
}

@MainActor
enum AppIntentsSetup {
    private static var spotlight: SpotlightIndexer?

    /// Registers the shared model before any intent runs, and keeps Siri and Spotlight current.
    static func configure(_ app: AppModel) {
        AppDependencyManager.shared.add(dependency: app)
        var indexesSpotlight = true
        #if DEBUG
        // Test runs against a throwaway library shouldn't add it to the Mac's system search.
        indexesSpotlight = ProcessInfo.processInfo.environment["STEREO_NO_SPOTLIGHT"] == nil
        #endif
        if indexesSpotlight {
            let indexer = SpotlightIndexer(app: app)
            indexer.start()
            spotlight = indexer
        }
        StereoShortcuts.updateAppShortcutParameters()
        Task {
            for await _ in app.store.observePlaylists() { StereoShortcuts.updateAppShortcutParameters() }
        }
        Task {
            for await _ in app.store.observeFavoriteStations() { StereoShortcuts.updateAppShortcutParameters() }
        }
    }
}
