import AppIntents
import TunerModel
import TunerUI

private let suggestionLimit = 50

private func itemIDs(_ identifiers: [String]) -> [ItemID] { identifiers.compactMap(ItemID.init(string:)) }

private func subtitle(_ text: String?) -> LocalizedStringResource? {
    text.map { LocalizedStringResource(stringLiteral: $0) }
}

// MARK: Album

struct AlbumEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Album"
    static let defaultQuery = AlbumEntityQuery()

    let id: String
    let name: String
    let artist: String?

    init(_ album: Album) {
        id = album.id.description
        name = album.name
        artist = album.artist
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: subtitle(artist))
    }
}

struct AlbumEntityQuery: EntityStringQuery {
    @Dependency var app: AppModel

    @MainActor func entities(for identifiers: [String]) async throws -> [AlbumEntity] {
        try itemIDs(identifiers).compactMap { try app.store.album($0)?.album }.map(AlbumEntity.init)
    }

    @MainActor func entities(matching string: String) async throws -> [AlbumEntity] {
        try app.store.search(string).albums.map(AlbumEntity.init)
    }

    @MainActor func suggestedEntities() async throws -> [AlbumEntity] {
        let recent = try app.store.albums(sortedBy: .recentlyPlayed, limit: suggestionLimit)
        let albums = recent.isEmpty ? try app.store.albums(sortedBy: .recentlyAdded, limit: suggestionLimit) : recent
        return albums.map(AlbumEntity.init)
    }
}

// MARK: Artist

struct ArtistEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Artist"
    static let defaultQuery = ArtistEntityQuery()

    let id: String
    let name: String

    init(_ artist: Artist) {
        id = artist.id.description
        name = artist.name
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct ArtistEntityQuery: EntityStringQuery {
    @Dependency var app: AppModel

    @MainActor func entities(for identifiers: [String]) async throws -> [ArtistEntity] {
        let wanted = Set(itemIDs(identifiers))
        return try app.store.artists().filter { wanted.contains($0.id) }.map(ArtistEntity.init)
    }

    @MainActor func entities(matching string: String) async throws -> [ArtistEntity] {
        try app.store.search(string).artists.map(ArtistEntity.init)
    }

    @MainActor func suggestedEntities() async throws -> [ArtistEntity] {
        try app.store.artists()
            .sorted { ($0.albumCount ?? 0) > ($1.albumCount ?? 0) }
            .prefix(suggestionLimit)
            .map(ArtistEntity.init)
    }
}

// MARK: Playlist

struct PlaylistEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Playlist"
    static let defaultQuery = PlaylistEntityQuery()

    let id: String
    let name: String

    init(_ playlist: Playlist) {
        id = playlist.id.description
        name = playlist.name
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct PlaylistEntityQuery: EntityStringQuery {
    @Dependency var app: AppModel

    @MainActor func entities(for identifiers: [String]) async throws -> [PlaylistEntity] {
        let wanted = Set(itemIDs(identifiers))
        return try app.store.playlists().filter { wanted.contains($0.id) }.map(PlaylistEntity.init)
    }

    @MainActor func entities(matching string: String) async throws -> [PlaylistEntity] {
        try app.store.playlists()
            .filter { $0.name.localizedStandardContains(string) }
            .map(PlaylistEntity.init)
    }

    @MainActor func suggestedEntities() async throws -> [PlaylistEntity] {
        try app.store.playlists().prefix(suggestionLimit).map(PlaylistEntity.init)
    }
}

// MARK: Station

struct StationEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Radio Station"
    static let defaultQuery = StationEntityQuery()

    let id: String
    let name: String
    let station: Station

    init(_ station: Station) {
        id = station.id
        name = station.name
        self.station = station
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: subtitle(station.tags.first))
    }
}

struct StationEntityQuery: EntityStringQuery {
    @Dependency var app: AppModel

    @MainActor func entities(for identifiers: [String]) async throws -> [StationEntity] {
        let wanted = Set(identifiers)
        return try app.store.savedStations().filter { wanted.contains($0.id) }.map(StationEntity.init)
    }

    @MainActor func entities(matching string: String) async throws -> [StationEntity] {
        try app.store.savedStations()
            .filter { $0.name.localizedStandardContains(string) }
            .map(StationEntity.init)
    }

    @MainActor func suggestedEntities() async throws -> [StationEntity] {
        try app.store.savedStations().prefix(suggestionLimit).map(StationEntity.init)
    }
}
