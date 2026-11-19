import Foundation
import Observation
import TunerModel
import TunerPlayback

/// User preferences, persisted to UserDefaults. (Moves to NSUbiquitousKeyValueStore with iCloud.)
@MainActor
@Observable
public final class AppSettings {
    public enum QualityOption: String, CaseIterable, Identifiable, Codable, Sendable {
        case original, aac320, aac256, aac128, mp3320, mp3192
        // Opus/Ogg returns once the decoder spike (decision 2) adds an Ogg decoder.
        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .original: "Original (lossless if available)"
            case .aac320: "AAC 320 kbps"
            case .aac256: "AAC 256 kbps"
            case .aac128: "AAC 128 kbps"
            case .mp3320: "MP3 320 kbps"
            case .mp3192: "MP3 192 kbps"
            }
        }

        public var quality: StreamQuality {
            switch self {
            case .original: .original
            case .aac320: .transcoded(format: "aac", maxBitRate: 320)
            case .aac256: .transcoded(format: "aac", maxBitRate: 256)
            case .aac128: .transcoded(format: "aac", maxBitRate: 128)
            case .mp3320: .transcoded(format: "mp3", maxBitRate: 320)
            case .mp3192: .transcoded(format: "mp3", maxBitRate: 192)
            }
        }
    }

    private let defaults: UserDefaults

    public var wifiQuality: QualityOption { didSet { save(wifiQuality.rawValue, "wifiQuality") } }
    public var cellularQuality: QualityOption { didSet { save(cellularQuality.rawValue, "cellularQuality") } }
    public var replayGainMode: ReplayGainMode { didSet { save(replayGainMode.rawValue, "replayGainMode") } }
    public var replayGainPreamp: Double { didSet { save(replayGainPreamp, "replayGainPreamp") } }
    public var cacheLimitGB: Int { didSet { save(cacheLimitGB, "cacheLimitGB") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        wifiQuality = defaults.string(forKey: "wifiQuality").flatMap(QualityOption.init) ?? .original
        cellularQuality = defaults.string(forKey: "cellularQuality").flatMap(QualityOption.init) ?? .aac256
        replayGainMode = defaults.string(forKey: "replayGainMode").flatMap(ReplayGainMode.init) ?? .auto
        replayGainPreamp = defaults.object(forKey: "replayGainPreamp") as? Double ?? 0
        cacheLimitGB = defaults.object(forKey: "cacheLimitGB") as? Int ?? 5
    }

    public var replayGainSettings: ReplayGainSettings {
        ReplayGainSettings(mode: replayGainMode, preampDB: replayGainPreamp)
    }

    private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }

    /// Keys mirrored to iCloud. The cache limit stays per device: storage differs between devices.
    public static let syncedKeys = ["wifiQuality", "cellularQuality", "replayGainMode", "replayGainPreamp"]

    /// Re-reads values after iCloud changed them in UserDefaults underneath us.
    public func reload() {
        let fresh = AppSettings(defaults: defaults)
        if wifiQuality != fresh.wifiQuality { wifiQuality = fresh.wifiQuality }
        if cellularQuality != fresh.cellularQuality { cellularQuality = fresh.cellularQuality }
        if replayGainMode != fresh.replayGainMode { replayGainMode = fresh.replayGainMode }
        if replayGainPreamp != fresh.replayGainPreamp { replayGainPreamp = fresh.replayGainPreamp }
    }
}
