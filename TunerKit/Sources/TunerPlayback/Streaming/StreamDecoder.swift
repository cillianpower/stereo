import AudioToolbox
import AVFoundation
import os

enum StreamDecoderError: LocalizedError {
    case unsupportedFormat(String)
    case parse(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let s): "This stream's format isn't supported (\(s))."
        case .parse(let status): "Couldn't read the audio stream (\(status))."
        }
    }
}

/// Decodes an HTTP stream while it loads: bytes → AudioFileStream (packets) → AVAudioConverter (PCM).
///
/// - Gapless: encoder priming and remainder frames from the packet table (AAC in M4A, MP3 LAME
///   headers) are trimmed so consecutive tracks join seamlessly.
/// - Seeking: `AudioFileStreamSeek` maps a time to a byte offset, then the byte source jumps
///   there (a Range request if needed) and parsing resumes with a discontinuity flag.
///
/// Every method runs on the engine queue.
final class StreamDecoder: PCMSource {
    let item: EngineItem
    let outputFormat: AVAudioFormat
    var onReadable: (() -> Void)?
    var onMetadata: (([String: String]) -> Void)?

    private let spec: StreamSpec
    private let bytes: ByteSource
    private let log = Logger(subsystem: "app.tuner", category: "stream")

    private var streamID: AudioFileStreamID?
    private var asbd = AudioStreamBasicDescription()
    private var cookie: Data?
    private var packetTable: AudioFilePacketTableInfo?
    private var dataOffset: Int64 = 0
    private var audioDataByteCount: UInt64?
    private var maxPacketSize: UInt32 = 0
    private var ready = false
    private var discontinuity = false

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var isPCM = false

    // Queued compressed packets (or raw PCM bytes when `isPCM`).
    private var packetData = Data()
    private var packetDescs: [AudioStreamPacketDescription] = []
    private var queuedFrames: Int64 = 0

    /// Output frames still to drop (priming, or the part of a packet before a seek target).
    private var framesToSkip: Int64 = 0
    /// Output frames left before the remainder (encoder padding) starts, when known.
    private var framesRemaining: Int64?
    private var pendingSeek: TimeInterval?
    private var inputExhausted = false
    private var flushedParser = false
    /// Set after a seek: the next bytes must be realigned to a verified FLAC frame header.
    private var needsFLACResync = false
    private var consecutiveDecodeErrors = 0
    private var finished = false
    private var failure: Error?

    init(item: EngineItem, spec: StreamSpec, outputFormat: AVAudioFormat, startAt seconds: TimeInterval,
         queue: DispatchQueue, configuration: URLSessionConfiguration) throws {
        self.item = item
        self.spec = spec
        self.outputFormat = outputFormat
        if spec.isLive {
            let live = LiveByteSource(request: spec.request, queue: queue, configuration: configuration)
            bytes = live
        } else {
            let download = try DownloadByteSource(request: spec.request, queue: queue, configuration: configuration)
            let completion = spec.completion
            download.onComplete = { url in
                // Hand the finished file to the cache; seeks after this can use it directly.
                Task {
                    if let stored = await completion.store?(url) { completion.finalURL = stored }
                    else { completion.finalURL = url }
                }
            }
            bytes = download
        }
        pendingSeek = seconds > 0 ? seconds : nil

        let hint = Self.fileType(for: spec.typeHint)
        let status = AudioFileStreamOpen(Unmanaged.passUnretained(self).toOpaque(), propertyProc, packetsProc, hint, &streamID)
        guard status == noErr else { throw StreamDecoderError.parse(status) }

        bytes.onAvailable = { [weak self] in self?.onReadable?() }
        if let live = bytes as? LiveByteSource {
            live.onMetadata = { [weak self] meta in self?.onMetadata?(meta) }
        }
    }

    deinit {
        if let streamID { AudioFileStreamClose(streamID) }
        bytes.cancel()
    }

    func cancel() {
        bytes.cancel()
        onReadable = nil
    }

    // MARK: Reading

    func read(frames: AVAudioFrameCount) throws -> PCMRead {
        if let failure { throw failure }
        if finished { return .end }

        // Parse until there's about a second of audio queued, or we run out of bytes.
        let wanted = Int64(max(Double(frames) * 2, (inputFormat?.sampleRate ?? 44_100)))
        while !ready || queuedFrames < wanted {
            guard let chunk = bytes.read(max: 64 * 1024) else { break }
            try parse(chunk)
            if let failure { throw failure }
        }
        if let error = bytes.error, !bytes.isAtEnd || !ready { throw error }
        guard ready, let converter, let inputFormat else {
            if bytes.isAtEnd { throw StreamDecoderError.unsupportedFormat(spec.typeHint ?? bytes.contentType ?? "unknown") }
            return .wait
        }
        if bytes.isAtEnd, !flushedParser { flushParser() }
        if packetDescs.isEmpty, !isPCM || packetData.isEmpty {
            if bytes.isAtEnd { inputExhausted = true } else { return .wait }
        }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(Double(frames) * max(ratio, 1)) + 1024)!
        var convertError: NSError?
        let status = converter.convert(to: out, error: &convertError) { [self] _, inputStatus in
            if let buffer = nextInputBuffer(format: inputFormat) {
                inputStatus.pointee = .haveData
                return buffer
            }
            inputStatus.pointee = inputExhausted ? .endOfStream : .noDataNow
            return nil
        }
        if status == .error {
            // Corrupt or misaligned data (common in radio, possible right after a seek): drop what's
            // queued, reset the decoder and carry on. Only give up if it keeps happening.
            consecutiveDecodeErrors += 1
            if consecutiveDecodeErrors > 8 { throw convertError ?? StreamDecoderError.parse(-1) }
            log.info("decode error, resetting (\(self.consecutiveDecodeErrors))")
            converter.reset()
            packetData.removeAll(keepingCapacity: true)
            packetDescs.removeAll(keepingCapacity: true)
            queuedFrames = 0
            return .wait
        }
        consecutiveDecodeErrors = 0

        trim(out)
        if out.frameLength == 0 {
            if status == .endOfStream || (framesRemaining ?? 1) <= 0 { finished = true; return .end }
            return bytes.isAtEnd && packetDescs.isEmpty && packetData.isEmpty && status != .haveData ? .end : .wait
        }
        out.applyGain(item.gain)
        if status == .endOfStream || (framesRemaining ?? 1) <= 0 { finished = true }
        return .buffer(out)
    }

    /// Drops priming/seek-lead frames from the front and encoder padding from the back.
    private func trim(_ buffer: AVAudioPCMBuffer) {
        var length = Int64(buffer.frameLength)
        if framesToSkip > 0, length > 0 {
            let drop = min(framesToSkip, length)
            framesToSkip -= drop
            length -= drop
            if drop > 0, let ch = buffer.floatChannelData {
                for c in 0..<Int(buffer.format.channelCount) {
                    (ch[c]).update(from: ch[c] + Int(drop), count: Int(length))
                }
            }
        }
        if let remaining = framesRemaining {
            length = min(length, max(remaining, 0))
            framesRemaining = remaining - length
        }
        buffer.frameLength = AVAudioFrameCount(length)
    }

    /// Pulls queued packets into one converter input buffer.
    private func nextInputBuffer(format: AVAudioFormat) -> AVAudioBuffer? {
        if isPCM {
            let bpf = Int(format.streamDescription.pointee.mBytesPerFrame)
            guard bpf > 0, packetData.count >= bpf else { return nil }
            let frames = min(packetData.count / bpf, 8192)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
            pcm.frameLength = AVAudioFrameCount(frames)
            let bytes = frames * bpf
            packetData.withUnsafeBytes { src in
                pcm.mutableAudioBufferList.pointee.mBuffers.mData?.copyMemory(from: src.baseAddress!, byteCount: bytes)
            }
            packetData.removeFirst(bytes)
            queuedFrames -= Int64(frames)
            return pcm
        }

        guard !packetDescs.isEmpty else { return nil }
        let count = min(packetDescs.count, 64)
        let descs = Array(packetDescs.prefix(count))
        let start = descs[0].mStartOffset
        let end = descs.last!.mStartOffset + Int64(descs.last!.mDataByteSize)
        let size = Int(end - start)
        // Size from the packets we're actually copying; the stream's advertised upper bound can be huge.
        let largest = Int(descs.map(\.mDataByteSize).max() ?? 1)
        let maxPacket = max(largest, (size + count - 1) / count)
        let buffer = AVAudioCompressedBuffer(format: format, packetCapacity: AVAudioPacketCount(count), maximumPacketSize: maxPacket)
        packetData.withUnsafeBytes { src in
            buffer.data.copyMemory(from: src.baseAddress!.advanced(by: Int(start)), byteCount: size)
        }
        if let out = buffer.packetDescriptions {
            for (i, d) in descs.enumerated() {
                out[i] = AudioStreamPacketDescription(mStartOffset: d.mStartOffset - start,
                                                      mVariableFramesInPacket: d.mVariableFramesInPacket,
                                                      mDataByteSize: d.mDataByteSize)
            }
        }
        buffer.packetCount = AVAudioPacketCount(count)
        buffer.byteLength = UInt32(size)

        // Drop consumed packets and rebase the rest.
        packetDescs.removeFirst(count)
        packetData.removeFirst(Int(end))
        for i in packetDescs.indices { packetDescs[i].mStartOffset -= end }
        queuedFrames -= Int64(count) * Int64(max(asbd.mFramesPerPacket, 1))
        return buffer
    }

    // MARK: Parsing

    private func parse(_ input: Data) throws {
        guard let streamID else { return }
        var chunk = input
        if needsFLACResync {
            guard let start = FLACFrameScanner.firstFrameHeader(in: chunk) else { return }   // keep looking in the next chunk
            chunk = chunk.subdata(in: (chunk.startIndex + start)..<chunk.endIndex)
            needsFLACResync = false
        }
        let flags: AudioFileStreamParseFlags = discontinuity ? .discontinuity : []
        discontinuity = false
        let status = chunk.withUnsafeBytes { raw in
            AudioFileStreamParseBytes(streamID, UInt32(chunk.count), raw.baseAddress, flags)
        }
        // Junk at the start of some radio streams is tolerated; anything else is fatal.
        if status != noErr, !spec.isLive { throw StreamDecoderError.parse(status) }
        if ready, let seek = pendingSeek {
            pendingSeek = nil
            performSeek(to: seek)
        }
    }

    fileprivate func handleProperty(_ id: AudioFileStreamPropertyID) {
        guard let streamID else { return }
        switch id {
        case kAudioFileStreamProperty_DataFormat:
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            AudioFileStreamGetProperty(streamID, id, &size, &asbd)
        case kAudioFileStreamProperty_MagicCookieData:
            var size: UInt32 = 0
            var writable: DarwinBoolean = false
            guard AudioFileStreamGetPropertyInfo(streamID, id, &size, &writable) == noErr, size > 0 else { return }
            var data = Data(count: Int(size))
            data.withUnsafeMutableBytes { _ = AudioFileStreamGetProperty(streamID, id, &size, $0.baseAddress!) }
            cookie = data
        case kAudioFileStreamProperty_PacketTableInfo:
            var info = AudioFilePacketTableInfo()
            var size = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
            if AudioFileStreamGetProperty(streamID, id, &size, &info) == noErr, info.mNumberValidFrames > 0 { packetTable = info }
        case kAudioFileStreamProperty_DataOffset:
            var offset: Int64 = 0
            var size = UInt32(MemoryLayout<Int64>.size)
            if AudioFileStreamGetProperty(streamID, id, &size, &offset) == noErr { dataOffset = offset }
        case kAudioFileStreamProperty_AudioDataByteCount:
            var count: UInt64 = 0
            var size = UInt32(MemoryLayout<UInt64>.size)
            if AudioFileStreamGetProperty(streamID, id, &size, &count) == noErr { audioDataByteCount = count }
        case kAudioFileStreamProperty_PacketSizeUpperBound, kAudioFileStreamProperty_MaximumPacketSize:
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioFileStreamGetProperty(streamID, id, &size, &value) == noErr { maxPacketSize = max(maxPacketSize, value) }
        case kAudioFileStreamProperty_ReadyToProducePackets:
            setUpConverter()
        default:
            break
        }
    }

    private func setUpConverter() {
        guard !ready else { return }
        isPCM = asbd.mFormatID == kAudioFormatLinearPCM
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            failure = StreamDecoderError.unsupportedFormat("format id \(asbd.mFormatID)")
            return
        }
        guard let converter = AVAudioConverter(from: format, to: outputFormat) else {
            failure = StreamDecoderError.unsupportedFormat("\(format)")
            return
        }
        if let cookie { converter.magicCookie = cookie }
        if format.channelCount == 1, outputFormat.channelCount == 2 { converter.channelMap = [0, 0] }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        self.converter = converter
        inputFormat = format
        let ratio = outputFormat.sampleRate / format.sampleRate
        if let pt = packetTable, pendingSeek == nil {
            framesToSkip = Int64(Double(pt.mPrimingFrames) * ratio)
            framesRemaining = Int64(Double(pt.mNumberValidFrames) * ratio)
        }
        ready = true
    }

    fileprivate func handlePackets(bytes count: UInt32, packets: UInt32, data: UnsafeRawPointer,
                                   descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        if !ready { setUpConverter() }
        let base = Int64(packetData.count)
        packetData.append(data.assumingMemoryBound(to: UInt8.self), count: Int(count))
        if let descriptions {
            var accepted = 0
            for i in 0..<Int(packets) {
                var d = descriptions[i]
                // Never trust the parser blindly: corrupt input can yield nonsense descriptions.
                guard d.mStartOffset >= 0, d.mDataByteSize > 0, d.mDataByteSize <= Self.maxSanePacketBytes,
                      d.mStartOffset + Int64(d.mDataByteSize) <= Int64(count) else { continue }
                d.mStartOffset += base
                packetDescs.append(d)
                accepted += 1
            }
            queuedFrames += Int64(accepted) * Int64(max(asbd.mFramesPerPacket, 1))
        } else if isPCM, asbd.mBytesPerFrame > 0 {
            queuedFrames += Int64(count / asbd.mBytesPerFrame)
        } else if asbd.mBytesPerPacket > 0 {
            // CBR compressed without descriptions: synthesise them.
            let per = Int64(asbd.mBytesPerPacket)
            for i in 0..<Int64(count) / per {
                packetDescs.append(AudioStreamPacketDescription(mStartOffset: base + i * per, mVariableFramesInPacket: 0, mDataByteSize: UInt32(per)))
            }
            queuedFrames += Int64(count) / per * Int64(max(asbd.mFramesPerPacket, 1))
        }
    }

    /// AudioFileStream only ends a FLAC frame when it sees the next frame's sync header, so the
    /// final frame would never come out. Feeding it the header of the first frame ends the last
    /// real frame; the fake one never completes, so it's never emitted.
    private func flushParser() {
        flushedParser = true
        guard asbd.mFormatID == kAudioFormatFLAC, let download = bytes as? DownloadByteSource,
              let header = download.peek(at: dataOffset, count: 32) else { return }
        try? parse(header)
    }

    // MARK: Seeking

    private func performSeek(to seconds: TimeInterval) {
        guard let streamID, let inputFormat, let converter else { return }
        let rate = inputFormat.sampleRate
        let ratio = outputFormat.sampleRate / rate
        let priming = Int64(packetTable?.mPrimingFrames ?? 0)
        let targetFrame = Int64(seconds * rate) + priming
        var byteOffset: Int64 = 0
        var leadFrames: Int64 = 0

        if isPCM, asbd.mBytesPerFrame > 0 {
            byteOffset = Int64(seconds * rate) * Int64(asbd.mBytesPerFrame)
        } else if asbd.mFramesPerPacket > 0 {
            let packet = targetFrame / Int64(asbd.mFramesPerPacket)
            var flags = AudioFileStreamSeekFlags(rawValue: 0)
            if AudioFileStreamSeek(streamID, packet, &byteOffset, &flags) == noErr {
                leadFrames = targetFrame - packet * Int64(asbd.mFramesPerPacket)
            } else if let total = bytes.contentLength, let duration = spec.expectedDuration, duration > 0 {
                byteOffset = Int64(Double(total - dataOffset) * seconds / duration)
            }
        } else if let total = bytes.contentLength, let duration = spec.expectedDuration, duration > 0 {
            // No packet math available (e.g. some FLAC): estimate proportionally; the parser resyncs.
            byteOffset = Int64(Double(total - dataOffset) * seconds / duration)
        }

        packetData.removeAll(keepingCapacity: true)
        packetDescs.removeAll(keepingCapacity: true)
        queuedFrames = 0
        converter.reset()
        framesToSkip = Int64(Double(leadFrames) * ratio)
        if let pt = packetTable {
            // Output starts exactly at the target once `leadFrames` are skipped.
            let validAfterTarget = Int64(pt.mNumberValidFrames) - Int64(seconds * rate)
            framesRemaining = Int64(Double(max(0, validAfterTarget)) * ratio)
        } else {
            framesRemaining = nil
        }
        discontinuity = true
        needsFLACResync = asbd.mFormatID == kAudioFormatFLAC
        bytes.seek(to: dataOffset + byteOffset)
        log.debug("seek \(seconds)s → byte \(self.dataOffset + byteOffset)")
    }

    // MARK: Helpers

    /// Largest packet we'll believe (8-channel 32-bit FLAC frames stay well under this).
    static let maxSanePacketBytes: UInt32 = 1 << 20

    static func fileType(for hint: String?) -> AudioFileTypeID {
        switch hint?.lowercased() {
        case "flac", "audio/flac", "audio/x-flac": kAudioFileFLACType
        case "mp3", "mpeg", "audio/mpeg", "audio/mp3": kAudioFileMP3Type
        case "aac", "aac+", "aacp", "he-aac", "audio/aac", "audio/aacp", "audio/x-aac": kAudioFileAAC_ADTSType
        case "m4a", "alac", "mp4", "audio/mp4", "audio/x-m4a": kAudioFileM4AType
        case "wav", "audio/wav", "audio/x-wav": kAudioFileWAVEType
        case "aif", "aiff", "audio/aiff", "audio/x-aiff": kAudioFileAIFFType
        case "caf": kAudioFileCAFType
        default: 0
        }
    }
}

// MARK: C callbacks

private func propertyProc(_ client: UnsafeMutableRawPointer, _ stream: AudioFileStreamID,
                          _ property: AudioFileStreamPropertyID, _ flags: UnsafeMutablePointer<AudioFileStreamPropertyFlags>) {
    Unmanaged<StreamDecoder>.fromOpaque(client).takeUnretainedValue().handleProperty(property)
}

private func packetsProc(_ client: UnsafeMutableRawPointer, _ numberBytes: UInt32, _ numberPackets: UInt32,
                         _ data: UnsafeRawPointer, _ descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
    Unmanaged<StreamDecoder>.fromOpaque(client).takeUnretainedValue()
        .handlePackets(bytes: numberBytes, packets: numberPackets, data: data, descriptions: descriptions)
}

/// Finds real FLAC frame headers: sync code plus a valid CRC-8, so a byte pattern that merely
/// looks like a sync inside audio data isn't mistaken for a frame start.
enum FLACFrameScanner {
    static func firstFrameHeader(in data: Data) -> Int? {
        data.withUnsafeBytes { raw -> Int? in
            let b = raw.bindMemory(to: UInt8.self)
            guard b.count >= 6 else { return nil }
            for i in 0..<(b.count - 5) where b[i] == 0xFF && (b[i + 1] & 0xFE) == 0xF8 {
                if let length = headerLength(b, at: i), i + length < b.count, crc8(b, from: i, count: length - 1) == b[i + length - 1] {
                    return i
                }
            }
            return nil
        }
    }

    /// Header length including the CRC byte, or nil if the fields are invalid.
    static func headerLength(_ b: UnsafeBufferPointer<UInt8>, at i: Int) -> Int? {
        let blockSizeCode = b[i + 2] >> 4
        let sampleRateCode = b[i + 2] & 0x0F
        let channelCode = b[i + 3] >> 4
        let sampleSizeCode = (b[i + 3] >> 1) & 0x07
        guard blockSizeCode != 0, sampleRateCode != 0x0F, channelCode <= 10, sampleSizeCode != 3, b[i + 3] & 1 == 0 else { return nil }
        // UTF-8-style coded frame/sample number.
        let first = b[i + 4]
        var utfLength = 1
        if first & 0x80 != 0 {
            var mask: UInt8 = 0x40
            utfLength = 2
            while first & mask != 0 && utfLength < 7 { utfLength += 1; mask >>= 1 }
            guard first & 0x40 != 0 else { return nil }
        }
        var length = 4 + utfLength
        if blockSizeCode == 6 { length += 1 } else if blockSizeCode == 7 { length += 2 }
        if sampleRateCode == 12 { length += 1 } else if sampleRateCode == 13 || sampleRateCode == 14 { length += 2 }
        return length + 1
    }

    static func crc8(_ b: UnsafeBufferPointer<UInt8>, from start: Int, count: Int) -> UInt8 {
        var crc: UInt8 = 0
        for k in start..<(start + count) {
            crc ^= b[k]
            for _ in 0..<8 { crc = (crc & 0x80) != 0 ? (crc << 1) ^ 0x07 : crc << 1 }
        }
        return crc
    }
}
