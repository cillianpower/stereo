import Accelerate
import AVFoundation

/// Reads a local audio file and converts it to the engine's fixed PCM format, applying gain.
/// Every item reaches the player node in the same format, so buffers from consecutive
/// tracks can be scheduled back to back with no gap.
final class FileDecoder {
    let item: EngineItem
    let outputFormat: AVAudioFormat
    private let file: AVAudioFile
    private let converter: AVAudioConverter?
    private let inputBuffer: AVAudioPCMBuffer
    private var inputExhausted = false
    private(set) var isFinished = false

    /// Duration of the file, in seconds.
    let duration: TimeInterval

    init(item: EngineItem, outputFormat: AVAudioFormat, startAt seconds: TimeInterval = 0, chunkFrames: AVAudioFrameCount = 8192) throws {
        self.item = item
        self.outputFormat = outputFormat
        file = try AVAudioFile(forReading: item.fileURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let inFormat = file.processingFormat
        duration = Double(file.length) / inFormat.sampleRate

        if seconds > 0 {
            file.framePosition = min(AVAudioFramePosition(seconds * inFormat.sampleRate), file.length)
        }

        if inFormat.sampleRate == outputFormat.sampleRate, inFormat.channelCount == outputFormat.channelCount {
            converter = nil
        } else {
            guard let c = AVAudioConverter(from: inFormat, to: outputFormat) else {
                throw NSError(domain: "Tuner.FileDecoder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported format \(inFormat)"])
            }
            if inFormat.channelCount == 1, outputFormat.channelCount == 2 {
                c.channelMap = [0, 0]   // mono → both speakers
            }
            c.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter = c
        }
        inputBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunkFrames)!
    }

    /// Returns the next buffer in `outputFormat`, or nil once the file is exhausted.
    func read(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        guard !isFinished else { return nil }
        let out: AVAudioPCMBuffer
        if let converter {
            let ratio = outputFormat.sampleRate / file.processingFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(frames) * ratio) + 64
            out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)!
            var readError: Error?
            let status = converter.convert(to: out, error: nil) { [self] packets, inputStatus in
                if inputExhausted {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    inputBuffer.frameLength = 0
                    try file.read(into: inputBuffer, frameCount: min(packets, inputBuffer.frameCapacity))
                } catch {
                    readError = error
                }
                if inputBuffer.frameLength == 0 {
                    inputExhausted = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inputBuffer
            }
            if let readError { throw readError }
            if status == .error { throw NSError(domain: "Tuner.FileDecoder", code: 2) }
            if status == .endOfStream || (inputExhausted && out.frameLength == 0) {
                isFinished = out.frameLength == 0 || status == .endOfStream
            }
        } else {
            out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frames)!
            try file.read(into: out, frameCount: frames)
            if file.framePosition >= file.length { isFinished = true }
        }

        guard out.frameLength > 0 else {
            isFinished = true
            return nil
        }
        applyGain(out)
        return out
    }

    private func applyGain(_ buffer: AVAudioPCMBuffer) {
        guard item.gain != 1, let channels = buffer.floatChannelData else { return }
        var gain = item.gain
        let n = vDSP_Length(buffer.frameLength)
        for ch in 0..<Int(buffer.format.channelCount) {
            vDSP_vsmul(channels[ch], 1, &gain, channels[ch], 1, n)
        }
    }
}
