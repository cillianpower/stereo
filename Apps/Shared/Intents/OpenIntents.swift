import AppIntents
import CoreSpotlight
import StereoModel
import StereoUI

// MARK: Spotlight fields

extension AlbumEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = name
        attributes.album = name
        attributes.artist = artist
        attributes.contentDescription = artist.map { "Album by \($0)" } ?? "Album"
        return attributes
    }
}

extension ArtistEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = name
        attributes.artist = name
        attributes.contentDescription = "Artist"
        return attributes
    }
}

extension PlaylistEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = name
        attributes.contentDescription = "Playlist"
        return attributes
    }
}

extension StationEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = name
        attributes.contentDescription = "Radio Station"
        attributes.keywords = station.tags
        return attributes
    }
}

// MARK: Opening a result

struct OpenAlbumIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Album"
    @Parameter(title: "Album") var target: AlbumEntity
    @Dependency var app: AppModel

    @MainActor func perform() async throws -> some IntentResult {
        guard let id = ItemID(string: target.id) else { throw AppActionError.notFound("album") }
        app.pendingDestination = .library(.album(id))
        return .result()
    }
}

struct OpenArtistIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Artist"
    @Parameter(title: "Artist") var target: ArtistEntity
    @Dependency var app: AppModel

    @MainActor func perform() async throws -> some IntentResult {
        guard let id = ItemID(string: target.id) else { throw AppActionError.notFound("artist") }
        app.pendingDestination = .library(.artist(id))
        return .result()
    }
}

struct OpenPlaylistIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Playlist"
    @Parameter(title: "Playlist") var target: PlaylistEntity
    @Dependency var app: AppModel

    @MainActor func perform() async throws -> some IntentResult {
        guard let id = ItemID(string: target.id) else { throw AppActionError.notFound("playlist") }
        app.pendingDestination = .library(.playlist(id))
        return .result()
    }
}

/// A station has no detail screen, so opening one starts it and shows Radio.
struct OpenStationIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Radio Station"
    @Parameter(title: "Station") var target: StationEntity
    @Dependency var app: AppModel

    @MainActor func perform() async throws -> some IntentResult {
        await app.performPlayStation(target.station)
        app.pendingDestination = .radio
        return .result()
    }
}
