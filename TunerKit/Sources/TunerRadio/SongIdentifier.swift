import AVFoundation
import Foundation
import os
import ShazamKit
import TunerPlayback

/// Identifies whatever is playing by feeding the engine's own PCM to ShazamKit — no microphone,
/// no permission prompt, works with headphones and in noisy rooms.
///
/// Needs the ShazamKit app service enabled for the App ID in the developer portal.
@MainActor
public final class SongIdentifier {
    public struct Match: Sendable, Equatable {
        public var title: String
        public var artist: String?
        public var artworkURL: URL?
        public var appleMusicURL: URL?
        public var isrc: String?
    }

    public enum IdentifyError: LocalizedError {
        case noAudio
        public var errorDescription: String? { "Nothing is playing through Tuner's engine." }
    }

    private let log = Logger(subsystem: "app.tuner", category: "shazam")

    public init() {}

    /// Listens for up to `timeout`. Returns nil if ShazamKit found nothing.
    public func identify(from tap: AudioTapHost?, timeout: Duration = .seconds(12)) async throws -> Match? {
        guard let tap else { throw IdentifyError.noAudio }
        let feeder = ShazamFeeder(session: SHSession())
        tap.installTap { buffer, time in feeder.feed(buffer, time: time) }
        defer { tap.removeTap() }
        return try await Self.firstMatch(feeder, timeout: timeout)
    }

    private nonisolated static func firstMatch(_ feeder: ShazamFeeder, timeout: Duration) async throws -> Match? {
        try await withThrowingTaskGroup(of: Match?.self) { group in
            group.addTask {
                for await result in feeder.session.results {
                    switch result {
                    case .match(let match):
                        guard let item = match.mediaItems.first else { continue }
                        return Match(title: item.title ?? "Unknown", artist: item.artist, artworkURL: item.artworkURL,
                                     appleMusicURL: item.appleMusicURL, isrc: item.isrc)
                    case .noMatch:
                        continue   // streaming matching keeps trying as more audio arrives
                    case .error(let error, _):
                        throw error
                    }
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// Converts tapped engine buffers to mono 44.1 kHz float (a format ShazamKit accepts) and streams
/// them into the session. Runs on the audio tap thread.
final class ShazamFeeder: @unchecked Sendable {
    let session: SHSession
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    init(session: SHSession) { self.session = session }

    func feed(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        if sourceFormat != buffer.format {
            sourceFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        let status = converter.convert(to: out, error: nil) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return }
        session.matchStreamingBuffer(out, at: nil)
    }
}
