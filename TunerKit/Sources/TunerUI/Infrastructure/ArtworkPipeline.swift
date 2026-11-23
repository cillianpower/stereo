import CryptoKit
import Foundation
import ImageIO
import SwiftUI

/// Loads, downsamples and caches artwork. Keys are stable IDs (cover art ID + size), not URLs,
/// because Subsonic URLs carry a fresh auth salt on every request and would never hit a URL cache.
///
/// Memory is checked synchronously so cached art appears on the first frame. Disk reads, decoding
/// and downloads run off the actor with limited concurrency, newest request first, and a request
/// is cancelled once no view is waiting for it, so fast scrolling doesn't build a backlog.
public actor ArtworkPipeline {
    public static let sizes = [120, 300, 600, 1200]
    static let diskLimitBytes: Int64 = 1_073_741_824

    private let directory: URL
    private nonisolated let memory = ArtworkMemoryCache()
    private let diskSlots = AsyncLimiter(limit: 4)
    private let networkSlots = AsyncLimiter(limit: 6)
    private var inFlight: [String: InFlight] = [:]

    private struct InFlight {
        let id: UUID
        let task: Task<CGImage?, Never>
        var waiters: Int
    }

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Task.detached(priority: .background) { Self.trimDisk(directory, limit: Self.diskLimitBytes) }
    }

    /// Rounds up to one of a few fixed sizes so different views share cache entries.
    public static func bucket(for points: CGFloat, scale: CGFloat) -> Int {
        let px = Int(points * scale)
        return sizes.first { $0 >= px } ?? sizes.last!
    }

    /// Art already in memory at this size or larger. Safe to call while drawing.
    public nonisolated func cachedImage(key: String, size: Int) -> CGImage? {
        memory.image(key: key, atLeast: size)
    }

    public func image(key: String, size: Int, url: @escaping @Sendable () async -> URL?) async -> CGImage? {
        if let hit = memory.image(key: key, atLeast: size) { return hit }
        let cacheKey = "\(key)@\(size)"
        let request: InFlight
        if var existing = inFlight[cacheKey] {
            existing.waiters += 1
            inFlight[cacheKey] = existing
            request = existing
        } else {
            request = start(cacheKey: cacheKey, key: key, size: size, url: url)
            inFlight[cacheKey] = request
        }
        let id = request.id
        return await withTaskCancellationHandler {
            await request.task.value
        } onCancel: {
            Task { await self.abandon(cacheKey, id: id) }
        }
    }

    private func start(cacheKey: String, key: String, size: Int, url: @escaping @Sendable () async -> URL?) -> InFlight {
        let id = UUID()
        let file = directory.appending(path: Self.fileName(cacheKey))
        let task = Task<CGImage?, Never>.detached(priority: .userInitiated) { [memory, diskSlots, networkSlots] in
            let image = await Self.load(file: file, size: size, url: url, disk: diskSlots, network: networkSlots)
            if let image, !Task.isCancelled { memory.insert(image, key: key, size: size) }
            await self.finish(cacheKey, id: id)
            return image
        }
        return InFlight(id: id, task: task, waiters: 1)
    }

    private func finish(_ cacheKey: String, id: UUID) {
        if inFlight[cacheKey]?.id == id { inFlight[cacheKey] = nil }
    }

    /// A view stopped waiting. With nobody left, the load is cancelled.
    private func abandon(_ cacheKey: String, id: UUID) {
        guard var request = inFlight[cacheKey], request.id == id else { return }
        request.waiters -= 1
        if request.waiters > 0 {
            inFlight[cacheKey] = request
        } else {
            inFlight[cacheKey] = nil
            request.task.cancel()
        }
    }

    private static func load(file: URL, size: Int, url: @Sendable () async -> URL?,
                             disk: AsyncLimiter, network: AsyncLimiter) async -> CGImage? {
        guard await disk.acquire() else { return nil }
        let local = (try? Data(contentsOf: file)).flatMap { decode($0, maxPixel: size) }
        if local != nil {
            // Marks it recently used for disk trimming.
            try? FileManager.default.setAttributes([.modificationDate: Date()],
                                                   ofItemAtPath: file.path(percentEncoded: false))
        }
        await disk.release()
        if let local { return local }

        guard !Task.isCancelled, await network.acquire() else { return nil }
        var image: CGImage?
        if let source = await url(), let (data, response) = try? await URLSession.shared.data(from: source),
           (response as? HTTPURLResponse)?.statusCode ?? 200 < 400, !Task.isCancelled {
            image = decode(data, maxPixel: size)
            if image != nil { try? data.write(to: file, options: .atomic) }
        }
        await network.release()
        return image
    }

    /// Deletes the least recently used files once the cache passes `limit`, down to 80% of it.
    static func trimDisk(_ directory: URL, limit: Int64) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        var entries = files.compactMap { url -> (url: URL, size: Int64, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: keys), let size = values.fileSize else { return nil }
            return (url, Int64(size), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > limit else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries where total > limit * 8 / 10 {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    static func fileName(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func decode(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Decoded images, limited by bytes rather than count. `NSCache` is thread-safe.
final class ArtworkMemoryCache: @unchecked Sendable {
    private let cache = NSCache<NSString, CGImageBox>()

    init(limitBytes: Int = 384 * 1024 * 1024) {
        cache.totalCostLimit = limitBytes
    }

    func insert(_ image: CGImage, key: String, size: Int) {
        cache.setObject(CGImageBox(image), forKey: "\(key)@\(size)" as NSString, cost: image.bytesPerRow * image.height)
    }

    /// The smallest cached size that's still sharp enough.
    func image(key: String, atLeast size: Int) -> CGImage? {
        for candidate in ArtworkPipeline.sizes where candidate >= size {
            if let hit = cache.object(forKey: "\(key)@\(candidate)" as NSString) { return hit.image }
        }
        return nil
    }
}

final class CGImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// Limits concurrent work. When a slot frees up, the most recent waiter goes first, because while
/// scrolling that's the artwork on screen now.
actor AsyncLimiter {
    private var available: Int
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    init(limit: Int) { available = limit }

    /// False if the task was cancelled, in which case there's no slot to release.
    func acquire() async -> Bool {
        if Task.isCancelled { return false }
        if available > 0 {
            available -= 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiting.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release() {
        if let next = waiting.popLast() {
            next.continuation.resume(returning: true)
        } else {
            available += 1
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(returning: false)
    }
}
