import Foundation
import os

/// Bytes for the stream parser. All methods and callbacks run on the engine queue.
protocol ByteSource: AnyObject {
    /// Called whenever new bytes are available (or the source finished/failed).
    var onAvailable: (() -> Void)? { get set }
    /// Returns up to `max` contiguous bytes at the read position, or nil if none are loaded yet.
    func read(max: Int) -> Data?
    /// True once every byte has been read.
    var isAtEnd: Bool { get }
    var error: Error? { get }
    var contentType: String? { get }
    var contentLength: Int64? { get }
    /// Moves the read position (absolute byte offset). May restart the download with a Range request.
    func seek(to offset: Int64)
    /// Like `seek`, for a look at a few bytes: fetches a small range so the connection can be reused.
    func probe(at offset: Int64)
    func cancel()
}

/// Delivers URLSession callbacks on the engine queue.
func makeEngineSession(configuration: URLSessionConfiguration, delegate: URLSessionDataDelegate, queue: DispatchQueue) -> URLSession {
    let ops = OperationQueue()
    ops.maxConcurrentOperationCount = 1
    ops.underlyingQueue = queue
    return URLSession(configuration: configuration, delegate: delegate, delegateQueue: ops)
}

// MARK: Progressive download

/// Downloads at network speed into a (possibly sparse) temporary file while the parser reads
/// from it at playback speed. Memory stays small even for hi-res FLAC, and a complete download
/// becomes the cached file for free.
///
/// Seeking past what has arrived restarts the download with `Range: bytes=N-` and writes at that
/// offset; the file is only handed to the cache if every byte ends up covered.
/// `@unchecked Sendable`: every property is confined to the engine queue (URLSession delivers there too).
final class DownloadByteSource: NSObject, ByteSource, URLSessionDataDelegate, @unchecked Sendable {
    var onAvailable: (() -> Void)?
    /// Called once with the temp file when every byte has been downloaded.
    var onComplete: ((URL) -> Void)?
    private(set) var error: Error?
    private(set) var contentType: String?
    private(set) var contentLength: Int64?

    let fileURL: URL
    private let request: URLRequest
    private let queue: DispatchQueue
    private let configuration: URLSessionConfiguration
    private let log = Logger(subsystem: "app.tuner", category: "download")

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var writer: FileHandle?
    private var reader: FileHandle?
    /// Downloaded byte ranges, kept sorted and merged.
    private var covered: [Range<Int64>] = []
    private var writeOffset: Int64 = 0
    private var readOffset: Int64 = 0
    private var serverSupportsRanges = true
    private var finishedTask = false
    private var completed = false
    private var taskStartedAt = Date()
    private var taskBytes: Int64 = 0
    /// The running request is a small probe; the download continues from the read position after it.
    private var isProbeTask = false
    private static let probeBytes: Int64 = 64 * 1024

    init(request: URLRequest, queue: DispatchQueue, configuration: URLSessionConfiguration) throws {
        self.request = request
        self.queue = queue
        self.configuration = configuration
        fileURL = FileManager.default.temporaryDirectory.appending(path: "tuner-stream-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: fileURL.path(), contents: nil)
        writer = try FileHandle(forWritingTo: fileURL)
        reader = try FileHandle(forReadingFrom: fileURL)
        super.init()
        start(at: 0)
    }

    deinit {
        try? writer?.close()
        try? reader?.close()
        if !completed { try? FileManager.default.removeItem(at: fileURL) }
    }

    private func start(at offset: Int64, length: Int64? = nil) {
        task?.cancel()
        var req = request
        if let length {
            req.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
        } else if offset > 0 {
            req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        writeOffset = offset
        finishedTask = false
        isProbeTask = length != nil
        error = nil
        taskStartedAt = Date()
        taskBytes = 0
        // One session for the whole track, so requests can share a connection.
        let session = self.session ?? makeEngineSession(configuration: configuration, delegate: self, queue: queue)
        self.session = session
        let task = session.dataTask(with: req)
        self.task = task
        task.resume()
    }

    // MARK: ByteSource

    var isAtEnd: Bool {
        if let contentLength { return readOffset >= contentLength && availableEnd(from: readOffset) >= contentLength }
        return finishedTask && readOffset >= writeOffset
    }

    func read(max: Int) -> Data? {
        let end = availableEnd(from: readOffset)
        guard end > readOffset, let reader else {
            resumeIfStalled()
            return nil
        }
        let count = Int(min(Int64(max), end - readOffset))
        do {
            try reader.seek(toOffset: UInt64(readOffset))
            guard let data = try reader.read(upToCount: count), !data.isEmpty else { return nil }
            readOffset += Int64(data.count)
            return data
        } catch {
            self.error = error
            return nil
        }
    }

    /// Reads bytes at an absolute offset without moving the read position (nil if not downloaded).
    func peek(at offset: Int64, count: Int) -> Data? {
        guard availableEnd(from: offset) >= offset + Int64(count), let reader else { return nil }
        try? reader.seek(toOffset: UInt64(offset))
        return try? reader.read(upToCount: count)
    }

    func seek(to offset: Int64) {
        readOffset = offset
        if availableEnd(from: offset) > offset { onAvailable?(); return }
        // Not downloaded yet. Jump with a Range request unless the running download will get
        // there within about 0.75 s at its current speed.
        let ahead = offset - writeOffset
        let elapsed = max(Date().timeIntervalSince(taskStartedAt), 0.05)
        let bytesPerSecond = max(Double(taskBytes) / elapsed, 1)
        let eta = ahead < 0 ? .infinity : Double(ahead) / bytesPerSecond
        if serverSupportsRanges, finishedTask || eta > 0.75 {
            log.debug("range restart at \(offset)")
            start(at: offset)
        }
        // Otherwise the running download will get there.
    }

    func probe(at offset: Int64) {
        readOffset = offset
        if availableEnd(from: offset) > offset { onAvailable?(); return }
        guard serverSupportsRanges else { return }   // the running download will get there
        start(at: offset, length: Self.probeBytes)
    }

    /// After seeking back into a loaded stretch, reading can reach a gap the running request
    /// has already passed (or no request is running). Fetch from the read position.
    private func resumeIfStalled() {
        guard serverSupportsRanges, error == nil, session != nil, let contentLength, readOffset < contentLength else { return }
        if finishedTask || writeOffset > readOffset { start(at: readOffset) }
    }

    func cancel() {
        checkComplete()
        task?.cancel()
        session?.invalidateAndCancel()
        session = nil
        onAvailable = nil
        onComplete = nil
    }

    /// End of the contiguous downloaded run starting at `offset`, or `offset` if none.
    private func availableEnd(from offset: Int64) -> Int64 {
        covered.first { $0.contains(offset) }?.upperBound ?? offset
    }

    private func addCovered(_ r: Range<Int64>) {
        var all = covered + [r]
        all.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int64>] = []
        for x in all {
            if let last = merged.last, x.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, x.upperBound)
            } else {
                merged.append(x)
            }
        }
        covered = merged
    }

    private func checkComplete() {
        guard !completed else { return }
        let total = contentLength ?? (finishedTask && covered.count == 1 && covered[0].lowerBound == 0 ? covered[0].upperBound : nil)
        guard let total, covered.count == 1, covered[0] == 0..<total else { return }
        completed = true
        contentLength = total
        try? writer?.synchronize()
        onComplete?(fileURL)
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // A response from a request a newer seek replaced says nothing about the current one.
        guard session === self.session, dataTask === task else { completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse else { completionHandler(.allow); return }
        guard (200..<300).contains(http.statusCode) else {
            error = URLError(.badServerResponse, userInfo: ["status": http.statusCode])
            completionHandler(.cancel)
            onAvailable?()
            return
        }
        contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
        if http.statusCode == 206, let range = http.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last.flatMap({ Int64($0) }) {
            contentLength = total
        } else {
            if writeOffset > 0 {
                // Server ignored our Range: it is sending from byte 0 again.
                serverSupportsRanges = false
                isProbeTask = false
                writeOffset = 0
            }
            if http.expectedContentLength > 0 { contentLength = http.expectedContentLength }
        }
        if http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "none" { serverSupportsRanges = false }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard session === self.session, dataTask === task, let writer else { return }
        do {
            try writer.seek(toOffset: UInt64(writeOffset))
            try writer.write(contentsOf: data)
        } catch {
            self.error = error
            return
        }
        addCovered(writeOffset..<(writeOffset + Int64(data.count)))
        writeOffset += Int64(data.count)
        taskBytes += Int64(data.count)
        // Detect completion on the last byte: the decoder may finish (and cancel us) before the
        // task-complete callback arrives.
        if contentLength != nil { checkComplete() }
        onAvailable?()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard session === self.session, task === self.task else { return }
        if let error = error as? URLError, error.code == .cancelled { return }
        finishedTask = true
        if let error {
            self.error = error
        } else {
            checkComplete()
            if isProbeTask, !completed, let contentLength {
                let next = availableEnd(from: readOffset)
                if next < contentLength { start(at: next) }
            }
        }
        onAvailable?()
    }
}

// MARK: Live radio

/// An endless Icecast/Shoutcast stream: ICY metadata is split out and reported, audio bytes are
/// queued in memory (bounded) for the parser. Nothing touches disk.
/// `@unchecked Sendable`: confined to the engine queue, like `DownloadByteSource`.
final class LiveByteSource: NSObject, ByteSource, URLSessionDataDelegate, @unchecked Sendable {
    var onAvailable: (() -> Void)?
    var onMetadata: (([String: String]) -> Void)?
    private(set) var error: Error?
    private(set) var contentType: String?
    var contentLength: Int64? { nil }

    private var session: URLSession?
    private var demuxer: ICYDemuxer?
    private var pending = Data()
    private var finished = false
    private let maxBuffered = 4 * 1024 * 1024

    init(request: URLRequest, queue: DispatchQueue, configuration: URLSessionConfiguration) {
        super.init()
        var req = request
        req.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        req.timeoutInterval = 15
        let session = makeEngineSession(configuration: configuration, delegate: self, queue: queue)
        self.session = session
        session.dataTask(with: req).resume()
    }

    var isAtEnd: Bool { finished && pending.isEmpty }

    func read(max: Int) -> Data? {
        guard !pending.isEmpty else { return nil }
        let n = min(max, pending.count)
        let out = pending.prefix(n)
        pending.removeFirst(n)
        return Data(out)
    }

    func seek(to offset: Int64) {}   // live: no seeking
    func probe(at offset: Int64) {}

    func cancel() {
        session?.invalidateAndCancel()
        session = nil
        onAvailable = nil
        onMetadata = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            guard (200..<300).contains(http.statusCode) else {
                error = URLError(.badServerResponse)
                completionHandler(.cancel)
                onAvailable?()
                return
            }
            contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
            if let interval = http.value(forHTTPHeaderField: "icy-metaint").flatMap(Int.init), interval > 0 {
                demuxer = ICYDemuxer(metaInterval: interval)
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if var d = demuxer {
            let out = d.consume(data)
            demuxer = d
            pending.append(out.audio)
            for meta in out.metadata { onMetadata?(meta) }
        } else {
            pending.append(data)
        }
        if pending.count > maxBuffered { pending.removeFirst(pending.count - maxBuffered) }
        onAvailable?()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as? URLError, error.code == .cancelled { return }
        finished = true
        self.error = error ?? URLError(.networkConnectionLost)
        onAvailable?()
    }
}
