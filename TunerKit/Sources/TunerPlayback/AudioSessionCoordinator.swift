#if os(iOS) || os(tvOS)
import AVFoundation

/// Configures the shared audio session for long-form playback and maps interruptions and
/// route changes onto the player.
///
/// iOS 27 splits interruptions into "the session became inactive" and a later "resumption
/// recommendation"; we pause on the first and resume only when the system recommends it.
@MainActor
public final class AudioSessionCoordinator {
    private weak var player: PlayerController?
    private var observers: [NSObjectProtocol] = []
    private var resumeWhenRecommended = false

    public init(player: PlayerController) {
        self.player = player
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionBecameInactive() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.resumptionRecommendationNotification, object: session, queue: .main) { [weak self] note in
            let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
            let shouldResume = context?.recommendation == .shouldResume
            MainActor.assumeIsolated { self?.resumptionRecommended(shouldResume) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated {
                // Headphones unplugged: pause, as every iOS player does.
                if reason == .oldDeviceUnavailable { self?.player?.pause() }
            }
        })
    }

    public func activate() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func sessionBecameInactive() {
        guard let player else { return }
        resumeWhenRecommended = player.isPlaying
        if player.isPlaying { player.pause() }
    }

    private func resumptionRecommended(_ shouldResume: Bool) {
        defer { resumeWhenRecommended = false }
        guard resumeWhenRecommended, shouldResume, let player else { return }
        activate()
        player.resume()
    }
}
#endif
