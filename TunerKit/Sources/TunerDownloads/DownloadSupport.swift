import CryptoKit
import Foundation
import SubsonicClient
import TunerModel

/// Converts between `StreamQuality` and the string stored with each pin/download.
public enum DownloadQuality {
    public static func key(_ quality: StreamQuality) -> String {
        switch quality {
        case .original: "original"
        case .transcoded(let format, let rate): "\(format)@\(rate)"
        }
    }

    public static func quality(fromKey key: String) -> StreamQuality {
        let parts = key.split(separator: "@")
        guard parts.count == 2, let rate = Int(parts[1]) else { return .original }
        return .transcoded(format: String(parts[0]), maxBitRate: rate)
    }

    /// File name for a track at a quality. Navidrome sends AAC transcodes as raw ADTS, so the
    /// transcode format doubles as the extension.
    public static func relativePath(for track: Track, quality: StreamQuality) -> String {
        let ext: String
        switch quality {
        case .original: ext = track.format.codec ?? "audio"
        case .transcoded(let format, _): ext = format
        }
        let digest = SHA256.hash(data: Data("\(track.id)|\(key(quality))".utf8))
            .prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(digest).\(ext)"
    }
}

/// What the download manager needs from a library. `SubsonicLibrary` conforms.
public protocol DownloadSource: Sendable {
    func album(_ id: ItemID) async throws -> AlbumDetail
    func playlist(_ id: ItemID) async throws -> PlaylistDetail
    /// The original file, untouched.
    func downloadRequest(for track: ItemID) async throws -> URLRequest
    func streamRequest(for track: ItemID, quality: StreamQuality, offset: Duration?) async throws -> URLRequest
}

extension SubsonicLibrary: DownloadSource {}

public enum DownloadError: Error, Equatable, LocalizedError {
    case http(Int)
    case serverError(String)
    case noSource

    public var errorDescription: String? {
        switch self {
        case .http(let code): "Server returned HTTP \(code)."
        case .serverError(let message): message
        case .noSource: "Not connected to a server."
        }
    }
}

/// Fetches one URL to a local temporary file, reporting progress.
public protocol DownloadTransport: Sendable {
    /// - Parameter tag: identifies the download across app launches (background sessions).
    /// - Returns: a temporary file the caller must move.
    func download(_ request: URLRequest, tag: String, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL
    /// Tags of transfers still running in the session (e.g. resumed after relaunch).
    func activeTags() async -> Set<String>
}

/// `URLSession` transport built on the delegate API, so it works with background sessions
/// (which reject the async convenience methods).
public final class URLSessionDownloadTransport: NSObject, DownloadTransport, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Pending {
        let continuation: CheckedContinuation<URL, Error>
        let progress: @Sendable (Int64, Int64?) -> Void
        var file: URL?
        var failure: Error?
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var orphans: [String: Result<URL, Error>] = [:]
    private let staging: URL
    private var session: URLSession!

    /// Called when a transfer finishes that no caller is waiting for (it outlived an app launch).
    public var onOrphanCompletion: (@Sendable (_ tag: String, _ result: Result<URL, Error>) -> Void)?

    /// Background session for the app (`sessionSendsLaunchEvents`, not discretionary).
    public static func background(identifier: String, staging: URL) -> URLSessionDownloadTransport {
        #if os(iOS) || os(tvOS)
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        #else
        let config = URLSessionConfiguration.default
        #endif
        config.httpMaximumConnectionsPerHost = 4
        return URLSessionDownloadTransport(configuration: config, staging: staging)
    }

    public init(configuration: URLSessionConfiguration = .default, staging: URL) {
        self.staging = staging
        super.init()
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    public func download(_ request: URLRequest, tag: String, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        let task = session.downloadTask(with: request)
        task.taskDescription = tag
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { pending[task.taskIdentifier] = Pending(continuation: continuation, progress: progress) }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    public func activeTags() async -> Set<String> {
        let tasks = await session.allTasks
        return Set(tasks.filter { $0.state == .running || $0.state == .suspended }.compactMap(\.taskDescription))
    }

    /// The `message` of a Subsonic error envelope, JSON (`f=json`) or XML.
    static func subsonicErrorMessage(_ data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let response = object["subsonic-response"] as? [String: Any],
           let error = response["error"] as? [String: Any] {
            return error["message"] as? String
        }
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: #"message="[^"]*""#, options: .regularExpression) else { return nil }
        return String(text[range].dropFirst("message=\"".count).dropLast())
    }

    // MARK: URLSessionDownloadDelegate

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let callback = lock.withLock { pending[downloadTask.taskIdentifier]?.progress }
        callback?(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this method returns, so validate and move it now.
        var outcome: Result<URL, Error>
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            outcome = .failure(DownloadError.http(http.statusCode))
        } else if let type = downloadTask.response?.mimeType?.lowercased(), type.contains("xml") || type.contains("json") {
            // Subsonic reports errors (bad ID, auth) as a 200 with an XML/JSON envelope.
            let data = (try? Data(contentsOf: location)) ?? Data()
            outcome = .failure(DownloadError.serverError(Self.subsonicErrorMessage(data) ?? "The server returned an error instead of audio."))
        } else {
            let dest = staging.appending(path: UUID().uuidString)
            do {
                try FileManager.default.moveItem(at: location, to: dest)
                outcome = .success(dest)
            } catch {
                outcome = .failure(error)
            }
        }
        lock.withLock {
            if var p = pending[downloadTask.taskIdentifier] {
                switch outcome {
                case .success(let url): p.file = url
                case .failure(let error): p.failure = error
                }
                pending[downloadTask.taskIdentifier] = p
            } else if let tag = downloadTask.taskDescription {
                orphans[tag] = outcome
            }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (entry, orphan) = lock.withLock { () -> (Pending?, Result<URL, Error>?) in
            let p = pending.removeValue(forKey: task.taskIdentifier)
            let o = p == nil ? task.taskDescription.flatMap { orphans.removeValue(forKey: $0) } : nil
            return (p, o)
        }
        if let entry {
            if let error { entry.continuation.resume(throwing: error) }
            else if let failure = entry.failure { entry.continuation.resume(throwing: failure) }
            else if let file = entry.file { entry.continuation.resume(returning: file) }
            else { entry.continuation.resume(throwing: URLError(.unknown)) }
        } else if let tag = task.taskDescription {
            let result: Result<URL, Error> = error.map { .failure($0) } ?? orphan ?? .failure(URLError(.unknown))
            onOrphanCompletion?(tag, result)
        }
    }
}
