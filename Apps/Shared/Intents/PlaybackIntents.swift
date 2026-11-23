import AppIntents
import TunerModel
import TunerUI

struct PlayAlbumIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Album"
    static let description = IntentDescription("Plays an album from your library.")

    @Parameter(title: "Album", requestValueDialog: "Which album?") var album: AlbumEntity
    @Parameter(title: "Shuffle", default: false) var shuffled: Bool
    @Dependency var app: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$album)") { \.$shuffled }
    }

    @MainActor func perform() async throws -> some IntentResult {
        guard let id = ItemID(string: album.id) else { throw AppActionError.notFound("album") }
        try await app.performPlayAlbum(id, shuffled: shuffled)
        return .result()
    }
}

struct PlayArtistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Artist"
    static let description = IntentDescription("Plays every album by an artist in your library.")

    @Parameter(title: "Artist", requestValueDialog: "Which artist?") var artist: ArtistEntity
    @Parameter(title: "Shuffle", default: true) var shuffled: Bool
    @Dependency var app: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$artist)") { \.$shuffled }
    }

    @MainActor func perform() async throws -> some IntentResult {
        guard let id = ItemID(string: artist.id) else { throw AppActionError.notFound("artist") }
        try await app.performPlayArtist(id, name: artist.name, shuffled: shuffled)
        return .result()
    }
}

struct PlayPlaylistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Playlist"
    static let description = IntentDescription("Plays one of your playlists.")

    @Parameter(title: "Playlist", requestValueDialog: "Which playlist?") var playlist: PlaylistEntity
    @Parameter(title: "Shuffle", default: false) var shuffled: Bool
    @Dependency var app: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$playlist)") { \.$shuffled }
    }

    @MainActor func perform() async throws -> some IntentResult {
        guard let id = ItemID(string: playlist.id) else { throw AppActionError.notFound("playlist") }
        try await app.performPlayPlaylist(id, name: playlist.name, shuffled: shuffled)
        return .result()
    }
}

struct PlayStationIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Radio Station"
    static let description = IntentDescription("Plays a saved or recently played radio station.")

    @Parameter(title: "Station", requestValueDialog: "Which station?") var station: StationEntity
    @Dependency var app: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$station)")
    }

    @MainActor func perform() async throws -> some IntentResult {
        await app.performPlayStation(station.station)
        return .result()
    }
}

struct ShuffleLibraryIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle Library"
    static let description = IntentDescription("Plays a random selection of up to 500 songs from your library.")

    @Dependency var app: AppModel

    @MainActor func perform() async throws -> some IntentResult {
        try await app.performShuffleLibrary()
        return .result()
    }
}

struct TogglePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let description = IntentDescription("Plays or pauses the current song or station.")

    @Dependency var app: AppModel

    @MainActor func perform() async throws -> some IntentResult {
        try await app.performTogglePlayback()
        return .result()
    }
}

struct IdentifySongIntent: AppIntent {
    static let title: LocalizedStringResource = "Identify Song"
    static let description = IntentDescription("Identifies the song that's currently playing, and returns its title and artist.")

    @Dependency var app: AppModel

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String?> & ProvidesDialog {
        let song = try await app.performIdentifySong()
        let dialog: IntentDialog = song.map { "That's \($0)." } ?? "I couldn't identify this song."
        return .result(value: song, dialog: dialog)
    }
}
