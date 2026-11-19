import Foundation
import Observation
import TunerModel
import TunerPlayback
import TunerRemote

/// Adapts `PlayerController` to `RemotePlaybackHost` using only its public API.
@MainActor
final class PlayerRemoteHost: RemotePlaybackHost {
    let player: PlayerController
    private var preparedStation: Station?
    private var preparedQueue = false

    init(player: PlayerController) { self.player = player }

    // MARK: State

    func currentState() -> RemoteState {
        let p = player
        let queue = p.queue
        let status: RemoteStatus = switch p.status {
        case .idle: .idle
        case .loading: .loading
        case .playing: .playing
        case .paused: .paused
        case .buffering: .buffering
        }
        let isTrack: Bool = { if case .track = p.nowPlaying { true } else { false } }()
        return RemoteState(
            item: p.nowPlaying.map(RemoteItem.init),
            status: status,
            anchor: PositionAnchor(position: p.position, rate: p.status == .playing && isTrack ? 1 : 0),
            duration: p.duration,
            volume: p.volume,
            upNext: Array(queue.upNext.prefix(RemoteState.windowSize)),
            remaining: Array(queue.remainingContext.prefix(RemoteState.windowSize)),
            shuffle: queue.isShuffled,
            repeatMode: queue.repeatMode,
            streamTitle: p.streamTitle?.raw,
            contextName: Self.name(of: queue.contextSource)
        )
    }

    func stateChanges() -> AsyncStream<RemoteState> {
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteState.self, bufferingPolicy: .bufferingNewest(1))
        let active = ActiveFlag()
        continuation.onTermination = { _ in active.isActive = false }
        observe(continuation, active)
        return stream
    }

    private func observe(_ continuation: AsyncStream<RemoteState>.Continuation, _ active: ActiveFlag) {
        guard active.isActive else { return }
        withObservationTracking {
            _ = currentState()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, active.isActive else { return }
                continuation.yield(self.currentState())
                self.observe(continuation, active)
            }
        }
    }

    // MARK: Commands

    func apply(_ command: RemoteCommand) {
        switch command {
        case .play: player.resume()
        case .pause: player.pause()
        case .togglePlayPause: player.togglePlayPause()
        case .seek(let t): player.seek(to: t)
        case .next: player.next()
        case .previous: player.previous()
        case .setQueue(let tracks, let start, let shuffled): player.play(tracks, startAt: start, shuffled: shuffled)
        case .enqueue(let tracks, let next): next ? player.playNext(tracks) : player.addToQueue(tracks)
        case .playStation(let s): player.play(s)
        case .setVolume(let v): player.volume = min(max(v, 0), 1)
        case .setShuffle(let on): player.setShuffle(on)
        case .setRepeat(let mode): setRepeat(mode)
        }
    }

    private func setRepeat(_ mode: RepeatMode) {
        player.setRepeat(mode)
    }

    // MARK: Handoff

    func queueSnapshot() -> QueueSnapshot? {
        let q = player.queue
        switch player.nowPlaying {
        case .track(let current):
            // Flatten to play order (current, Up Next, rest) so the target needs no shuffle state.
            return QueueSnapshot(content: .tracks([current] + q.upNext + q.remainingContext, currentIndex: 0),
                                 position: player.position, shuffle: q.isShuffled, repeatMode: q.repeatMode,
                                 volume: player.volume, contextName: Self.name(of: q.contextSource))
        case .station(let s):
            return QueueSnapshot(content: .station(s), position: 0, volume: player.volume)
        case nil:
            return nil
        }
    }

    func prepareTransfer(_ snapshot: QueueSnapshot) async throws {
        switch snapshot.content {
        case .station(let s):
            preparedStation = s
        case .tracks(let tracks, let index):
            guard tracks.indices.contains(index) else { throw RemoteError.transferFailed("Empty queue") }
            do {
                // Loaded paused at the exact position; nothing is heard until commit.
                try await player.prepare(tracks, startAt: index, position: snapshot.position, repeatMode: snapshot.repeatMode)
            } catch {
                throw RemoteError.transferFailed(error.localizedDescription)
            }
            preparedQueue = true
        }
        player.volume = snapshot.volume
    }

    func commitTransfer() {
        if let station = preparedStation {
            preparedStation = nil
            player.play(station)
        } else if preparedQueue {
            preparedQueue = false
            player.resume()
        }
    }

    func cancelTransfer() {
        preparedStation = nil
        if preparedQueue {
            preparedQueue = false
            player.stop()
        }
    }

    func stopForTransfer() async {
        let original = player.volume
        // ~300 ms fade, then stop. The queue stays here so "play" resumes locally if wanted.
        for step in 1...6 {
            player.volume = original * Float(6 - step) / 6
            try? await Task.sleep(for: .milliseconds(50))
        }
        if case .station = player.nowPlaying { player.stop() } else { player.pause() }
        player.volume = original
    }

    private static func name(of context: QueueContext?) -> String? {
        switch context {
        case .album(_, let n), .playlist(_, let n), .artist(_, let n): n
        default: nil
        }
    }
}

private final class ActiveFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    var isActive: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
