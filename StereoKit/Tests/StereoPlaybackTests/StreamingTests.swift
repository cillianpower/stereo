import AVFoundation
import Foundation
import os
import Testing
@testable import StereoPlayback

/// Serves registered byte blobs over a fake HTTP, in small throttled chunks, with Range support
/// and optional ICY metadata interleaving — enough to exercise real streaming code paths.
final class StubHTTP: URLProtocol, @unchecked Sendable {
    struct Resource {
        var data: Data
        var contentType: String
        var chunk = 8 * 1024
        var delay: TimeInterval = 0.001
        var icyInterval: Int?
        var icyTitles: [String] = []
        var acceptRanges = true
    }

    nonisolated(unsafe) static var resources: [String: Resource] = [:]
    nonisolated(unsafe) static var log: [(url: String, range: String?)] = []
    static let lock = NSLock()

    static func register(_ path: String, _ r: Resource) -> URL {
        lock.withLock { resources[path] = r }
        return URL(string: "stub://media\(path)")!
    }

    static var configuration: URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubHTTP.self]
        return c
    }

    private let stoppedLock = NSLock()
    private var _stopped = false
    private var stopped: Bool {
        get { stoppedLock.withLock { _stopped } }
        set { stoppedLock.withLock { _stopped = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme == "stub" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let range = request.value(forHTTPHeaderField: "Range")
        Self.lock.withLock { Self.log.append((url.path(), range)) }
        guard let res = Self.lock.withLock({ Self.resources[url.path()] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist)); return
        }
        var start = 0
        var status = 200
        var headers = ["Content-Type": res.contentType]
        if res.acceptRanges { headers["Accept-Ranges"] = "bytes" }
        if let range, res.acceptRanges, let n = Int(range.dropFirst("bytes=".count).split(separator: "-").first ?? "") {
            start = n
            status = 206
            headers["Content-Range"] = "bytes \(n)-\(res.data.count - 1)/\(res.data.count)"
        }
        var body = res.data.subdata(in: start..<res.data.count)
        if let interval = res.icyInterval {
            headers["icy-metaint"] = String(interval)
            body = Self.interleave(body, interval: interval, titles: res.icyTitles)
        } else {
            headers["Content-Length"] = String(body.count)
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        let client = self.client
        DispatchQueue.global().async { [self] in
            var offset = 0
            while offset < body.count, !stopped {
                let end = min(offset + res.chunk, body.count)
                client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
                offset = end
                if res.delay > 0 { Thread.sleep(forTimeInterval: res.delay) }
            }
            if !stopped { client?.urlProtocolDidFinishLoading(self) }
        }
    }

    override func stopLoading() { stopped = true }

    static func interleave(_ audio: Data, interval: Int, titles: [String]) -> Data {
        var out = Data()
        var i = 0, block = 0
        while i < audio.count {
            let end = min(i + interval, audio.count)
            out.append(audio.subdata(in: i..<end))
            i = end
            if end - (end - interval) == interval, i <= audio.count {
                if block < titles.count {
                    var bytes = Array("StreamTitle='\(titles[block])';".utf8)
                    let padded = (bytes.count + 15) / 16 * 16
                    bytes += [UInt8](repeating: 0, count: padded - bytes.count)
                    out.append(UInt8(padded / 16)); out.append(contentsOf: bytes)
                } else {
                    out.append(0)
                }
                block += 1
            }
        }
        return out
    }
}

private func fixture(_ name: String) -> URL {
    Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
}

private let format44 = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

/// Reference decode through AVAudioFile (which applies the file's own gapless trimming).
private func decodeFile(_ url: URL, from seconds: TimeInterval = 0) throws -> [Float] {
    let d = try FileDecoder(item: EngineItem(id: "ref", fileURL: url), url: url, outputFormat: format44, startAt: seconds)
    var out: [Float] = []
    while let b = try d.readBuffer(frames: 8192) { out += UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)) }
    return out
}

/// Pulls a StreamDecoder to completion on its own queue, waiting for data as needed.
private func decodeStream(_ url: URL, hint: String, from seconds: TimeInterval = 0) async throws -> [Float] {
    let queue = DispatchQueue(label: "test.stream")
    let item = EngineItem(id: "s", source: .stream(StreamSpec(request: URLRequest(url: url), typeHint: hint, expectedDuration: 3)))
    guard case .stream(let spec) = item.source else { fatalError() }
    let decoder = try queue.sync {
        try StreamDecoder(item: item, spec: spec, outputFormat: format44, startAt: seconds, queue: queue, configuration: StubHTTP.configuration)
    }
    var out: [Float] = []
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        let result = try queue.sync { try decoder.read(frames: 8192) }
        switch result {
        case .buffer(let b): out += UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength))
        case .wait: try await Task.sleep(for: .milliseconds(5))
        case .end: return out
        }
    }
    Issue.record("stream decode timed out")
    return out
}

private func maxDiff(_ a: [Float], _ b: [Float]) -> Float {
    zip(a, b).map { abs($0 - $1) }.max() ?? .infinity
}

@Suite(.serialized) struct StreamDecoderTests {
    @Test func flacStreamMatchesFileDecodeExactly() async throws {
        let url = StubHTTP.register("/a.flac", .init(data: try Data(contentsOf: fixture("sweep1.flac")), contentType: "audio/flac"))
        let streamed = try await decodeStream(url, hint: "flac")
        let reference = try decodeFile(fixture("sweep1.flac"))
        #expect(streamed.count == reference.count)
        #expect(maxDiff(streamed, reference) < 1e-6)
    }

    @Test func aacM4AStreamTrimsPrimingLikeAVAudioFile() async throws {
        let url = StubHTTP.register("/a.m4a", .init(data: try Data(contentsOf: fixture("sweep1.m4a")), contentType: "audio/mp4"))
        let streamed = try await decodeStream(url, hint: "m4a")
        let reference = try decodeFile(fixture("sweep1.m4a"))
        print("aac streamed \(streamed.count) reference \(reference.count)")
        #expect(abs(streamed.count - reference.count) <= 1)
        #expect(maxDiff(streamed, reference) < 1e-3)
    }

    @Test func mp3StreamLengthMatchesFile() async throws {
        let url = StubHTTP.register("/a.mp3", .init(data: try Data(contentsOf: fixture("sweep1.mp3")), contentType: "audio/mpeg"))
        let streamed = try await decodeStream(url, hint: "mp3")
        let reference = try decodeFile(fixture("sweep1.mp3"))
        print("mp3 streamed \(streamed.count) reference \(reference.count) (source 132300)")
        #expect(abs(streamed.count - reference.count) <= 1152)
        #expect(!streamed.isEmpty)
    }

    /// Best alignment between `a` and `b` within ±`window` frames: (lag, max deviation). Positive lag = `a` starts later.
    static func align(_ a: [Float], _ b: [Float], window: Int, compare n: Int = 4000) -> (lag: Int, error: Float) {
        var best = (lag: 0, error: Float.infinity)
        for lag in -window...window {
            let aa = lag < 0 ? Array(a.dropFirst(-lag).prefix(n)) : Array(a.prefix(n))
            let bb = lag > 0 ? Array(b.dropFirst(lag).prefix(n)) : Array(b.prefix(n))
            guard aa.count == n, bb.count == n else { continue }
            let e = maxDiff(aa, bb)
            if e < best.error { best = (lag, e) }
        }
        return best
    }

    @Test func seekIntoFLACStream() async throws {
        let url = StubHTTP.register("/seek.flac", .init(data: try Data(contentsOf: fixture("sweep1.flac")), contentType: "audio/flac"))
        let streamed = try await decodeStream(url, hint: "flac", from: 1.5)
        let reference = try decodeFile(fixture("sweep1.flac"), from: 1.5)
        let (lag, error) = Self.align(streamed, reference, window: 4410)   // ±100 ms
        print("seek streamed \(streamed.count) reference \(reference.count) lag \(lag) error \(error)")
        // Clean audio from (within 100 ms of) the requested point — no garbage after the jump.
        #expect(error < 1e-5)
        #expect(abs(lag) <= 4410)
    }

    @Test func seekBeyondDownloadedUsesRangeRequest() async throws {
        let data = try Data(contentsOf: fixture("sweep1.flac"))
        // Slow delivery: 2 KB every 20 ms, so seeking to 2.5 s outruns the download.
        let url = StubHTTP.register("/slow.flac", .init(data: data, contentType: "audio/flac", chunk: 2048, delay: 0.02))
        StubHTTP.lock.withLock { StubHTTP.log.removeAll() }
        let streamed = try await decodeStream(url, hint: "flac", from: 2.5)
        let ranges = StubHTTP.lock.withLock { StubHTTP.log.filter { $0.url == "/slow.flac" }.compactMap(\.range) }
        print("range requests: \(ranges)")
        #expect(!ranges.isEmpty)
        #expect(abs(Double(streamed.count) / 44_100 - 0.5) < 0.15)
    }

    @Test func completedDownloadIsHandedToCache() async throws {
        let url = StubHTTP.register("/cache.flac", .init(data: try Data(contentsOf: fixture("sweep1.flac")), contentType: "audio/flac"))
        let stored = OSAllocatedUnfairLock<URL?>(initialState: nil)
        let completion = StreamCompletion { tmp in
            let dest = FileManager.default.temporaryDirectory.appending(path: "cached-\(UUID().uuidString).flac")
            try? FileManager.default.moveItem(at: tmp, to: dest)
            stored.withLock { $0 = dest }
            return dest
        }
        let queue = DispatchQueue(label: "test.cache")
        let item = EngineItem(id: "c", source: .stream(StreamSpec(request: URLRequest(url: url), typeHint: "flac", completion: completion)))
        guard case .stream(let spec) = item.source else { return }
        let decoder = try queue.sync { try StreamDecoder(item: item, spec: spec, outputFormat: format44, startAt: 0, queue: queue, configuration: StubHTTP.configuration) }
        for _ in 0..<500 {
            if completion.finalURL != nil { break }
            _ = try queue.sync { try decoder.read(frames: 8192) }
            try await Task.sleep(for: .milliseconds(5))
        }
        let final = try #require(completion.finalURL)
        #expect(try Data(contentsOf: final) == Data(contentsOf: fixture("sweep1.flac")))
        try? FileManager.default.removeItem(at: final)
    }
}

@Suite(.serialized) struct StreamingEngineTests {
    func render(_ player: AudioEnginePlayer, frames total: Int) throws -> [Float] {
        let out = AVAudioPCMBuffer(pcmFormat: player.engine.manualRenderingFormat, frameCapacity: 4096)!
        var result: [Float] = []
        while result.count < total {
            let n = min(AVAudioFrameCount(total - result.count), 4096)
            guard try player.engine.renderOffline(n, to: out) == .success else { break }
            result += UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))
        }
        return result
    }

    @Test func twoStreamedFLACTracksAreGapless() async throws {
        let u1 = StubHTTP.register("/g1.flac", .init(data: try Data(contentsOf: fixture("sweep1.flac")), contentType: "audio/flac"))
        let u2 = StubHTTP.register("/g2.flac", .init(data: try Data(contentsOf: fixture("sweep2.flac")), contentType: "audio/flac"))
        let expected = try decodeFile(fixture("sweep1.flac")) + decodeFile(fixture("sweep2.flac"))

        let player = AudioEnginePlayer(manualRenderingFormat: format44, buffersAhead: 1000, chunkFrames: 4096,
                                       streamConfiguration: StubHTTP.configuration)
        player.play(EngineItem(id: "1", source: .stream(StreamSpec(request: URLRequest(url: u1), typeHint: "flac"))), at: 0)
        player.setNext(EngineItem(id: "2", source: .stream(StreamSpec(request: URLRequest(url: u2), typeHint: "flac"))))
        // Offline rendering doesn't wait for the network, so let both streams arrive first.
        try await Task.sleep(for: .milliseconds(800))
        player.drain()

        let rendered = try render(player, frames: expected.count)
        #expect(rendered.count == expected.count)
        #expect(maxDiff(rendered, expected) < 1e-5, "gap or click between streamed tracks")
    }

    @Test func gaplessAcrossAACTracks() async throws {
        // AAC in M4A carries priming/remainder in its packet table; trimming must make the join seamless.
        let u1 = StubHTTP.register("/g1.m4a", .init(data: try Data(contentsOf: fixture("sweep1.m4a")), contentType: "audio/mp4"))
        let u2 = StubHTTP.register("/g2.m4a", .init(data: try Data(contentsOf: fixture("sweep2.m4a")), contentType: "audio/mp4"))
        let reference = try decodeFile(fixture("sweep1.m4a")) + decodeFile(fixture("sweep2.m4a"))

        let player = AudioEnginePlayer(manualRenderingFormat: format44, buffersAhead: 1000, chunkFrames: 4096,
                                       streamConfiguration: StubHTTP.configuration)
        player.play(EngineItem(id: "1", source: .stream(StreamSpec(request: URLRequest(url: u1), typeHint: "m4a"))), at: 0)
        player.setNext(EngineItem(id: "2", source: .stream(StreamSpec(request: URLRequest(url: u2), typeHint: "m4a"))))
        try await Task.sleep(for: .milliseconds(800))
        player.drain()
        let rendered = try render(player, frames: reference.count)
        let boundary = 132_300
        // Largest sample step near the join vs. elsewhere: a gap shows up as a big jump.
        func maxStep(_ r: Range<Int>) -> Float { r.map { abs(rendered[$0] - rendered[$0 - 1]) }.max() ?? 0 }
        let joinStep = maxStep((boundary - 50)..<(boundary + 50))
        let typical = maxStep(10_000..<20_000)
        print("aac join step \(joinStep) typical \(typical); len \(rendered.count) vs \(reference.count)")
        #expect(joinStep <= typical * 1.5)
    }

    @Test func liveICYStreamDecodesAndReportsTitles() async throws {
        let mp3 = try Data(contentsOf: fixture("sweep1.mp3"))
        let url = StubHTTP.register("/live", .init(data: mp3, contentType: "audio/mpeg", icyInterval: 8000,
                                                  icyTitles: ["Artist One - Song A", "Artist Two - Song B"]))
        let player = AudioEnginePlayer(manualRenderingFormat: format44, buffersAhead: 1000, chunkFrames: 4096,
                                       streamConfiguration: StubHTTP.configuration)
        var events = player.events.makeAsyncIterator()
        player.play(EngineItem(id: "radio", source: .stream(StreamSpec(request: URLRequest(url: url), typeHint: "mp3", isLive: true))), at: 0)
        try await Task.sleep(for: .milliseconds(600))
        player.drain()
        let rendered = try render(player, frames: 44_100)
        #expect(rendered.contains { abs($0) > 0.1 }, "no audio decoded from live stream")

        var titles: [String] = []
        for _ in 0..<6 {
            guard let e = await events.next() else { break }
            if case .streamMetadata(_, let t) = e { titles.append(t) }
            if titles.count == 2 { break }
        }
        #expect(titles == ["Artist One - Song A", "Artist Two - Song B"])
    }
}
