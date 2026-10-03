// SPDX-License-Identifier: AGPL-3.0-or-later
import AVFoundation
import Foundation

/// Records from the microphone at 22050 Hz mono float32, or imports an audio
/// file (m4a / wav / aac) converted to the same format. Audio never leaves
/// the device.
public final class AudioRecorder {
    public static let targetSampleRate = 22050.0
    /// Maximum take length: 10 minutes.
    public static let maxSamples = Int(targetSampleRate * 600)

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var peak: Float = 0
    public private(set) var isRecording = false

    /// Called on the audio thread with the current peak level (0...1).
    public var onLevel: ((Float) -> Void)?

    public init() {}

    public func start() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try session.setActive(true, options: [])
        #endif

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: Self.targetSampleRate,
                                   channels: 1, interleaved: false)!
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        peak = 0
        lock.unlock()

        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let n = Int(buffer.frameLength)
            guard n > 0, let channels = buffer.floatChannelData else { return }
            let ch = channels[0]
            var localPeak: Float = 0
            for i in 0..<n {
                let a = abs(ch[i])
                if a > localPeak { localPeak = a }
            }
            self.lock.lock()
            if self.samples.count < Self.maxSamples {
                self.samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: n))
            }
            if localPeak > self.peak { self.peak = localPeak } else { self.peak *= 0.999 }
            let p = self.peak
            self.lock.unlock()
            self.onLevel?(p)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    public func stop() -> [Float] {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        lock.lock()
        defer { lock.unlock() }
        isRecording = false
        return samples
    }

    public var recordedSampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count
    }

    public var recordedSeconds: Double {
        Double(recordedSampleCount) / Self.targetSampleRate
    }
}

/// Imports an audio file, converting to 22050 Hz mono float32.
public enum AudioImport {
    public static func loadMono22050(url: URL, maxSamples: Int = AudioRecorder.maxSamples) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        let dstFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: AudioRecorder.targetSampleRate,
                                      channels: 1, interleaved: false)!
        var out: [Float] = []
        out.reserveCapacity(min(Int(file.length), maxSamples))

        if srcFormat.sampleRate == dstFormat.sampleRate, srcFormat.channelCount == 1,
           srcFormat.commonFormat == .pcmFormatFloat32, !srcFormat.isInterleaved {
            // Fast path: already the target format.
            while out.count < maxSamples {
                let n = min(8192, maxSamples - out.count)
                guard let buf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(n)) else { break }
                try file.read(into: buf, frameCount: AVAudioFrameCount(n))
                if buf.frameLength == 0 { break }
                out.append(contentsOf: UnsafeBufferPointer(start: buf.floatChannelData![0],
                                                           count: Int(buf.frameLength)))
            }
            return out
        }

        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw ImportError.conversionFailed
        }
        var streamEnded = false
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            if streamEnded { outStatus.pointee = .endOfStream; return nil }
            let n = min(Int(inNumPackets), 8192)
            guard let buf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(n)) else {
                outStatus.pointee = .noDataNow
                return nil
            }
            do {
                try file.read(into: buf, frameCount: AVAudioFrameCount(n))
            } catch {
                outStatus.pointee = .noDataNow
                return nil
            }
            if buf.frameLength == 0 {
                streamEnded = true
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            return buf
        }

        while out.count < maxSamples {
            guard let dst = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: 8192) else { break }
            var err: NSError?
            let status = converter.convert(to: dst, error: &err, withInputFrom: inputBlock)
            if let err { throw err }
            if dst.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(start: dst.floatChannelData![0],
                                                           count: Int(dst.frameLength)))
            }
            if status == .endOfStream { break }
            if status == .inputRanDry { break }
        }
        return out
    }

    public enum ImportError: Error {
        case conversionFailed
    }
}
