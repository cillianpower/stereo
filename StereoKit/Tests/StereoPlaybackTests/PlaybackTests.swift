import AVFoundation
import Foundation
import Testing
import StereoModel
@testable import StereoPlayback

@Suite struct ICYDemuxerTests {
    private func icyStream(interval: Int, blocks: [(audio: [UInt8], meta: String?)]) -> Data {
        var data = Data()
        for block in blocks {
            precondition(block.audio.count == interval)
            data.append(contentsOf: block.audio)
            if let meta = block.meta {
                var bytes = Array(meta.utf8)
                let padded = (bytes.count + 15) / 16 * 16
                bytes += [UInt8](repeating: 0, count: padded - bytes.count)
                data.append(UInt8(padded / 16))
                data.append(contentsOf: bytes)
            } else {
                data.append(0)
            }
        }
        return data
    }

    @Test func separatesAudioAndMetadataAcrossArbitraryChunks() {
        let interval = 16
        let a = [UInt8](repeating: 1, count: interval)
        let b = [UInt8](repeating: 2, count: interval)
        let c = [UInt8](repeating: 3, count: interval)
        let stream = icyStream(interval: interval, blocks: [
            (a, "StreamTitle='Daft Punk - Veridis Quo';StreamUrl='';"),
            (b, nil),
            (c, "StreamTitle='It's a title; with punctuation';"),
        ])

        // Feed in awkward chunk sizes to exercise every state boundary.
        for chunkSize in [1, 3, 7, 16, 17, 1000] {
            var demuxer = ICYDemuxer(metaInterval: interval)
            var audio = Data()
            var meta: [[String: String]] = []
            var i = 0
            while i < stream.count {
                let out = demuxer.consume(stream.subdata(in: i..<min(i + chunkSize, stream.count)))
                audio.append(out.audio)
                meta += out.metadata
                i += chunkSize
            }
            #expect(audio == Data(a + b + c), "chunk \(chunkSize)")
            #expect(meta.count == 2)
            #expect(meta.first?["StreamTitle"] == "Daft Punk - Veridis Quo")
            #expect(meta.first?["StreamUrl"] == "")
            #expect(meta.last?["StreamTitle"] == "It's a title; with punctuation")
        }
    }

    @Test func latin1Fallback() {
        var block = Data("StreamTitle='Bj".utf8)
        block.append(0xF6)  // ö in Latin-1, invalid as UTF-8
        block.append(contentsOf: Array("rk - J".utf8))
        block.append(0xF3)
        block.append(contentsOf: Array("ga';".utf8))
        #expect(ICYDemuxer.parse(block)["StreamTitle"] == "Björk - Jóga")
    }
}

@Suite struct GainTests {
    let rg = ReplayGain(trackGain: -6, trackPeak: 0.9, albumGain: -8, albumPeak: 0.95)

    @Test func modes() {
        let track = GainCalculator.linearGain(for: rg, settings: .init(mode: .track), albumContext: true)
        let album = GainCalculator.linearGain(for: rg, settings: .init(mode: .album), albumContext: false)
        #expect(abs(track - 0.501) < 0.001)
        #expect(abs(album - 0.398) < 0.001)
        #expect(GainCalculator.linearGain(for: rg, settings: .init(mode: .off), albumContext: true) == 1)
        #expect(GainCalculator.linearGain(for: rg, settings: .init(mode: .auto), albumContext: true) == album)
        #expect(GainCalculator.linearGain(for: rg, settings: .init(mode: .auto), albumContext: false) == track)
    }

    @Test func clippingPrevention() {
        let loud = ReplayGain(trackGain: +6, trackPeak: 0.8)
        let g = GainCalculator.linearGain(for: loud, settings: .init(mode: .track, preventClipping: true), albumContext: false)
        #expect(abs(g - 1.25) < 0.0001)  // capped at 1/peak, not 10^(6/20) ≈ 2
    }

    @Test func fallbackForUntaggedFiles() {
        let g = GainCalculator.linearGain(for: ReplayGain(), settings: .init(mode: .track, fallbackDB: -6), albumContext: false)
        #expect(abs(g - 0.501) < 0.001)
    }
}

/// Renders the real engine offline and checks the output sample by sample.
@Suite(.serialized) struct GaplessEngineTests {
    static let rate = 44_100.0
    static let frequency = 441.0   // 100 samples per cycle

    static func sine(_ n: Int, startFrame: Int) -> [Float] {
        (0..<n).map { Float(0.5 * sin(2 * .pi * frequency * Double(startFrame + $0) / rate)) }
    }

    /// Writes a stereo float WAV containing frames [start, start+count) of a continuous sine.
    static func writeSine(to url: URL, start: Int, count: Int) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        let samples = sine(count, startFrame: start)
        for ch in 0..<2 { samples.withUnsafeBufferPointer { buffer.floatChannelData![ch].update(from: $0.baseAddress!, count: count) } }
        try file.write(from: buffer)
    }

    static func render(_ player: AudioEnginePlayer, frames total: Int) throws -> [Float] {
        let engine = player.engine
        let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)!
        var result: [Float] = []
        while result.count < total {
            let n = min(AVAudioFrameCount(total - result.count), out.frameCapacity)
            let status = try engine.renderOffline(n, to: out)
            guard status == .success else { break }
            let ptr = out.floatChannelData![0]
            result += UnsafeBufferPointer(start: ptr, count: Int(out.frameLength))
        }
        return result
    }

    func tmp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "stereo-tests-\(UUID().uuidString)-\(name).wav")
    }

    func makePlayer() -> AudioEnginePlayer {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2)!
        // Schedule far ahead so the whole test fits up front; offline rendering doesn't wait for callbacks.
        return AudioEnginePlayer(manualRenderingFormat: fmt, buffersAhead: 1000, chunkFrames: 4096)
    }

    @Test func consecutiveFilesAreSampleContinuous() async throws {
        // Split at a frame that isn't on a buffer or cycle boundary.
        let split = 30_001, total = 60_000
        let a = tmp("a"), b = tmp("b")
        try Self.writeSine(to: a, start: 0, count: split)
        try Self.writeSine(to: b, start: split, count: total - split)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }

        let player = makePlayer()
        player.play(EngineItem(id: "a", fileURL: a), at: 0)
        player.setNext(EngineItem(id: "b", fileURL: b))
        _ = player.currentItemID  // barrier: queue.sync

        let rendered = try Self.render(player, frames: total)
        let expected = Self.sine(total, startFrame: 0)
        #expect(rendered.count == total)
        let maxError = zip(rendered, expected).map { abs($0 - $1) }.max() ?? 1
        #expect(maxError < 1e-5, "max deviation \(maxError) — a gap or a click at the boundary")
    }

    @Test func reportsAdvanceThenEnd() async throws {
        let a = tmp("a"), b = tmp("b")
        try Self.writeSine(to: a, start: 0, count: 10_000)
        try Self.writeSine(to: b, start: 10_000, count: 10_000)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }

        let player = makePlayer()
        var iterator = player.events.makeAsyncIterator()
        player.play(EngineItem(id: "a", fileURL: a), at: 0)
        player.setNext(EngineItem(id: "b", fileURL: b))
        _ = player.currentItemID

        _ = try Self.render(player, frames: 12_000)
        player.tickSync()
        #expect(player.currentItemID == "b")
        #expect(player.currentTime > 0.03 && player.currentTime < 0.06)

        _ = try Self.render(player, frames: 9_000)
        player.tickSync()

        var events: [EngineEvent] = []
        for _ in 0..<5 { if let e = await iterator.next() { events.append(e) } }
        #expect(events == [.playingChanged(true), .started(id: "a"), .advanced(id: "b"), .playingChanged(false), .ended])
    }

    @Test func appliesGain() async throws {
        let a = tmp("a")
        try Self.writeSine(to: a, start: 0, count: 8_000)
        defer { try? FileManager.default.removeItem(at: a) }

        let player = makePlayer()
        player.play(EngineItem(id: "a", fileURL: a, gain: 0.5), at: 0)
        _ = player.currentItemID
        let rendered = try Self.render(player, frames: 8_000)
        let expected = Self.sine(8_000, startFrame: 0).map { $0 * 0.5 }
        let maxError = zip(rendered, expected).map { abs($0 - $1) }.max() ?? 1
        #expect(maxError < 1e-5)
    }

    @Test func seekStartsAtOffset() async throws {
        let a = tmp("a")
        try Self.writeSine(to: a, start: 0, count: 44_100)
        defer { try? FileManager.default.removeItem(at: a) }

        let player = makePlayer()
        player.play(EngineItem(id: "a", fileURL: a), at: 0.5)
        _ = player.currentItemID
        let rendered = try Self.render(player, frames: 1000)
        let expected = Self.sine(1000, startFrame: 22_050)
        let maxError = zip(rendered, expected).map { abs($0 - $1) }.max() ?? 1
        #expect(maxError < 1e-5)
    }
}
