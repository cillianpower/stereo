import Foundation
import StereoModel

public enum ReplayGainMode: String, Codable, Sendable, CaseIterable {
    case off
    case track
    case album
    /// Album gain when playing an album in order, track gain otherwise (shuffle, playlists).
    case auto
}

public struct ReplayGainSettings: Hashable, Codable, Sendable {
    public var mode: ReplayGainMode
    /// Extra gain applied on top of the tag value (dB). ReplayGain targets −18 LUFS; many people add a few dB.
    public var preampDB: Double
    /// Gain applied to files with no ReplayGain tags (dB).
    public var fallbackDB: Double
    /// Reduce gain so `peak × gain ≤ 1` and the signal never clips.
    public var preventClipping: Bool

    public init(mode: ReplayGainMode = .auto, preampDB: Double = 0, fallbackDB: Double = -6, preventClipping: Bool = true) {
        self.mode = mode
        self.preampDB = preampDB
        self.fallbackDB = fallbackDB
        self.preventClipping = preventClipping
    }
}

public enum GainCalculator {
    /// Linear gain multiplier for a track.
    /// - Parameter albumContext: true when the track is playing as part of its album in order.
    public static func linearGain(for rg: ReplayGain, settings: ReplayGainSettings, albumContext: Bool) -> Float {
        let useAlbum: Bool
        switch settings.mode {
        case .off: return 1
        case .track: useAlbum = false
        case .album: useAlbum = true
        case .auto: useAlbum = albumContext
        }

        let tagGain = useAlbum ? (rg.albumGain ?? rg.trackGain) : (rg.trackGain ?? rg.albumGain)
        let peak = useAlbum ? (rg.albumPeak ?? rg.trackPeak) : (rg.trackPeak ?? rg.albumPeak)
        let db = (tagGain ?? settings.fallbackDB) + settings.preampDB
        var linear = pow(10, db / 20)
        if settings.preventClipping, let peak, peak > 0 {
            linear = min(linear, 1 / peak)
        }
        return Float(linear)
    }
}
