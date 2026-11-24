import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads and writes the widget snapshot and its artwork in a directory, normally the App Group
/// container. Writes are atomic, so a widget reading mid-write sees the old or the new file, never
/// half of one.
public struct WidgetSnapshotStore: Sendable {
    public let directory: URL

    /// Info.plist key holding the App Group identifier, set by project.yml for the app and the widgets.
    public static let appGroupInfoKey = "StereoAppGroup"

    public init(directory: URL) {
        self.directory = directory
    }

    /// The store in this build's App Group, or nil when the build has no App Group
    /// (an ad-hoc signed Mac build, tests).
    public static func appGroup(bundle: Bundle = .main) -> WidgetSnapshotStore? {
        guard let group = bundle.object(forInfoDictionaryKey: appGroupInfoKey) as? String, !group.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return WidgetSnapshotStore(directory: container.appending(path: "Widgets", directoryHint: .isDirectory))
    }

    var snapshotURL: URL { directory.appending(path: "snapshot.json") }
    var artworkDirectory: URL { directory.appending(path: "Artwork", directoryHint: .isDirectory) }

    public func read() -> WidgetSnapshot {
        guard let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? Self.decoder.decode(WidgetSnapshot.self, from: data) else { return .empty }
        return snapshot
    }

    /// Writes the snapshot, then deletes artwork it no longer refers to.
    public func write(_ snapshot: WidgetSnapshot) throws {
        try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        try Self.encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)
        removeArtwork(except: snapshot.artworkFiles)
    }

    public func artworkURL(_ name: String) -> URL {
        artworkDirectory.appending(path: name)
    }

    public func hasArtwork(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: artworkURL(name).path(percentEncoded: false))
    }

    /// Stable file name for an artwork key, so unchanged art isn't rewritten.
    public static func artworkName(for key: String, size: Int) -> String {
        let hash = SHA256.hash(data: Data("\(key)@\(size)".utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(hash).jpg"
    }

    /// Saves artwork as a JPEG no larger than `maxPixel`. Widgets have a tight memory limit, so
    /// they must never decode full-size art.
    @discardableResult
    public func saveArtwork(_ image: CGImage, named name: String, maxPixel: Int) -> Bool {
        try? FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        let scaled = Self.downscale(image, maxPixel: maxPixel) ?? image
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return false }
        return (try? (data as Data).write(to: artworkURL(name), options: .atomic)) != nil
    }

    /// Decodes a saved thumbnail. Returns nil for a missing or unreadable file.
    public func loadArtwork(_ name: String, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(artworkURL(name) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func removeArtwork(except keep: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: artworkDirectory.path(percentEncoded: false))) ?? []
        for file in files where !keep.contains(file) {
            try? FileManager.default.removeItem(at: artworkURL(file))
        }
    }

    static func downscale(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maxPixel else { return image }
        let scale = Double(maxPixel) / Double(longest)
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}
