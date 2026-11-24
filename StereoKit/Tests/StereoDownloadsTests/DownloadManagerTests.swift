import Foundation
import Testing
import StereoModel
import StereoStore
@testable import StereoDownloads

private let src = SourceID("nav")
private func iid(_ raw: String) -> ItemID { ItemID(source: src, raw: raw) }

private func makeTrack(_ raw: String, album: String = "al1") -> Track {
    Track(id: iid(raw), title: "Track \(raw)", artist: "Artist", album: "Album", albumID: iid(album),
          trackNumber: 1, duration: .seconds(100), format: AudioFormat(codec: "flac"))
}

/// In-memory library whose albums/playlists can change between calls.
actor StubSource: DownloadSource {
    var albums: [ItemID: AlbumDetail] = [:]
    var playlists: [ItemID: PlaylistDetail] = [:]

    func setAlbum(_ raw: String, tracks: [String]) {
        let id = iid(raw)
        albums[id] = AlbumDetail(album: Album(id: id, name: "Album \(raw)", artist: "Artist", coverArtID: "c-\(raw)"),
                                 tracks: tracks.map { makeTrack($0, album: raw) })
    }

    func setPlaylist(_ raw: String, tracks: [String]) {
        let id = iid(raw)
        playlists[id] = PlaylistDetail(playlist: Playlist(id: id, name: "Playlist \(raw)"), tracks: tracks.map { makeTrack($0) })
    }

    func album(_ id: ItemID) async throws -> AlbumDetail {
        guard let a = albums[id] else { throw URLError(.fileDoesNotExist) }
        return a
    }

    func playlist(_ id: ItemID) async throws -> PlaylistDetail {
        guard let p = playlists[id] else { throw URLError(.fileDoesNotExist) }
        return p
    }

    func downloadRequest(for track: ItemID) async throws -> URLRequest {
        URLRequest(url: URL(string: "https://stub.example/rest/download?id=\(track.raw)")!)
    }

    func streamRequest(for track: ItemID, quality: StreamQuality, offset: Duration?) async throws -> URLRequest {
        guard case .transcoded(let format, let rate) = quality else { return try await downloadRequest(for: track) }
        return URLRequest(url: URL(string: "https://stub.example/rest/stream?id=\(track.raw)&format=\(format)&maxBitRate=\(rate)")!)
    }
}

/// Writes "audio-<id>" to a temp file. Can fail the first N attempts per track, or hang.
final class StubTransport: DownloadTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var failuresLeft: [String: Int] = [:]
    private var _concurrent = 0
    private var _maxConcurrent = 0
    var delay: Duration = .zero
    let staging = FileManager.default.temporaryDirectory.appending(path: "stereo-dl-staging-\(UUID().uuidString)")

    init() { try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true) }

    var requests: [URLRequest] { lock.withLock { _requests } }
    var maxConcurrent: Int { lock.withLock { _maxConcurrent } }
    func fail(_ raw: String, times: Int) { lock.withLock { failuresLeft["id=\(raw)"] = times } }

    func download(_ request: URLRequest, tag: String, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        let url = request.url!.absoluteString
        let shouldFail: Bool = lock.withLock {
            _requests.append(request)
            _concurrent += 1
            _maxConcurrent = max(_maxConcurrent, _concurrent)
            guard let key = failuresLeft.keys.first(where: { url.contains($0 + "&") || url.hasSuffix($0) }),
                  let n = failuresLeft[key], n > 0 else { return false }
            failuresLeft[key] = n - 1
            return true
        }
        defer { lock.withLock { _concurrent -= 1 } }
        if delay > .zero { try await Task.sleep(for: delay) }
        if shouldFail { throw URLError(.networkConnectionLost) }
        let body = Data("audio-\(tag)".utf8)
        progress(Int64(body.count / 2), Int64(body.count))
        let file = staging.appending(path: UUID().uuidString)
        try body.write(to: file)
        progress(Int64(body.count), Int64(body.count))
        return file
    }

    func activeTags() async -> Set<String> { [] }
}

private struct Harness {
    let store: LibraryStore
    let source = StubSource()
    let transport = StubTransport()
    let dir = FileManager.default.temporaryDirectory.appending(path: "stereo-dl-\(UUID().uuidString)")
    let manager: DownloadManager

    init(retryDelays: [Duration] = [.milliseconds(10), .milliseconds(10)], maxConcurrent: Int = 3) throws {
        store = try LibraryStore.inMemory()
        manager = DownloadManager(source: source, store: store, directory: dir, transport: transport,
                                  maxConcurrent: maxConcurrent, retryDelays: retryDelays)
    }

    func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path())) ?? []).sorted()
    }
}

/// Bounded wait so a bug fails the test instead of hanging the run.
private func idle(_ m: DownloadManager, timeout: Duration = .seconds(5)) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await m.waitUntilIdle() }
        group.addTask { try await Task.sleep(for: timeout); throw CancellationError() }
        try await group.next()
        group.cancelAll()
    }
}

@Suite struct DownloadManagerTests {
    @Test func pinAlbumDownloadsEveryTrackAndResolverFindsThem() async throws {
        let h = try Harness()
        await h.source.setAlbum("al1", tracks: ["t1", "t2", "t3"])
        await h.manager.start()
        try await h.manager.pin(album: iid("al1"), quality: .original)
        try await idle(h.manager)

        #expect(h.files().count == 3)
        #expect(h.files().allSatisfy { $0.hasSuffix(".flac") })
        let progress = try #require(try h.store.pinProgress(.album(iid("al1"))))
        #expect(progress.total == 3 && progress.done == 3 && progress.isComplete)
        #expect(try h.store.downloadStats().files == 3)

        let lookup = h.manager.pinnedLookup
        let file = try #require(await lookup(iid("t2")))
        #expect(try String(contentsOf: file, encoding: .utf8) == "audio-nav:t2")
        #expect(await lookup(iid("nope")) == nil)
        // The album is browsable offline afterwards.
        #expect(try h.store.album(iid("al1"))?.tracks.count == 3)
        #expect(h.transport.requests.allSatisfy { $0.url!.path().hasSuffix("/rest/download") })
    }

    @Test func respectsConcurrencyLimit() async throws {
        let h = try Harness(maxConcurrent: 3)
        h.transport.delay = .milliseconds(30)
        await h.source.setAlbum("al1", tracks: (1...10).map { "t\($0)" })
        await h.manager.start()
        try await h.manager.pin(album: iid("al1"), quality: .original)
        try await idle(h.manager)
        #expect(h.files().count == 10)
        #expect(h.transport.maxConcurrent <= 3)
        #expect(h.transport.maxConcurrent >= 2)
    }

    @Test func transcodedPinUsesStreamEndpoint() async throws {
        let h = try Harness()
        await h.source.setAlbum("al1", tracks: ["t1"])
        await h.manager.start()
        try await h.manager.pin(album: iid("al1"), quality: .transcoded(format: "aac", maxBitRate: 256))
        try await idle(h.manager)
        let url = try #require(h.transport.requests.first?.url?.absoluteString)
        #expect(url.contains("/rest/stream") && url.contains("format=aac") && url.contains("maxBitRate=256"))
        #expect(h.files().first?.hasSuffix(".aac") == true)
        #expect(try h.store.pin(for: .album(iid("al1")))?.quality == "aac@256")
    }

    @Test func unpinDeletesFilesButKeepsTracksOtherPinsNeed() async throws {
        let h = try Harness()
        await h.source.setAlbum("al1", tracks: ["t1", "t2"])
        await h.source.setPlaylist("pl1", tracks: ["t2", "t9"])
        await h.manager.start()
        try await h.manager.pin(album: iid("al1"), quality: .original)
        try await h.manager.pin(playlist: iid("pl1"), quality: .original)
        try await idle(h.manager)
        #expect(h.files().count == 3)   // t2 is shared, downloaded once

        try await h.manager.unpin(.album(iid("al1")))
        #expect(h.files().count == 2)
        #expect(h.manager.localFile(for: iid("t1")) == nil)
        #expect(h.manager.localFile(for: iid("t2")) != nil)   // still needed by the playlist
        #expect(try h.store.pinProgress(.album(iid("al1"))) == nil)

        try await h.manager.unpin(.playlist(iid("pl1")))
        #expect(h.files().isEmpty)
        #expect(try h.store.pins().isEmpty)
    }

    @Test func transientFailureRetriesThenSucceeds() async throws {
        let h = try Harness(retryDelays: [.milliseconds(20), .milliseconds(20)])
        h.transport.fail("t1", times: 2)
        await h.source.setAlbum("al1", tracks: ["t1"])
        await h.manager.start()
        try await h.manager.pin(album: iid("al1"), quality: .original)
        try await idle(h.manager)
        let entry = try #require(try h.store.downloadEntry(iid("t1")))
        #expect(entry.state == .done)
        #expect(entry.attempts == 2)
        #expect(h.transport.requests.count == 3)
    }

    @Test func persistentFailureEndsFailedAndCanBeRetried() async throws {
        let h = try Harness(retryDelays: [.milliseconds(10)])
        h.transport.fail("t1", times: 2)
        await h.source.setAlbum("al1", tracks: ["t1", "t2"])
        await h.manager.start()
        try await h.manager.pin(album: iid("al1"), quality: .original)
        try await idle(h.manager)
        #expect(try h.store.downloadEntry(iid("t1"))?.state == .failed)
        #expect(try h.store.downloadEntry(iid("t1"))?.error != nil)
        #expect(try h.store.downloadEntry(iid("t2"))?.state == .done)
        #expect(try h.store.pinProgress(.album(iid("al1")))?.failed == 1)

        await h.manager.retryFailed()
        try await idle(h.manager)
        #expect(try h.store.downloadEntry(iid("t1"))?.state == .done)
    }

    @Test func refreshPicksUpNewTracksAndDropsRemovedOnes() async throws {
        let h = try Harness()
        await h.source.setAlbum("al1", tracks: ["t1", "t2"])
        await h.manager.start()
        try await h.manager.pin(album: iid("al1"), quality: .original)
        try await idle(h.manager)

        await h.source.setAlbum("al1", tracks: ["t2", "t3"])   // t1 removed on the server, t3 added
        await h.manager.refreshPins()
        try await idle(h.manager)

        #expect(h.manager.localFile(for: iid("t1")) == nil)
        #expect(h.manager.localFile(for: iid("t3")) != nil)
        #expect(h.files().count == 2)
        #expect(try h.store.pinnedTrackIDs(.album(iid("al1"))) == [iid("t2"), iid("t3")])
    }

    @Test func deleteAllClearsEverything() async throws {
        let h = try Harness()
        await h.source.setAlbum("al1", tracks: ["t1", "t2"])
        await h.manager.start()
        try await h.manager.pin(album: iid("al1"), quality: .original)
        try await idle(h.manager)
        #expect(h.manager.totalBytes() > 0)
        await h.manager.deleteAll()
        #expect(h.files().isEmpty)
        #expect(h.manager.totalBytes() == 0)
        #expect(try h.store.pins().isEmpty)
    }

    @Test func noSourcePausesUntilConnected() async throws {
        let h = try Harness()
        await h.source.setAlbum("al1", tracks: ["t1"])
        await h.manager.start()
        try await h.manager.pin(album: iid("al1"), quality: .original)
        try await idle(h.manager)
        await h.manager.setSource(nil)
        await #expect(throws: DownloadError.noSource) { try await h.manager.pin(album: iid("al1"), quality: .original) }
    }

    @Test func interruptedDownloadsRequeueOnStart() async throws {
        let h = try Harness()
        try h.store.savePin(Pin(owner: .track(iid("t1")), name: "x", quality: "original"),
                            tracks: [PinnedTrack(trackID: iid("t1"), relativePath: "t1.flac")])
        try h.store.updateDownload(iid("t1"), .started)   // as if the app died mid-transfer
        await h.manager.start()
        try await idle(h.manager)
        #expect(try h.store.downloadEntry(iid("t1"))?.state == .done)
    }

    @Test func progressStreamReportsCompletion() async throws {
        let h = try Harness()
        await h.source.setAlbum("al1", tracks: ["t1"])
        await h.manager.start()
        let stream = await h.manager.progressUpdates()
        try await h.manager.pin(album: iid("al1"), quality: .original)
        var sawDone = false
        for await p in stream where p.trackID == iid("t1") && p.state == .done {
            sawDone = true
            break
        }
        #expect(sawDone)
    }

    @Test func parsesSubsonicErrorEnvelopes() {
        let json = Data(#"{"subsonic-response":{"status":"failed","error":{"code":70,"message":"data not found"}}}"#.utf8)
        let xml = Data(#"<subsonic-response status="failed"><error code="70" message="data not found"></error></subsonic-response>"#.utf8)
        #expect(URLSessionDownloadTransport.subsonicErrorMessage(json) == "data not found")
        #expect(URLSessionDownloadTransport.subsonicErrorMessage(xml) == "data not found")
        #expect(URLSessionDownloadTransport.subsonicErrorMessage(Data("fLaC".utf8)) == nil)
    }

    @Test func qualityKeysRoundTrip() {
        #expect(DownloadQuality.key(.original) == "original")
        #expect(DownloadQuality.key(.transcoded(format: "mp3", maxBitRate: 320)) == "mp3@320")
        #expect(DownloadQuality.quality(fromKey: "aac@256") == .transcoded(format: "aac", maxBitRate: 256))
        #expect(DownloadQuality.quality(fromKey: "garbage") == .original)
    }
}
