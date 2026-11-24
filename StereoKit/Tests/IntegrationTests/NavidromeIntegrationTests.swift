import AVFoundation
import Foundation
import Testing
import StereoModel
@testable import SubsonicClient
@testable import StereoPlayback
@testable import StereoStore

/// End-to-end tests against a real Navidrome, run with:
///
///     STEREO_IT_URL=http://127.0.0.1:4599 STEREO_IT_USER=stereo STEREO_IT_PASS=stereopass swift test --filter IntegrationTests
///
/// They expect the synthetic library from `scripts/make-test-library.sh`:
/// "Continuous Sweep" (4 gapless FLAC tracks), "Plain Tones" (3 FLAC), "Ágætis Tones" (3 MP3).
private let env = ProcessInfo.processInfo.environment
private let enabled = env["STEREO_IT_URL"] != nil

private func makeLibrary() -> SubsonicLibrary {
    SubsonicLibrary(configuration: ServerConfiguration(
        name: "IT",
        urls: [URL(string: "http://192.0.2.1:9")!, URL(string: env["STEREO_IT_URL"]!)!],  // first URL is unroutable: exercises failover
        username: env["STEREO_IT_USER"] ?? "stereo",
        credential: .password(env["STEREO_IT_PASS"] ?? "stereopass")
    ))
}

@Suite(.enabled(if: enabled), .serialized)
struct NavidromeIntegrationTests {
    @Test func signInAndCapabilities() async throws {
        let lib = makeLibrary()
        try await lib.verify()
        #expect(await lib.resolver.current?.port == URL(string: env["STEREO_IT_URL"]!)!.port)
        let caps = try await lib.capabilities()
        print("capabilities:", caps)
        #expect(caps.contains(.syncedLyrics))
    }

    @Test func wrongPasswordIsAnAuthError() async throws {
        let bad = SubsonicLibrary(configuration: ServerConfiguration(
            name: "IT", urls: [URL(string: env["STEREO_IT_URL"]!)!], username: "stereo", credential: .password("nope")))
        do {
            try await bad.verify()
            Issue.record("expected failure")
        } catch let error as SubsonicError {
            #expect(error.isAuthenticationFailure)
        }
    }

    @Test func fullSyncIndexesEverything() async throws {
        let store = try LibraryStore.inMemory()
        try await LibrarySyncer(source: makeLibrary(), store: store).sync(force: true)
        let counts = try store.counts()
        #expect(counts.albums == 3)
        #expect(counts.tracks == 10)
        #expect(counts.artists == 2)

        let sweep = try #require(try store.search("continuous sweep").albums.first)
        let detail = try #require(try store.album(sweep.id))
        #expect(detail.tracks.map(\.trackNumber) == [1, 2, 3, 4])
        let t1 = detail.tracks[0]
        #expect(t1.format.codec == "flac")
        #expect(t1.replayGain.trackGain == -4.5)
        #expect(t1.replayGain.albumGain == -5.0)
        #expect(t1.duration == .seconds(12))
        // Diacritic-insensitive local search over server data (á→a; note æ is a letter, not a diacritic).
        #expect(try store.search("agætis").albums.count == 1)
    }

    @Test func realFLACAlbumPlaysGaplessly() async throws {
        let lib = makeLibrary()
        let store = try LibraryStore.inMemory()
        try await LibrarySyncer(source: lib, store: store).sync(force: true)
        let sweep = try #require(try store.search("continuous sweep").albums.first)
        let tracks = try #require(try store.album(sweep.id)).tracks

        let cacheDir = FileManager.default.temporaryDirectory.appending(path: "stereo-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let resolver = LibraryTrackResolver(library: lib, cache: TrackCache(directory: cacheDir), quality: { .original })
        let f1 = try await resolver.localFile(for: tracks[0])
        let f2 = try await resolver.localFile(for: tracks[1])
        // Second resolve is a cache hit (same file, no download).
        #expect(try await resolver.localFile(for: tracks[0]) == f1)

        // Expected: both files decoded and concatenated.
        func decode(_ url: URL) throws -> [Float] {
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buf)
            return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
        }
        let expected = try decode(f1) + decode(f2)
        #expect(expected.count == 2 * 12 * 44_100)

        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let player = AudioEnginePlayer(manualRenderingFormat: fmt, buffersAhead: 1000, chunkFrames: 4096)
        player.play(EngineItem(id: "1", fileURL: f1), at: 0)
        player.setNext(EngineItem(id: "2", fileURL: f2))
        _ = player.currentItemID

        var rendered: [Float] = []
        let out = AVAudioPCMBuffer(pcmFormat: player.engine.manualRenderingFormat, frameCapacity: 4096)!
        while rendered.count < expected.count {
            let n = min(AVAudioFrameCount(expected.count - rendered.count), 4096)
            guard try player.engine.renderOffline(n, to: out) == .success else { break }
            rendered += UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))
        }
        let maxError = zip(rendered, expected).map { abs($0 - $1) }.max() ?? 1
        #expect(rendered.count == expected.count)
        #expect(maxError < 1e-5, "deviation \(maxError) across the FLAC track boundary")

        // And the boundary itself is smooth: the sample step there is like any other.
        let boundary = 12 * 44_100
        let step = abs(rendered[boundary] - rendered[boundary - 1])
        let typical = (1..<1000).map { abs(rendered[$0] - rendered[$0 - 1]) }.max()!
        #expect(step <= typical * 1.5)
    }

    @Test func streamedFLACFromServerIsGaplessAndCachesItself() async throws {
        let lib = makeLibrary()
        let store = try LibraryStore.inMemory()
        try await LibrarySyncer(source: lib, store: store).sync(force: true)
        let sweep = try #require(try store.search("continuous sweep").albums.first)
        let tracks = try #require(try store.album(sweep.id)).tracks

        let cacheDir = FileManager.default.temporaryDirectory.appending(path: "stereo-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let cache = TrackCache(directory: cacheDir)
        let resolver = LibraryTrackResolver(library: lib, cache: cache, quality: { .original })
        let s1 = try await resolver.playbackSource(for: tracks[2])
        let s2 = try await resolver.playbackSource(for: tracks[3])
        guard case .stream = s1, case .stream = s2 else { Issue.record("expected streams with an empty cache"); return }

        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let player = AudioEnginePlayer(manualRenderingFormat: fmt, buffersAhead: 1000, chunkFrames: 4096)
        player.play(EngineItem(id: "3", source: s1), at: 0)
        player.setNext(EngineItem(id: "4", source: s2))
        try await Task.sleep(for: .seconds(1.5))   // offline rendering doesn't wait for the network
        player.drain()

        var rendered: [Float] = []
        let out = AVAudioPCMBuffer(pcmFormat: player.engine.manualRenderingFormat, frameCapacity: 4096)!
        while rendered.count < 2 * 12 * 44_100 {
            guard try player.engine.renderOffline(4096, to: out) == .success else { break }
            rendered += UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))
        }
        let boundary = 12 * 44_100
        let step = abs(rendered[boundary] - rendered[boundary - 1])
        let typical = (1..<2000).map { abs(rendered[$0] - rendered[$0 - 1]) }.max()!
        #expect(rendered.count >= 2 * 12 * 44_100)
        #expect(step <= typical * 1.5, "click/gap at streamed boundary: \(step) vs \(typical)")

        // Both streams finished downloading, so they're now cache hits.
        try await Task.sleep(for: .milliseconds(300))
        if case .file = try await resolver.playbackSource(for: tracks[2]) {} else { Issue.record("track 3 not cached after streaming") }
        if case .file = try await resolver.playbackSource(for: tracks[3]) {} else { Issue.record("track 4 not cached after streaming") }
    }

    @Test func transcodedStreamDownloadsAndDecodes() async throws {
        let lib = makeLibrary()
        let album = try #require(try await lib.albums(.alphabeticalByName, page: .init()).items.first { $0.name == "Plain Tones" })
        let track = try #require(try await lib.album(album.id).tracks.first)
        let cacheDir = FileManager.default.temporaryDirectory.appending(path: "stereo-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let resolver = LibraryTrackResolver(library: lib, cache: TrackCache(directory: cacheDir),
                                            quality: { .transcoded(format: "aac", maxBitRate: 128) })
        let url = try await resolver.localFile(for: track)
        let file = try AVAudioFile(forReading: url)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        print("transcoded:", url.lastPathComponent, file.fileFormat, seconds, "s")
        #expect(abs(seconds - 12) < 0.5)
    }

    @Test func starScrobbleAndPlayQueueRoundTrip() async throws {
        let lib = makeLibrary()
        let album = try #require(try await lib.albums(.alphabeticalByName, page: .init()).items.first { $0.name == "Plain Tones" })
        let tracks = try await lib.album(album.id).tracks

        try await lib.setStarred(true, .track(tracks[0].id))
        #expect(try await lib.album(album.id).tracks[0].starred != nil)
        try await lib.setStarred(false, .track(tracks[0].id))
        #expect(try await lib.album(album.id).tracks[0].starred == nil)

        try await lib.report(.nowPlaying(tracks[1].id))
        try await lib.report(.played(tracks[1].id, at: Date()))
        #expect((try await lib.album(album.id).tracks[1].playCount ?? 0) >= 1)

        try await lib.savePlayQueue(tracks.map(\.id), current: tracks[2].id, position: .milliseconds(4_250))
        let saved = try #require(try await lib.loadPlayQueue())
        #expect(saved.tracks.map(\.id) == tracks.map(\.id))
        #expect(saved.current == tracks[2].id)
        #expect(saved.position == .milliseconds(4_250))
        #expect(saved.changedBy == "Stereo")
    }

    @Test func coverArtIsServed() async throws {
        let lib = makeLibrary()
        let album = try #require(try await lib.albums(.newest, page: .init()).items.first)
        let url = try await lib.coverArtURL(try #require(album.coverArtID), size: 300)
        let (data, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(data.count > 500)
    }
}
