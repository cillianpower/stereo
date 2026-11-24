import Foundation
import StereoModel
import StereoPlayback
import StereoRemote
import StereoStore

/// Why a system-initiated action (Siri, Shortcuts, widgets) could not run. Shown to the user.
public enum AppActionError: LocalizedError, Equatable {
    case signedOut
    case notFound(String)
    case emptyLibrary
    case nothingPlaying
    case identifyBusy
    case identifyNeedsLocalPlayback
    case identifyNeedsRadio

    public var errorDescription: String? {
        switch self {
        case .signedOut: "Sign in to your music server first."
        case .notFound(let item): "Couldn't find that \(item)."
        case .emptyLibrary: "Your library is empty or hasn't finished syncing."
        case .nothingPlaying: "Nothing is playing."
        case .identifyBusy: "Already identifying a song."
        case .identifyNeedsLocalPlayback: "Song identification only works on the device that's playing."
        case .identifyNeedsRadio: "Song identification is for radio stations."
        }
    }
}

/// Where an external request (such as a Spotlight result) should land.
public enum AppDestination: Hashable {
    case library(Route)
    case radio
}

/// Actions for App Intents. Each one finishes launching first, because the system can start the
/// app in the background with no view on screen, and follows "controlling <device>" mode.
extension AppModel {
    private func requireSession() async throws {
        await start()
        guard phase == .ready else { throw AppActionError.signedOut }
    }

    private func deliver(_ tracks: [Track], from context: QueueContext, shuffled: Bool) {
        if remote.isControllingRemote {
            remote.send(.setQueue(tracks: tracks, startIndex: 0, shuffled: shuffled))
        } else {
            player.play(tracks, from: context, shuffled: shuffled)
        }
    }

    public func performPlayAlbum(_ id: ItemID, shuffled: Bool) async throws {
        try await requireSession()
        guard let detail = await albumDetail(id), !detail.tracks.isEmpty else { throw AppActionError.notFound("album") }
        deliver(detail.tracks, from: .album(id, name: detail.album.name), shuffled: shuffled)
    }

    public func performPlayArtist(_ id: ItemID, name: String, shuffled: Bool) async throws {
        try await requireSession()
        var albums = (try? store.albums(byArtist: id)) ?? []
        if albums.isEmpty, let detail = try? await library?.artist(id) { albums = detail.albums }
        var tracks: [Track] = []
        for album in albums {
            // The local index avoids one server refresh per album.
            if let local = try? store.album(album.id), !local.tracks.isEmpty {
                tracks += local.tracks
            } else if let fetched = await albumDetail(album.id) {
                tracks += fetched.tracks
            }
        }
        guard !tracks.isEmpty else { throw AppActionError.notFound("artist") }
        deliver(tracks, from: .artist(id, name: name), shuffled: shuffled)
    }

    public func performPlayPlaylist(_ id: ItemID, name: String, shuffled: Bool) async throws {
        try await requireSession()
        var tracks = (try? await library?.playlist(id))?.tracks ?? []
        if tracks.isEmpty {
            // Offline: fall back to a downloaded copy.
            let pinned = (try? store.pinnedTrackIDs(.playlist(id))) ?? []
            tracks = (try? store.tracks(ids: pinned)) ?? []
        }
        guard !tracks.isEmpty else { throw AppActionError.notFound("playlist") }
        deliver(tracks, from: .playlist(id, name: name), shuffled: shuffled)
    }

    /// Stations don't need a music server, so this works while signed out.
    public func performPlayStation(_ station: Station) async {
        await start()
        if remote.isControllingRemote {
            remote.send(.playStation(station))
        } else {
            player.play(station)
        }
    }

    public func performShuffleLibrary() async throws {
        try await requireSession()
        let tracks = try store.randomTracks()
        guard !tracks.isEmpty else { throw AppActionError.emptyLibrary }
        deliver(tracks, from: .songs, shuffled: false)   // already in random order
    }

    public func performTogglePlayback() async throws {
        await start()
        if remote.isControllingRemote {
            remote.send(.togglePlayPause)
            return
        }
        guard player.nowPlaying != nil else { throw AppActionError.nothingPlaying }
        player.togglePlayPause()
    }

    /// Next or previous track, for the Now Playing widget.
    public func performSkip(forward: Bool) async throws {
        await start()
        if remote.isControllingRemote {
            remote.send(forward ? .next : .previous)
            return
        }
        guard case .track = player.nowPlaying else { throw AppActionError.nothingPlaying }
        forward ? player.next() : player.previous()
    }

    /// Plays a saved station by its ID, for the Stations widget.
    public func performPlayStation(id: String) async throws {
        guard let station = try store.savedStations().first(where: { $0.id == id }) else {
            throw AppActionError.notFound("station")
        }
        await performPlayStation(station)
    }

    /// Returns "Title by Artist", or nil when there was no match.
    public func performIdentifySong() async throws -> String? {
        await start()
        guard !remote.isControllingRemote else { throw AppActionError.identifyNeedsLocalPlayback }
        guard player.isPlaying else { throw AppActionError.nothingPlaying }
        guard case .station = player.nowPlaying else { throw AppActionError.identifyNeedsRadio }
        guard identification != .listening else { throw AppActionError.identifyBusy }
        await identifyCurrentSong()
        switch identification {
        case .found(let match, _):
            return match.artist.map { "\(match.title) by \($0)" } ?? match.title
        case .failed(let message):
            throw NSError(domain: "Identify", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        default:
            return nil
        }
    }
}
