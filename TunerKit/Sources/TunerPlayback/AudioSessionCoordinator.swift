#if os(iOS) || os(tvOS)
import AVFoundation

/// Configures the shared audio session for long-form playback and maps interruptions and
/// route changes onto the player.
@MainActor
public final class AudioSessionCoordinator {
    private weak var player: PlayerController?
    private var observers: [NSObjectProtocol] = []
    private var resumeAfterInterruption = false

    public init(player: PlayerController) {
        self.player = player
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init) ?? []
            MainActor.assumeIsolated { self?.handleInterruption(type: type, options: options) }
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

    private func handleInterruption(type: AVAudioSession.InterruptionType?, options: AVAudioSession.InterruptionOptions) {
        guard let player else { return }
        switch type {
        case .began:
            resumeAfterInterruption = player.isPlaying
            if player.isPlaying { player.pause() }
        case .ended:
            if resumeAfterInterruption, options.contains(.shouldResume) {
                activate()
                player.resume()
            }
            resumeAfterInterruption = false
        default:
            break
        }
    }
}
#endif
