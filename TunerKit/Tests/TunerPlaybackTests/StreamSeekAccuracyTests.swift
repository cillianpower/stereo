import AVFoundation
import Foundation
import Testing
@testable import TunerPlayback

/// Seeks in full-length, variable-bitrate files. The left channel's pitch encodes the time, so the
/// decoded audio itself shows where a seek landed. The right channel's noise level changes over
/// time so frame sizes vary as they do in real music, which breaks proportional byte estimates.
@Suite(.serialized) struct StreamSeekAccuracyTests {
    private static let rate = 44_100.0
    private static let duration = 120.0
    private static let output = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!

    private static func frequency(at time: Double) -> Double { 200 + time * 10 }

    private static func makeTrack(ext: String, settings: [String: Any]) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appending(path: "seek-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let block: AVAudioFrameCount = 4096
            let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: block)!
            buffer.frameLength = block
            var generator = SystemRandomNumberGenerator()
            var phase = 0.0
            var frame = 0
            while Double(frame) < duration * rate {
                let left = buffer.floatChannelData![0], right = buffer.floatChannelData![1]
                for i in 0..<Int(block) {
                    let t = Double(frame + i) / rate
                    phase += 2 * .pi * frequency(at: t) / rate
                    left[i] = Float(sin(phase) * 0.5)
                    // Loud noise in the first quarter, near silence after it.
                    let level: Float = t < duration / 4 ? 0.4 : 0.002
                    right[i] = Float.random(in: -level...level, using: &generator)
                }
                try file.write(from: buffer)
                frame += Int(block)
            }
        }
        return try Data(contentsOf: url)
    }

    /// Where the audio is, from the left channel's zero crossings.
    private static func measuredTime(_ samples: [Float]) -> Double {
        let window = samples.prefix(Int(rate / 2))
        var crossings = 0
        for (a, b) in zip(window, window.dropFirst()) where (a < 0) != (b < 0) { crossings += 1 }
        let hz = Double(crossings) / 2 / (Double(window.count) / rate)
        return (hz - 200) / 10 - 0.25   // the window's centre is 0.25 s past its start
    }

    private func landing(_ url: URL, hint: String, seconds: Double) async throws -> Double {
        let queue = DispatchQueue(label: "test.seek")
        let spec = StreamSpec(request: URLRequest(url: url), typeHint: hint, expectedDuration: Self.duration)
        let item = EngineItem(id: "seek", source: .stream(spec))
        let decoder = try queue.sync {
            try StreamDecoder(item: item, spec: spec, outputFormat: Self.output, startAt: seconds,
                              queue: queue, configuration: StubHTTP.configuration)
        }
        defer { queue.sync { decoder.cancel() } }
        var left: [Float] = []
        for _ in 0..<4000 where left.count < Int(Self.rate) {
            let result = try queue.sync { try decoder.read(frames: 8192) }
            switch result {
            case .buffer(let b): left += UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength))
            case .wait: try await Task.sleep(for: .milliseconds(5))
            case .end: return Self.measuredTime(left)
            }
        }
        return Self.measuredTime(left)
    }

    private func check(ext: String, hint: String, settings: [String: Any]) async throws {
        let data = try Self.makeTrack(ext: ext, settings: settings)
        let url = StubHTTP.register("/long.\(ext)", .init(data: data, contentType: "audio/\(hint)", chunk: 256 * 1024))
        for target in [10.0, 45.0, 90.0, 115.0] {
            let landed = try await landing(url, hint: hint, seconds: target)
            print("SEEK \(ext) \(data.count / 1024) KB target \(target) landed \(String(format: "%.2f", landed))")
            #expect(abs(landed - target) < 0.25, "\(ext): asked for \(target)s, landed at \(landed)s")
        }
    }

    private func collect(_ decoder: StreamDecoder, on queue: DispatchQueue) async throws -> Double {
        var left: [Float] = []
        for _ in 0..<4000 where left.count < Int(Self.rate) {
            switch try queue.sync(execute: { try decoder.read(frames: 8192) }) {
            case .buffer(let b): left += UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength))
            case .wait: try await Task.sleep(for: .milliseconds(5))
            case .end: return Self.measuredTime(left)
            }
        }
        return Self.measuredTime(left)
    }

    /// Scrubbing around one open stream: every landing is right, and few requests are made.
    @Test func repeatedSeeksInOneStream() async throws {
        let data = try Self.makeTrack(ext: "flac", settings: [
            AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: 2,
        ])
        let url = StubHTTP.register("/scrub.flac", .init(data: data, contentType: "audio/flac", chunk: 256 * 1024))
        StubHTTP.lock.withLock { StubHTTP.log.removeAll() }
        let queue = DispatchQueue(label: "test.scrub")
        let spec = StreamSpec(request: URLRequest(url: url), typeHint: "flac", expectedDuration: Self.duration)
        let item = EngineItem(id: "scrub", source: .stream(spec))
        let decoder = try queue.sync {
            try StreamDecoder(item: item, spec: spec, outputFormat: Self.output, startAt: 0,
                              queue: queue, configuration: StubHTTP.configuration)
        }
        defer { queue.sync { decoder.cancel() } }
        _ = try await collect(decoder, on: queue)
        for target in [90.0, 20.0, 60.0, 90.0, 0.5, 110.0] {
            #expect(queue.sync { decoder.seek(to: target) })
            let landed = try await collect(decoder, on: queue)
            print("SCRUB target \(target) landed \(String(format: "%.2f", landed))")
            #expect(abs(landed - target) < 0.25, "asked for \(target)s, landed at \(landed)s")
        }
        let requests = StubHTTP.lock.withLock { StubHTTP.log.filter { $0.url == "/scrub.flac" }.count }
        print("SCRUB requests \(requests)")
        #expect(requests < 40)
    }

    /// Resampling must reach the end of a file without an error or losing its last buffer.
    @Test func resampledFileDecodesToItsEnd() throws {
        let url = try #require(Bundle.module.url(forResource: "sweep1", withExtension: "flac", subdirectory: "Fixtures"))
        let source = try AVAudioFile(forReading: url)
        let seconds = Double(source.length) / source.processingFormat.sampleRate
        let output48k = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let item = EngineItem(id: "resample", source: .file(url))
        let decoder = try FileDecoder(item: item, url: url, outputFormat: output48k)
        var frames = 0
        while let buffer = try decoder.readBuffer(frames: 8192) { frames += Int(buffer.frameLength) }
        #expect(abs(Double(frames) / 48_000 - seconds) < 0.01)
    }

    @Test func flac() async throws {
        try await check(ext: "flac", hint: "flac", settings: [
            AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: 2,
        ])
    }

    @Test func aacInM4A() async throws {
        try await check(ext: "m4a", hint: "m4a", settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ])
    }
}
