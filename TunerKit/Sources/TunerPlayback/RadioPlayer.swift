import AVFoundation
import TunerModel

/// Interim radio player on AVPlayer. It handles Icecast/Shoutcast (ICY titles arrive as timed
/// metadata) and HLS. In M3 non-HLS streams move into `AudioEnginePlayer` through `ICYDemuxer`,
/// so ShazamKit can match the PCM directly; AVPlayer stays as the HLS fallback.
@MainActor
public final class RadioPlayer: NSObject {
    public enum Event: Sendable, Equatable {
        case playing
        case buffering
        case paused
        case title(String)
        case failed(String)
    }

    public private(set) var station: Station?
    public var onEvent: ((Event) -> Void)?

    private let player = AVPlayer()
    private var metadataOutput: AVPlayerItemMetadataOutput?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?

    public override init() {
        super.init()
        player.automaticallyWaitsToMinimizeStalling = true
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            MainActor.assumeIsolated {
                switch status {
                case .playing: self?.onEvent?(.playing)
                case .waitingToPlayAtSpecifiedRate: self?.onEvent?(.buffering)
                case .paused: self?.onEvent?(.paused)
                @unknown default: break
                }
            }
        }
    }

    public func play(_ station: Station, url: URL? = nil) {
        stop()
        self.station = station
        let item = AVPlayerItem(url: url ?? station.streamURL)
        let output = AVPlayerItemMetadataOutput(identifiers: nil)
        output.setDelegate(self, queue: .main)
        item.add(output)
        metadataOutput = output
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed
            let message = item.error?.localizedDescription ?? "Stream failed"
            MainActor.assumeIsolated {
                if failed { self?.onEvent?(.failed(message)) }
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }

    public func pause() { player.pause() }

    /// Live radio can't really resume; reconnect to the live edge instead.
    public func resume() {
        guard let station else { return }
        play(station)
    }

    public func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObservation = nil
        metadataOutput = nil
        station = nil
    }

    public var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }
}

extension RadioPlayer: AVPlayerItemMetadataOutputPushDelegate {
    nonisolated public func metadataOutput(
        _ output: AVPlayerItemMetadataOutput,
        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
        from track: AVPlayerItemTrack?
    ) {
        // Timed ICY metadata is already loaded, so the synchronous accessor doesn't block.
        let titles: [String] = groups.flatMap(\.items).compactMap { item in
            let isTitle = item.identifier == .icyMetadataStreamTitle || item.commonKey == .commonKeyTitle
            guard isTitle, let value = item.stringValue, !value.isEmpty else { return nil }
            return value
        }
        guard !titles.isEmpty else { return }
        Task { @MainActor in
            for title in titles { self.onEvent?(.title(title)) }
        }
    }
}
