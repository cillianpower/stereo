import CoreGraphics
import Foundation
import ImageIO
import os
import Testing
import UniformTypeIdentifiers
@testable import StereoUI

@Suite struct ArtworkPipelineTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "artwork-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writePNG(to url: URL, side: Int = 700) throws {
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.8, green: 0.2, blue: 0.4, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func cachedArtSurvivesARestartWithoutTheNetwork() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appending(path: "source.png")
        try writePNG(to: source)
        let first = ArtworkPipeline(directory: directory.appending(path: "cache"))
        #expect(await first.image(key: "a", size: 300) { source } != nil)

        try FileManager.default.removeItem(at: source)
        let restarted = ArtworkPipeline(directory: directory.appending(path: "cache"))
        #expect(restarted.cachedImage(key: "a", size: 300) == nil)
        #expect(await restarted.image(key: "a", size: 300) { nil } != nil)
        #expect(restarted.cachedImage(key: "a", size: 300) != nil)
    }

    @Test func memoryServesALargerSizeInstantly() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appending(path: "source.png")
        try writePNG(to: source)
        let pipeline = ArtworkPipeline(directory: directory.appending(path: "cache"))
        _ = await pipeline.image(key: "a", size: 600) { source }
        #expect(pipeline.cachedImage(key: "a", size: 300)?.width == 600)
        #expect(pipeline.cachedImage(key: "a", size: 1200) == nil)
    }

    @Test func simultaneousRequestsShareOneLoad() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appending(path: "source.png")
        try writePNG(to: source)
        let pipeline = ArtworkPipeline(directory: directory.appending(path: "cache"))
        let calls = OSAllocatedUnfairLock(initialState: 0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    let image = await pipeline.image(key: "a", size: 300) {
                        calls.withLock { $0 += 1 }
                        try? await Task.sleep(for: .milliseconds(40))
                        return source
                    }
                    #expect(image != nil)
                }
            }
        }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func aCancelledLoadCanBeRequestedAgain() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appending(path: "source.png")
        try writePNG(to: source)
        let pipeline = ArtworkPipeline(directory: directory.appending(path: "cache"))
        let abandoned = Task {
            await pipeline.image(key: "a", size: 300) {
                try? await Task.sleep(for: .seconds(5))
                return source
            }
        }
        try await Task.sleep(for: .milliseconds(40))
        abandoned.cancel()
        _ = await abandoned.value
        try await Task.sleep(for: .milliseconds(40))
        #expect(await pipeline.image(key: "a", size: 300) { source } != nil)
    }

    @Test func limiterCapsConcurrencyAndFavoursTheNewestWaiter() async throws {
        let limiter = AsyncLimiter(limit: 1)
        #expect(await limiter.acquire())
        let order = OSAllocatedUnfairLock(initialState: [Int]())
        let waiters = (0..<3).map { index in
            Task {
                try? await Task.sleep(for: .milliseconds(20 * (index + 1)))
                if await limiter.acquire() {
                    order.withLock { $0.append(index) }
                    await limiter.release()
                }
            }
        }
        try await Task.sleep(for: .milliseconds(140))
        #expect(order.withLock { $0 }.isEmpty)
        await limiter.release()
        for waiter in waiters { await waiter.value }
        #expect(order.withLock { $0 } == [2, 1, 0])
    }

    @Test func diskTrimRemovesTheOldestFiles() throws {
        let directory = try temporaryDirectory()
        for index in 0..<4 {
            let file = directory.appending(path: "file\(index)")
            try Data(repeating: 1, count: 100).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index) * 1000)],
                                                  ofItemAtPath: file.path(percentEncoded: false))
        }
        ArtworkPipeline.trimDisk(directory, limit: 300)
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).sorted()
        #expect(left == ["file2", "file3"])
    }
}
