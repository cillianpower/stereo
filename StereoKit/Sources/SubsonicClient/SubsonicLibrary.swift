import Foundation
import StereoModel

/// A Navidrome / OpenSubsonic server as a `LibrarySource`.
public actor SubsonicLibrary: LibrarySource {
    public nonisolated let id: SourceID
    public nonisolated let configuration: ServerConfiguration
    let api: SubsonicAPI
    public let resolver: EndpointResolver
    private var cachedCapabilities: LibraryCapabilities?

    public init(configuration: ServerConfiguration, transport: HTTPTransport = URLSession.shared) {
        let api = SubsonicAPI(config: configuration, transport: transport)
        self.id = configuration.id
        self.configuration = configuration
        self.api = api
        self.resolver = EndpointResolver(urls: configuration.urls) { url in
            await api.isReachable(base: url)
        }
    }

    // MARK: Plumbing

    /// Runs `body` against the resolved endpoint; on a connection-level failure, re-resolves once and retries.
    private func perform<T: Sendable>(_ body: @Sendable (URL) async throws -> T) async throws -> T {
        let base = try await resolver.resolve()
        do {
            return try await body(base)
        } catch let error as URLError where Self.isConnectivity(error) {
            await resolver.invalidate()
            let retryBase = try await resolver.resolve()
            return try await body(retryBase)
        }
    }

    static func isConnectivity(_ error: URLError) -> Bool {
        [.timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
         .notConnectedToInternet, .dnsLookupFailed, .secureConnectionFailed].contains(error.code)
    }

    private func get<B: Decodable & Sendable>(_ type: B.Type, _ endpoint: String, _ query: [URLQueryItem] = []) async throws -> B {
        let api = self.api
        return try await perform { base in
            try await api.request(type, base: base, endpoint: endpoint, query: query)
        }
    }

    private func itemID(_ raw: String) -> ItemID { ItemID(source: id, raw: raw) }

    private func raw(_ itemID: ItemID) throws -> String {
        guard itemID.source == id else { throw SubsonicError.invalidID(itemID.description) }
        return itemID.raw
    }

    // MARK: Server info

    /// Verifies reachability and credentials. Use for sign-in.
    public func verify() async throws {
        let base = try await resolver.resolve()
        try await api.ping(base: base)
    }

    public func capabilities() async throws -> LibraryCapabilities {
        if let cachedCapabilities { return cachedCapabilities }
        var caps: LibraryCapabilities = [.similarSongs, .playQueue, .transcoding, .jukebox]
        if let body = try? await get(ExtensionsBody.self, "getOpenSubsonicExtensions") {
            let names = Set((body.openSubsonicExtensions ?? []).map(\.name))
            if names.contains("songLyrics") { caps.insert(.syncedLyrics) }
            if names.contains("transcodeOffset") { caps.insert(.transcodeOffset) }
            if names.contains("apiKeyAuthentication") { caps.insert(.apiKeyAuth) }
            if names.contains("formPost") { caps.insert(.formPost) }
        }
        cachedCapabilities = caps
        return caps
    }

    // MARK: Browse

    public func albums(_ list: AlbumListKind, page: PageRequest) async throws -> Page<Album> {
        let body = try await get(AlbumList2Body.self, "getAlbumList2", [
            .init(name: "type", value: list.rawValue),
            .init(name: "size", value: String(page.size)),
            .init(name: "offset", value: String(page.offset)),
        ])
        return Page(items: (body.albumList2.album ?? []).map(map), request: page)
    }

    public func album(_ albumID: ItemID) async throws -> AlbumDetail {
        let body = try await get(AlbumBody.self, "getAlbum", [.init(name: "id", value: try raw(albumID))])
        return AlbumDetail(album: map(body.album), tracks: (body.album.song ?? []).map(map))
    }

    /// Labels, dates and moods from OpenSubsonic, plus notes and links from `getAlbumInfo2`. Notes
    /// need a metadata agent such as Last.fm on the server, so their absence isn't an error.
    public func albumInfo(_ albumID: ItemID) async throws -> AlbumInfo {
        let query = [URLQueryItem(name: "id", value: try raw(albumID))]
        let album = (try? await get(AlbumExtrasBody.self, "getAlbum", query))?.album
        let notes = (try? await get(AlbumInfoBody.self, "getAlbumInfo2", query))?.albumInfo
        guard album != nil || notes != nil else { throw SubsonicError.invalidID(albumID.description) }

        func clean(_ values: [String?]?) -> [String] {
            var seen = Set<String>()
            return (values ?? []).compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        }
        func nonEmpty(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        let date = [album?.originalReleaseDate, album?.releaseDate].compactMap { $0 }.first { $0.year != nil }
        return AlbumInfo(
            notes: AlbumInfo.plainText(fromHTML: notes?.notes),
            lastFmURL: nonEmpty(notes?.lastFmUrl).flatMap(URL.init(string:)),
            musicBrainzID: nonEmpty(notes?.musicBrainzId) ?? nonEmpty(album?.musicBrainzId),
            labels: clean(album?.recordLabels?.map(\.name)),
            releaseTypes: clean(album?.releaseTypes),
            genres: clean(album?.genres?.map(\.name)),
            moods: clean(album?.moods),
            released: date.map { AlbumInfo.ReleaseDate(year: $0.year, month: $0.month, day: $0.day) },
            version: nonEmpty(album?.version),
            isCompilation: album?.isCompilation ?? false
        )
    }

    public func artists() async throws -> [Artist] {
        let body = try await get(ArtistsBody.self, "getArtists")
        return (body.artists.index ?? []).flatMap { $0.artist ?? [] }.map(map)
    }

    public func artist(_ artistID: ItemID) async throws -> ArtistDetail {
        let body = try await get(ArtistBody.self, "getArtist", [.init(name: "id", value: try raw(artistID))])
        return ArtistDetail(artist: map(body.artist), albums: (body.artist.album ?? []).map(map))
    }

    public func artistInfo(_ artistID: ItemID) async throws -> ArtistInfo {
        let body = try await get(ArtistInfoBody.self, "getArtistInfo2", [.init(name: "id", value: try raw(artistID))])
        let info = body.artistInfo2
        return ArtistInfo(
            biography: AlbumInfo.plainText(fromHTML: info?.biography),
            lastFmURL: info?.lastFmUrl.flatMap { $0.isEmpty ? nil : URL(string: $0) },
            musicBrainzID: info?.musicBrainzId.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    public func topSongs(artistName: String, count: Int = 10) async throws -> [Track] {
        let body = try await get(TopSongsBody.self, "getTopSongs", [
            .init(name: "artist", value: artistName), .init(name: "count", value: String(count)),
        ])
        return (body.topSongs.song ?? []).map(map)
    }

    public func playlists() async throws -> [Playlist] {
        let body = try await get(PlaylistsBody.self, "getPlaylists")
        return (body.playlists.playlist ?? []).map(map)
    }

    public func playlist(_ playlistID: ItemID) async throws -> PlaylistDetail {
        let body = try await get(PlaylistBody.self, "getPlaylist", [.init(name: "id", value: try raw(playlistID))])
        return PlaylistDetail(playlist: map(body.playlist), tracks: (body.playlist.entry ?? []).map(map))
    }

    public func search(_ query: String, limit: Int = 20) async throws -> SearchResults {
        let n = String(limit)
        let body = try await get(Search3Body.self, "search3", [
            .init(name: "query", value: query),
            .init(name: "artistCount", value: n), .init(name: "albumCount", value: n), .init(name: "songCount", value: n),
        ])
        let r = body.searchResult3
        return SearchResults(
            artists: (r.artist ?? []).map(map),
            albums: (r.album ?? []).map(map),
            tracks: (r.song ?? []).map(map)
        )
    }

    // MARK: Media URLs

    public func streamRequest(for track: ItemID, quality: StreamQuality, offset: Duration?) async throws -> URLRequest {
        let rawID = try raw(track)
        var query: [URLQueryItem] = [.init(name: "id", value: rawID)]
        switch quality {
        case .original:
            query.append(.init(name: "format", value: "raw"))
        case .transcoded(let format, let maxBitRate):
            query.append(.init(name: "format", value: format))
            query.append(.init(name: "maxBitRate", value: String(maxBitRate)))
            // No `estimateContentLength`: on a cold transcode the estimate overshoots and the server
            // closes early, which URLSession reports as "network connection lost".
        }
        // Originals are seekable files: the engine seeks with HTTP Range itself, so `offset` only
        // matters for transcodes, and only when the server can start a transcode mid-track.
        if let offset, offset > .zero, case .transcoded = quality, try await capabilities().contains(.transcodeOffset) {
            query.append(.init(name: "timeOffset", value: String(Int(offset.components.seconds))))
        }
        let base = try await resolver.resolve()
        return URLRequest(url: api.url(base: base, endpoint: "stream", query: query))
    }

    public func downloadRequest(for track: ItemID) async throws -> URLRequest {
        let base = try await resolver.resolve()
        return URLRequest(url: api.url(base: base, endpoint: "download", query: [.init(name: "id", value: try raw(track))]))
    }

    public func coverArtURL(_ coverArtID: String, size: Int) async throws -> URL {
        let base = try await resolver.resolve()
        return api.url(base: base, endpoint: "getCoverArt", query: [
            .init(name: "id", value: coverArtID), .init(name: "size", value: String(size)),
        ])
    }

    // MARK: Extras

    public func lyrics(for track: Track) async throws -> Lyrics? {
        if try await capabilities().contains(.syncedLyrics) {
            let body = try await get(LyricsListBody.self, "getLyricsBySongId", [.init(name: "id", value: try raw(track.id))])
            let all = body.lyricsList.structuredLyrics ?? []
            if let best = all.first(where: \.synced) ?? all.first {
                let offset = best.offset ?? 0
                return Lyrics(
                    lines: (best.line ?? []).map { line in
                        Lyrics.Line(start: line.start.map { .milliseconds($0 + offset) }, text: line.value)
                    },
                    isSynced: best.synced
                )
            }
        }
        guard let artist = track.artist else { return nil }
        let body = try await get(LyricsBody.self, "getLyrics", [
            .init(name: "artist", value: artist), .init(name: "title", value: track.title),
        ])
        guard let text = body.lyrics?.value, !text.isEmpty else { return nil }
        return Lyrics(lines: text.components(separatedBy: .newlines).map { .init(start: nil, text: $0) }, isSynced: false)
    }

    public func similar(to track: ItemID, count: Int) async throws -> [Track] {
        let body = try await get(SimilarSongs2Body.self, "getSimilarSongs2", [
            .init(name: "id", value: try raw(track)), .init(name: "count", value: String(count)),
        ])
        return (body.similarSongs2.song ?? []).map(map)
    }

    public func setStarred(_ starred: Bool, _ target: StarTarget) async throws {
        let item: URLQueryItem
        switch target {
        case .track(let id): item = .init(name: "id", value: try raw(id))
        case .album(let id): item = .init(name: "albumId", value: try raw(id))
        case .artist(let id): item = .init(name: "artistId", value: try raw(id))
        }
        _ = try await get(PingBody.self, starred ? "star" : "unstar", [item])
    }

    public func setRating(_ rating: Int, track: ItemID) async throws {
        _ = try await get(PingBody.self, "setRating", [
            .init(name: "id", value: try raw(track)), .init(name: "rating", value: String(min(max(rating, 0), 5))),
        ])
    }

    public func report(_ event: PlaybackEvent) async throws {
        switch event {
        case .nowPlaying(let id):
            _ = try await get(PingBody.self, "scrobble", [
                .init(name: "id", value: try raw(id)), .init(name: "submission", value: "false"),
            ])
        case .played(let id, let date):
            _ = try await get(PingBody.self, "scrobble", [
                .init(name: "id", value: try raw(id)),
                .init(name: "submission", value: "true"),
                .init(name: "time", value: String(Int64(date.timeIntervalSince1970 * 1000))),
            ])
        }
    }

    public func savePlayQueue(_ tracks: [ItemID], current: ItemID?, position: Duration) async throws {
        var query = try tracks.map { URLQueryItem(name: "id", value: try raw($0)) }
        if let current { query.append(.init(name: "current", value: try raw(current))) }
        let ms = position.components.seconds * 1000 + position.components.attoseconds / 1_000_000_000_000_000
        query.append(.init(name: "position", value: String(ms)))
        _ = try await get(PingBody.self, "savePlayQueue", query)
    }

    public func loadPlayQueue() async throws -> SavedPlayQueue? {
        let body = try await get(PlayQueueBody.self, "getPlayQueue")
        guard let q = body.playQueue, let entries = q.entry, !entries.isEmpty else { return nil }
        return SavedPlayQueue(
            tracks: entries.map(map),
            current: q.current.map(itemID),
            position: .milliseconds(q.position ?? 0),
            changed: q.changed,
            changedBy: q.changedBy
        )
    }

    // MARK: Mapping

    func map(_ s: SongDTO) -> Track {
        Track(
            id: itemID(s.id), title: s.title, artist: s.artist, artistID: s.artistId.map(itemID),
            album: s.album, albumID: s.albumId.map(itemID), trackNumber: s.track, discNumber: s.discNumber,
            year: s.year, genre: s.genre, duration: s.duration.map { .seconds($0) }, coverArtID: s.coverArt,
            format: AudioFormat(codec: s.suffix?.lowercased(), bitRate: s.bitRate, sampleRate: s.samplingRate,
                                bitDepth: s.bitDepth, channels: s.channelCount),
            replayGain: ReplayGain(trackGain: s.replayGain?.trackGain, trackPeak: s.replayGain?.trackPeak,
                                   albumGain: s.replayGain?.albumGain, albumPeak: s.replayGain?.albumPeak),
            starred: s.starred, rating: s.userRating, playCount: s.playCount, musicBrainzID: s.musicBrainzId
        )
    }

    func map(_ a: AlbumDTO) -> Album {
        Album(
            id: itemID(a.id), name: a.name ?? a.title ?? "Unknown Album", artist: a.artist,
            artistID: a.artistId.map(itemID), year: a.year, genre: a.genre, songCount: a.songCount,
            duration: a.duration.map { .seconds($0) }, coverArtID: a.coverArt, created: a.created,
            starred: a.starred, playCount: a.playCount, lastPlayed: a.played
        )
    }

    func map(_ a: ArtistDTO) -> Artist {
        Artist(id: itemID(a.id), name: a.name, albumCount: a.albumCount, coverArtID: a.coverArt, starred: a.starred)
    }

    func map(_ p: PlaylistDTO) -> Playlist {
        Playlist(id: itemID(p.id), name: p.name, comment: p.comment, songCount: p.songCount,
                 duration: p.duration.map { .seconds($0) }, coverArtID: p.coverArt, changed: p.changed)
    }
}
