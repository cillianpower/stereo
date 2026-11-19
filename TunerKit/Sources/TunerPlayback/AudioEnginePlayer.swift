import AVFoundation
import os

/// Gapless player on AVAudioEngine.
///
/// Every item is decoded into one fixed PCM format and its buffers go to a single
/// `AVAudioPlayerNode`. When one file runs out, the next file's buffers are scheduled
/// straight after, so the transition is sample-accurate. A position poll detects when
/// playback crosses into the next item and reports `.advanced`.
///
/// Every mutable property is touched only on `queue`.
public final class AudioEnginePlayer: PlaybackEngine, @unchecked Sendable {
    private struct Segment {
        let item: EngineItem
        /// Frame (relative to the last `node.play()`) where this item's first sample sits.
        let startFrame: AVAudioFramePosition
        /// Seconds into the item at which this segment began (non-zero after a seek).
        let itemOffset: TimeInterval
    }

    public let events: AsyncStream<EngineEvent>
    private let continuation: AsyncStream<EngineEvent>.Continuation

    let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "tuner.audio-engine", qos: .userInitiated)
    private let log = Logger(subsystem: "app.tuner", category: "engine")

    let format: AVAudioFormat
    private let manualRendering: Bool
    private let buffersAhead: Int
    private let chunkFrames: AVAudioFrameCount

    private var segments: [Segment] = []
    private var decoder: FileDecoder?
    private var nextItem: EngineItem?
    private var scheduledFrames: AVAudioFramePosition = 0
    private var buffersInFlight = 0
    private var generation = 0
    private var audibleID: String?
    private var isPlaying = false
    private var endReported = false
    private var pausedPosition: TimeInterval?
    private var poll: DispatchSourceTimer?
    private var configObserver: NSObjectProtocol?

    /// - Parameters:
    ///   - manualRenderingFormat: when set, the engine runs in offline manual-rendering mode (tests).
    ///   - buffersAhead: how many ~0.19 s buffers to keep scheduled.
    public init(manualRenderingFormat: AVAudioFormat? = nil, buffersAhead: Int = 16, chunkFrames: AVAudioFrameCount = 8192) {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        self.buffersAhead = buffersAhead
        self.chunkFrames = chunkFrames
        manualRendering = manualRenderingFormat != nil

        if let manualRenderingFormat {
            try? engine.enableManualRenderingMode(.offline, format: manualRenderingFormat, maximumFrameCount: 4096)
            format = AVAudioFormat(standardFormatWithSampleRate: manualRenderingFormat.sampleRate, channels: 2)!
        } else {
            let hw = engine.outputNode.outputFormat(forBus: 0).sampleRate
            format = AVAudioFormat(standardFormatWithSampleRate: hw > 0 ? hw : 48_000, channels: 2)!
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
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

    public func setNext(_ item: EngineItem?) {
        queue.async { [self] in
            guard let last = segments.last else { return }
            if last.item.id == audibleID {
                nextItem = item
                // The current file may already be fully decoded; start the next one now.
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
            guard !isPlaying, !segments.isEmpty else { return }
            do {
                try startEngineIfNeeded()
                node.play()
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
            setPlaying(false)
        }
    }

    public func seek(to seconds: TimeInterval) {
        queue.async { [self] in
            guard let current = audibleSegment() else { return }
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

    // MARK: Scheduling

    private func start(_ item: EngineItem, at offset: TimeInterval, emit event: EngineEvent?) {
        reset()
        do {
            decoder = try FileDecoder(item: item, outputFormat: format, startAt: offset, chunkFrames: chunkFrames)
        } catch {
            log.error("open failed \(item.fileURL.lastPathComponent): \(error)")
            emit(.failed(id: item.id, message: error.localizedDescription))
            return
        }
        segments = [Segment(item: item, startFrame: 0, itemOffset: offset)]
        audibleID = item.id
        endReported = false
        fill()
        do {
            try startEngineIfNeeded()
            node.play()
            setPlaying(true)
            startPolling()
            if let event { emit(event) }
        } catch {
            emit(.failed(id: item.id, message: error.localizedDescription))
        }
    }

    private func reset() {
        generation += 1
        node.stop()          // flushes buffers; their completions are ignored via `generation`
        decoder = nil
        segments = []
        scheduledFrames = 0
        buffersInFlight = 0
    }

    private func beginDecoding(_ item: EngineItem) {
        do {
            decoder = try FileDecoder(item: item, outputFormat: format, chunkFrames: chunkFrames)
            segments.append(Segment(item: item, startFrame: scheduledFrames, itemOffset: 0))
            endReported = false
        } catch {
            log.error("next item open failed: \(error)")
            emit(.failed(id: item.id, message: error.localizedDescription))
            decoder = nil
        }
        nextItem = nil
    }

    /// Keeps `buffersAhead` buffers scheduled, moving on to `nextItem` when the current file ends.
    private func fill() {
        while buffersInFlight < buffersAhead {
            guard let decoder else { return }
            do {
                if let buffer = try decoder.read(frames: chunkFrames) {
                    schedule(buffer)
                } else if let next = nextItem {
                    beginDecoding(next)
                } else {
                    self.decoder = nil
                    return
                }
            } catch {
                emit(.failed(id: decoder.item.id, message: error.localizedDescription))
                self.decoder = nil
                if let next = nextItem { beginDecoding(next) }
            }
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        buffersInFlight += 1
        scheduledFrames += AVAudioFramePosition(buffer.frameLength)
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

    /// Frames rendered since the last `node.play()`.
    private func renderedFrames() -> AVAudioFramePosition? {
        guard let nodeTime = node.lastRenderTime, let playerTime = node.playerTime(forNodeTime: nodeTime) else { return nil }
        return playerTime.sampleTime
    }

    private func audibleSegment() -> Segment? {
        guard let frames = renderedFrames() else { return segments.first { $0.item.id == audibleID } ?? segments.first }
        return segments.last { $0.startFrame <= frames } ?? segments.first
    }

    private func position() -> TimeInterval {
        guard let seg = audibleSegment() else { return 0 }
        guard let frames = renderedFrames() else { return seg.itemOffset }
        return seg.itemOffset + Double(max(0, frames - seg.startFrame)) / format.sampleRate
    }

    private func startPolling() {
        guard poll == nil, !manualRendering else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        poll = timer
    }

    /// Detects boundary crossings and end of playback. Public for manual-rendering tests.
    func tick() {
        guard isPlaying, let frames = renderedFrames() else { return }
        if let seg = segments.last(where: { $0.startFrame <= frames }), seg.item.id != audibleID {
            audibleID = seg.item.id
            // Drop segments that are fully in the past.
            if let idx = segments.firstIndex(where: { $0.item.id == seg.item.id }), idx > 0 {
                segments.removeFirst(idx)
            }
            emit(.advanced(id: seg.item.id))
        }
        if decoder == nil, nextItem == nil, !endReported, frames >= scheduledFrames, !segments.isEmpty {
            endReported = true
            node.stop()
            setPlaying(false)
            emit(.ended)
        }
    }

    /// Test hook: runs `tick()` on the engine queue.
    func tickSync() { queue.sync { tick() } }

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
        start(seg.item, at: pos, emit: nil)
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

    private func emit(_ event: EngineEvent) { continuation.yield(event) }
}
