import AVFoundation
import Foundation
import Testing
import SubsonicClient
import TunerModel
import TunerStore
@testable import TunerDownloads

/// Real Navidrome + real URLSession transport. Skipped unless TUNER_IT_URL is set, e.g.
///     TUNER_IT_URL=http://127.0.0.1:4599 swift test --filter DownloadIntegrationTests
private let env = ProcessInfo.processInfo.environment

@Suite(.enabled(if: env["TUNER_IT_URL"] != nil), .serialized)
struct DownloadIntegrationTests {
    private func library() -> SubsonicLibrary {
        SubsonicLibrary(configuration: ServerConfiguration(
            name: "IT", urls: [URL(string: env["TUNER_IT_URL"]!)!],
            username: env["TUNER_IT_USER"] ?? "tuner", credential: .password(env["TUNER_IT_PASS"] ?? "tunerpass")))
    }

    private func run(quality: StreamQuality, expectedExtension: String) async throws {
        let lib = library()
        let album = try #require(try await lib.albums(.alphabeticalByName, page: .init()).items.first { $0.name == "Plain Tones" })
        let root = FileManager.default.temporaryDirectory.appending(path: "tuner-dl-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore.inMemory()
        let transport = URLSessionDownloadTransport(configuration: .ephemeral, staging: root.appending(path: "staging"))
        let manager = DownloadManager(source: lib, store: store, directory: root.appending(path: "Downloads"),
                                      transport: transport, retryDelays: [.milliseconds(200)])
        await manager.start()
        try await manager.pin(album: album.id, quality: quality)
        await manager.waitUntilIdle()

        let progress = try #require(try store.pinProgress(.album(album.id)))
        #expect(progress.total == 3)
        let failures = try store.downloadEntries(state: .failed).map { $0.error ?? "" }
        #expect(progress.done == 3, "failed: \(failures)")

        for id in try store.pinnedTrackIDs(.album(album.id)) {
            let file = try #require(manager.localFile(for: id))
            #expect(file.pathExtension == expectedExtension)
            let audio = try AVAudioFile(forReading: file)
            let seconds = Double(audio.length) / audio.processingFormat.sampleRate
            #expect(abs(seconds - 12) < 0.5)
        }
        #expect(manager.totalBytes() > 0)
        try await manager.unpin(.album(album.id))
        #expect(try FileManager.default.contentsOfDirectory(atPath: manager.directory.path()).isEmpty)
    }

    @Test func pinPlainTonesOriginals() async throws {
        try await run(quality: .original, expectedExtension: "flac")
    }

    @Test func pinPlainTonesAsAAC() async throws {
        try await run(quality: .transcoded(format: "aac", maxBitRate: 128), expectedExtension: "aac")
    }

    @Test func badTrackIDFailsWithServerMessage() async throws {
        let lib = library()
        let root = FileManager.default.temporaryDirectory.appending(path: "tuner-dl-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore.inMemory()
        let manager = DownloadManager(
            source: lib, store: store, directory: root.appending(path: "Downloads"),
            transport: URLSessionDownloadTransport(configuration: .ephemeral, staging: root.appending(path: "staging")),
            retryDelays: [])
        await manager.start()
        let bogus = Track(id: ItemID(source: lib.id, raw: "does-not-exist"), title: "Ghost", format: AudioFormat(codec: "flac"))
        try await manager.pin(track: bogus, quality: .original)
        await manager.waitUntilIdle()
        let entry = try #require(try store.downloadEntry(bogus.id))
        #expect(entry.state == .failed)
        #expect(entry.error == "data not found")
        #expect(manager.localFile(for: bogus.id) == nil)
    }
}
