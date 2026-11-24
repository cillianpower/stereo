import AppIntents

// Compiled into both the apps and the widget extensions. Audio playback intents run in the app's
// process, so the extension's copies only describe the buttons; the WIDGET_EXTENSION versions of
// `perform` never run. Hidden from Shortcuts, which has the full intents in Apps/Shared/Intents.

#if !WIDGET_EXTENSION
import StereoModel
import StereoUI
#endif

struct WidgetTogglePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let isDiscoverable = false

    init() {}

    #if WIDGET_EXTENSION
    func perform() async throws -> some IntentResult { .result() }
    #else
    @Dependency var app: AppModel
    @MainActor func perform() async throws -> some IntentResult {
        try await app.performTogglePlayback()
        return .result()
    }
    #endif
}

struct WidgetSkipIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Skip"
    static let isDiscoverable = false

    @Parameter(title: "Forward") var forward: Bool

    init() {}
    init(forward: Bool) { self.forward = forward }

    #if WIDGET_EXTENSION
    func perform() async throws -> some IntentResult { .result() }
    #else
    @Dependency var app: AppModel
    @MainActor func perform() async throws -> some IntentResult {
        try await app.performSkip(forward: forward)
        return .result()
    }
    #endif
}

struct WidgetPlayAlbumIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Album"
    static let isDiscoverable = false

    @Parameter(title: "Album ID") var albumID: String

    init() {}
    init(albumID: String) { self.albumID = albumID }

    #if WIDGET_EXTENSION
    func perform() async throws -> some IntentResult { .result() }
    #else
    @Dependency var app: AppModel
    @MainActor func perform() async throws -> some IntentResult {
        guard let id = ItemID(string: albumID) else { throw AppActionError.notFound("album") }
        try await app.performPlayAlbum(id, shuffled: false)
        return .result()
    }
    #endif
}

struct WidgetPlayStationIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Station"
    static let isDiscoverable = false

    @Parameter(title: "Station ID") var stationID: String

    init() {}
    init(stationID: String) { self.stationID = stationID }

    #if WIDGET_EXTENSION
    func perform() async throws -> some IntentResult { .result() }
    #else
    @Dependency var app: AppModel
    @MainActor func perform() async throws -> some IntentResult {
        try await app.performPlayStation(id: stationID)
        return .result()
    }
    #endif
}
