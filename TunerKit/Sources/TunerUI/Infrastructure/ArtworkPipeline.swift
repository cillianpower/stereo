import CryptoKit
import Foundation
import ImageIO
import SwiftUI

/// Loads, downsamples and caches artwork. Keys are stable IDs (cover art ID + size), not URLs,
/// because Subsonic URLs carry a fresh auth salt on every request and would never hit a URL cache.
public actor ArtworkPipeline {
    public static let sizes = [120, 300, 600, 1200]

    private let directory: URL
    private let memory = NSCache<NSString, CGImageBox>()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 400
    }

    /// Rounds up to one of a few fixed sizes so different views share cache entries.
    public static func bucket(for points: CGFloat, scale: CGFloat) -> Int {
        let px = Int(points * scale)
        return sizes.first { $0 >= px } ?? sizes.last!
    }

    public func image(key: String, size: Int, url: @Sendable () async -> URL?) async -> CGImage? {
        let cacheKey = "\(key)@\(size)"
        if let hit = memory.object(forKey: cacheKey as NSString) { return hit.image }
        if let task = inFlight[cacheKey] { return await task.value }

        let file = directory.appending(path: Self.fileName(cacheKey))
        if let data = try? Data(contentsOf: file), let img = Self.decode(data, maxPixel: size) {
            memory.setObject(CGImageBox(img), forKey: cacheKey as NSString)
            return img
        }
        let urlValue = await url()
        let task = Task<CGImage?, Never> {
            guard let urlValue, let (data, response) = try? await URLSession.shared.data(from: urlValue),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                  let img = Self.decode(data, maxPixel: size) else { return nil }
            try? data.write(to: file, options: .atomic)
            return img
        }
        inFlight[cacheKey] = task
        let image = await task.value
        inFlight[cacheKey] = nil
        if let image { memory.setObject(CGImageBox(image), forKey: cacheKey as NSString) }
        return image
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

final class CGImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
