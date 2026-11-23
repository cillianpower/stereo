import Foundation
import MediaPlayer
import Observation
import TunerModel
import TunerPlayback
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

/// Mirrors `PlayerController` into the system Now Playing info (Control Center, Lock Screen, media keys,
/// AirPods) and routes remote commands back to it.
@MainActor
public final class NowPlayingBridge {
    public typealias ArtworkURLProvider = @Sendable (PlayableItem) async -> URL?

    private let player: PlayerController
    private let artworkURL: ArtworkURLProvider
    private let center = MPNowPlayingInfoCenter.default()
    private var artworkTask: Task<Void, Never>?
    private var artworkKey: String?
    private var artwork: MPMediaItemArtwork?
    private var lastStatus: PlayerController.Status?
    private var lastItem: PlayableItem?
    private var lastTitle: StreamTitle?
    private var lastPositionPush: TimeInterval = -10

    public init(player: PlayerController, artworkURL: @escaping ArtworkURLProvider) {
        self.player = player
        self.artworkURL = artworkURL
        registerCommands()
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = player.nowPlaying
            _ = player.status
            _ = player.streamTitle
            _ = player.position
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
        update()
    }

    private func update() {
        let item = player.nowPlaying
        let changedItem = item != lastItem || player.streamTitle != lastTitle
        let changedStatus = player.status != lastStatus
        // Position only needs pushing on seeks; the system extrapolates from rate.
        let jumped = abs(player.position - lastPositionPush) > 2.5
        guard changedItem || changedStatus || jumped else {
            lastPositionPush = player.position
            return
        }
        lastItem = item
        lastTitle = player.streamTitle
        lastStatus = player.status
        lastPositionPush = player.position

        guard let item else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }

        var info: [String: Any] = [:]
        switch item {
        case .track(let t):
            info[MPMediaItemPropertyTitle] = t.title
            info[MPMediaItemPropertyArtist] = t.artist
            info[MPMediaItemPropertyAlbumTitle] = t.album
            if let d = player.duration { info[MPMediaItemPropertyPlaybackDuration] = d }
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.position
            info[MPNowPlayingInfoPropertyIsLiveStream] = false
            info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        case .station(let s):
            info[MPMediaItemPropertyTitle] = player.streamTitle?.title ?? s.name
            info[MPMediaItemPropertyArtist] = player.streamTitle?.artist ?? s.name
            info[MPMediaItemPropertyAlbumTitle] = s.name
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.status == .playing ? 1.0 : 0.0
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        center.playbackState = player.isPlaying ? .playing : .paused

        let commands = MPRemoteCommandCenter.shared()
        let isTrack: Bool = { if case .track = item { return true } else { return false } }()
        commands.nextTrackCommand.isEnabled = isTrack
        commands.previousTrackCommand.isEnabled = isTrack
        commands.changePlaybackPositionCommand.isEnabled = isTrack

        if changedItem { loadArtwork(for: item) }
    }

    private func loadArtwork(for item: PlayableItem) {
        let key: String = switch item {
        case .track(let t): t.coverArtID ?? t.id.description
        case .station(let s): s.id
        }
        guard key != artworkKey else { return }
        artworkKey = key
        artwork = nil
        artworkTask?.cancel()
        let provider = artworkURL
        artworkTask = Task { [weak self] in
            guard let url = await provider(item),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = PlatformImage(data: data), !Task.isCancelled else { return }
            let art = Self.makeArtwork(image)
            guard let self, self.artworkKey == key else { return }
            self.artwork = art
            var info = self.center.nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = art
            self.center.nowPlayingInfo = info
        }
    }

    /// Nonisolated on purpose: MediaPlayer calls the handler on its own queue, and a closure
    /// formed on the main actor would trap there.
    private nonisolated static func makeArtwork(_ image: PlatformImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func registerCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.player.resume(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.player.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.player.togglePlayPause(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.player.next(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.player.previous(); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.player.seek(to: e.positionTime)
            return .success
        }
    }
}
