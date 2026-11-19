import AVFoundation
import os

/// Gapless player on AVAudioEngine.
///
/// Every item, file or stream, is decoded into one fixed PCM format and its buffers go to a single
/// `AVAudioPlayerNode`. When one item runs out, the next item's buffers are scheduled straight
/// after, so the transition is sample-accurate. A position poll detects when playback crosses
/// into the next item (`.advanced`) and when a stream underruns (`.buffering`).
///
/// Every mutable property is touched only on `queue`.
public final class AudioEnginePlayer: PlaybackEngine, AudioTapHost, @unchecked Sendable {
    private struct Segment {
        let item: EngineItem
        /// Frame (relative to the last `try node.playAudio()`) where this item's first sample sits.
        var startFrame: AVAudioFramePosition
        /// Seconds into the item at which this segment began (non-zero after a seek).
        let itemOffset: TimeInterval
    }

    public let events: AsyncStream<EngineEvent>
    private let continuation: AsyncStream<EngineEvent>.Continuation

    let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    let queue = DispatchQueue(label: "tuner.audio-engine", qos: .userInitiated)
    private let log = Logger(subsystem: "app.tuner", category: "engine")
    private let streamConfiguration: URLSessionConfiguration

    let format: AVAudioFormat
    private let manualRendering: Bool
    private let buffersAhead: Int
    private let chunkFrames: AVAudioFrameCount

    private var segments: [Segment] = []
    private var decoder: PCMSource?
    private var nextItem: EngineItem?
    private var scheduledFrames: AVAudioFramePosition = 0
    private var buffersInFlight = 0
    private var generation = 0
    private var audibleID: String?
    private var isPlaying = false
    private var isBuffering = false
    private var endReported = false
    private var pausedPosition: TimeInterval?
    private var poll: DispatchSourceTimer?
    private var configObserver: NSObjectProtocol?
    private var tapInstalled = false

    /// - Parameters:
    ///   - manualRenderingFormat: when set, the engine runs in offline manual-rendering mode (tests).
    ///   - buffersAhead: how many buffers (`chunkFrames` each) to keep scheduled; 32 × 8192 ≈ 5.5 s.
    ///   - streamConfiguration: URLSession configuration for streams (tests inject stub protocols).
    public init(manualRenderingFormat: AVAudioFormat? = nil, buffersAhead: Int = 32, chunkFrames: AVAudioFrameCount = 8192,
                streamConfiguration: URLSessionConfiguration = .default) {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        self.buffersAhead = buffersAhead
        self.chunkFrames = chunkFrames
        self.streamConfiguration = streamConfiguration
        manualRendering = manualRenderingFormat != nil

        if let manualRenderingFormat {
            try? engine.enableManualRenderingMode(.offline, format: manualRenderingFormat, maximumFrameCount: 4096)
            format = AVAudioFormat(standardFormatWithSampleRate: manualRenderingFormat.sampleRate, channels: 2)!
        } else {
            let hw = engine.outputNode.outputFormat(forBus: 0).sampleRate
            format = AVAudioFormat(standardFormatWithSampleRate: hw > 0 ? hw : 48_000, channels: 2)!
        }

        engine.attach(node)
        do {
            try engine.connectNode(node, to: engine.mainMixerNode, format: format)
        } catch {
            Logger(subsystem: "app.tuner", category: "engine").fault("engine connect failed: \(error.localizedDescription)")
        }
        engine.prepare()

        if !manualRendering {
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                self.queue.async { [weak self] in self?.handleConfigurationChange() }
            }
        }
    }

    deinit {
        poll?.cancel()
        decoder?.cancel()
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        continuation.finish()
    }

    // MARK: PlaybackEngine

    public func play(_ item: EngineItem, at offset: TimeInterval = 0) {
        queue.async { [self] in
            nextItem = nil
            start(item, at: offset, emit: .started(id: item.id))
        }
    }

    public func load(_ item: EngineItem, at offset: TimeInterval) {
        queue.async { [self] in
            nextItem = nil
            start(item, at: offset, emit: nil, autoplay: false)
        }
    }

    public func setNext(_ item: EngineItem?) {
        queue.async { [self] in
            guard let last = segments.last else { return }
            if last.item.id == audibleID {
                nextItem = item
                // The current item may already be fully decoded; start the next one now.
                if decoder == nil, let item { beginDecoding(item) }
                fill()
            }
            // Otherwise the next item is already decoding, so leave it alone.
        }
    }

    public func pause() {
        queue.async { [self] in
            guard isPlaying else { return }
            pausedPosition = position()
            node.pause()
            if !manualRendering { engine.pause() }
            setPlaying(false)
        }
    }

    public func resume() {
        queue.async { [self] in
            guard !isPlaying, let seg = audibleSegment() else { return }
            // Live radio can't continue from where it paused; rejoin the live edge.
            if seg.item.isLive {
                start(seg.item, at: 0, emit: nil)
                return
            }
            do {
                try startEngineIfNeeded()
                try node.playAudio()
                pausedPosition = nil
                setPlaying(true)
            } catch {
                emit(.failed(id: audibleID ?? "", message: error.localizedDescription))
            }
        }
    }

    public func stop() {
        queue.async { [self] in
            reset()
            nextItem = nil
            audibleID = nil
            pausedPosition = nil
            setBuffering(false)
            setPlaying(false)
        }
    }

    public func seek(to seconds: TimeInterval) {
        queue.async { [self] in
            guard let current = audibleSegment(), !current.item.isLive else { return }
            let following = segments.drop { $0.item.id != current.item.id }.dropFirst().first?.item ?? nextItem
            let wasPlaying = isPlaying
            start(current.item, at: max(0, seconds), emit: nil)
            nextItem = following
            fill()
            if !wasPlaying {
                node.pause()
                pausedPosition = max(0, seconds)
                setPlaying(false)
            }
        }
    }

    public var currentTime: TimeInterval { queue.sync { pausedPosition ?? position() } }
    public var currentItemID: String? { queue.sync { audibleID } }

    public var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    // MARK: AudioTapHost

    public func installTap(_ handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        queue.async { [self] in
            if tapInstalled { engine.mainMixerNode.removeTap(onBus: 0) }
            do {
                try engine.mainMixerNode.installAudioTap(onBus: 0, bufferSize: 8192, format: nil) { buffer, time in
                    handler(AVAudioPCMBuffer(copying: buffer), time)
                }
                tapInstalled = true
            } catch {
                log.error("tap failed: \(error.localizedDescription)")
            }
        }
    }

    public func removeTap() {
        queue.async { [self] in
            guard tapInstalled else { return }
            engine.mainMixerNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    // MARK: Sources

    private func makeSource(_ item: EngineItem, at offset: TimeInterval) throws -> PCMSource {
        switch item.source {
        case .file(let url):
            return try FileDecoder(item: item, url: url, outputFormat: format, startAt: offset, chunkFrames: chunkFrames)
        case .stream(let spec):
            // Already fully downloaded (by us earlier, or by a prefetch)? Play the file.
            if !spec.isLive, let local = spec.completion.finalURL, FileManager.default.fileExists(atPath: local.path()) {
                return try FileDecoder(item: item, url: local, outputFormat: format, startAt: offset, chunkFrames: chunkFrames)
            }
            let decoder = try StreamDecoder(item: item, spec: spec, outputFormat: format, startAt: offset,
                                            queue: queue, configuration: streamConfiguration)
            decoder.onMetadata = { [weak self] meta in
                if let title = meta["StreamTitle"], !title.isEmpty { self?.emit(.streamMetadata(id: item.id, title: title)) }
            }
            return decoder
        }
    }

    private func attach(_ source: PCMSource) {
        let gen = generation
        source.onReadable = { [weak self] in
            guard let self, gen == self.generation else { return }
            self.fill()
        }
    }

    // MARK: Scheduling

    private func start(_ item: EngineItem, at offset: TimeInterval, emit event: EngineEvent?, autoplay: Bool = true) {
        reset()
        let source: PCMSource
        do {
            source = try makeSource(item, at: offset)
        } catch {
            log.error("open failed: \(error.localizedDescription)")
            emit(.failed(id: item.id, message: error.localizedDescription))
            return
        }
        decoder = source
        attach(source)
        segments = [Segment(item: item, startFrame: 0, itemOffset: offset)]
        audibleID = item.id
        endReported = false
        fill()
        do {
            try startEngineIfNeeded()
            startPolling()
            if autoplay {
                try node.playAudio()
                setPlaying(true)
            } else {
                pausedPosition = offset
                setPlaying(false)
            }
            if let event { emit(event) }
        } catch {
            emit(.failed(id: item.id, message: error.localizedDescription))
        }
    }

    private func reset() {
        generation += 1
        decoder?.cancel()
        node.stop()          // flushes buffers; their completions are ignored via `generation`
        decoder = nil
        segments = []
        scheduledFrames = 0
        buffersInFlight = 0
    }

    private func beginDecoding(_ item: EngineItem) {
        do {
            let source = try makeSource(item, at: 0)
            decoder = source
            attach(source)
            segments.append(Segment(item: item, startFrame: scheduledFrames, itemOffset: 0))
            endReported = false
        } catch {
            log.error("next item open failed: \(error.localizedDescription)")
            emit(.failed(id: item.id, message: error.localizedDescription))
            decoder = nil
        }
        nextItem = nil
    }

    /// Keeps `buffersAhead` buffers scheduled, moving on to `nextItem` when the current source ends.
    private func fill() {
        while buffersInFlight < buffersAhead {
            guard let decoder else { return }
            do {
                switch try decoder.read(frames: chunkFrames) {
                case .buffer(let buffer):
                    schedule(buffer)
                case .wait:
                    return   // `onReadable` calls back in when more data arrives
                case .end:
                    if let next = nextItem {
                        beginDecoding(next)
                    } else {
                        self.decoder = nil
                        return
                    }
                }
            } catch {
                log.error("decode failed: \(error.localizedDescription)")
                emit(.failed(id: decoder.item.id, message: error.localizedDescription))
                decoder.cancel()
                self.decoder = nil
                if let next = nextItem { beginDecoding(next) }
            }
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        // After an underrun the node kept counting frames through silence; realign so positions
        // and segment boundaries stay correct for what comes next.
        if let rendered = renderedFrames(), rendered > scheduledFrames, !segments.isEmpty {
            let drift = rendered - scheduledFrames
            scheduledFrames = rendered
            segments[segments.count - 1].startFrame += drift
        }
        buffersInFlight += 1
        scheduledFrames += AVAudioFramePosition(buffer.frameLength)
        setBuffering(false)
        let gen = generation
        node.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard gen == self.generation else { return }
                self.buffersInFlight -= 1
                self.fill()
            }
        }
    }

    // MARK: Position

    /// Frames rendered since the last `try node.playAudio()`.
    private func renderedFrames() -> AVAudioFramePosition? {
        // playerTime(forNodeTime:) raises an Objective-C exception unless the engine is running.
        guard engine.isRunning, node.engine != nil, let nodeTime = node.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return nil }
        return playerTime.sampleTime
    }

    private func audibleSegment() -> Segment? {
        guard let frames = renderedFrames() else { return segments.first { $0.item.id == audibleID } ?? segments.first }
        return segments.last { $0.startFrame <= frames } ?? segments.first
    }

    private func position() -> TimeInterval {
        guard let seg = audibleSegment() else { return 0 }
        guard let frames = renderedFrames() else { return seg.itemOffset }
        // Don't count silence during an underrun.
        let effective = min(frames, scheduledFrames)
        return seg.itemOffset + Double(max(0, effective - seg.startFrame)) / format.sampleRate
    }

    private func startPolling() {
        guard poll == nil, !manualRendering else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        poll = timer
    }

    /// Detects boundary crossings, underruns and end of playback.
    func tick() {
        guard isPlaying, let frames = renderedFrames() else { return }
        if let seg = segments.last(where: { $0.startFrame <= frames }), seg.item.id != audibleID {
            audibleID = seg.item.id
            if let idx = segments.firstIndex(where: { $0.item.id == seg.item.id }), idx > 0 {
                segments.removeFirst(idx)
            }
            emit(.advanced(id: seg.item.id))
        }
        let starved = frames >= scheduledFrames
        if starved, decoder != nil { setBuffering(true) }
        if decoder == nil, nextItem == nil, !endReported, starved, !segments.isEmpty {
            endReported = true
            node.stop()
            setPlaying(false)
            emit(.ended)
        }
    }

    /// Test hook: runs `tick()` on the engine queue.
    func tickSync() { queue.sync { tick() } }
    /// Test hook: waits for queued engine work.
    func drain() { queue.sync {} }

    // MARK: Engine lifecycle

    private func startEngineIfNeeded() throws {
        if !engine.isRunning { try engine.start() }
    }

    private func handleConfigurationChange() {
        // Output device or sample rate changed: the engine stopped and the node lost its schedule.
        log.info("engine configuration changed")
        guard let seg = audibleSegment() else { return }
        let pos = pausedPosition ?? position()
        let wasPlaying = isPlaying
        let following = nextItem
        start(seg.item, at: seg.item.isLive ? 0 : pos, emit: nil)
        nextItem = following
        if !wasPlaying {
            node.pause()
            engine.pause()
            pausedPosition = pos
            setPlaying(false)
        }
    }

    private func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        emit(.playingChanged(playing))
    }

    private func setBuffering(_ buffering: Bool) {
        guard buffering != isBuffering else { return }
        isBuffering = buffering
        emit(.buffering(buffering))
    }

    private func emit(_ event: EngineEvent) { continuation.yield(event) }
}
