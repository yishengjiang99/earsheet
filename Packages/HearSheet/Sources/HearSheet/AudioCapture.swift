// SPDX-License-Identifier: AGPL-3.0-or-later
import AVFoundation
import Foundation

/// Records from the microphone at 22050 Hz mono float32, or imports an audio
/// file (m4a / wav / aac) converted to the same format. Audio never leaves
/// the device.
public final class AudioRecorder {
    public static let targetSampleRate = 22050.0
    /// Longest live take (10 minutes, `Transcriber.maxDurationSeconds`). At the limit the recorder
    /// stops keeping audio and calls `onLimitReached` once; callers stop and tell the user.
    public static let maxRecordingSeconds = Transcriber.maxDurationSeconds
    public static let maxSamples = Transcriber.maxSamples

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var peak: Float = 0
    public private(set) var isRecording = false

    /// Called on the audio thread with the current peak level (0...1).
    public var onLevel: ((Float) -> Void)?

    /// Called on the audio thread with each tap's samples (a copy).
    /// Used by the live-listening screen to feed the streaming transcriber.
    public var onSamples: (([Float]) -> Void)?

    /// Called once on the audio thread when the take reaches `maxRecordingSeconds`.
    public var onLimitReached: (() -> Void)?

    /// True once the current take hit `maxRecordingSeconds`.
    public var didReachLimit: Bool {
        lock.lock(); defer { lock.unlock() }
        return reachedLimit
    }
    private var reachedLimit = false

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
        reachedLimit = false
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
            let take = max(0, min(n, Self.maxSamples - self.samples.count))
            if take > 0 {
                self.samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: take))
            }
            let justHitLimit = !self.reachedLimit && self.samples.count >= Self.maxSamples
            if justHitLimit { self.reachedLimit = true }
            if localPeak > self.peak { self.peak = localPeak } else { self.peak *= 0.999 }
            let p = self.peak
            let emit = self.onSamples
            let limit = justHitLimit ? self.onLimitReached : nil
            self.lock.unlock()
            self.onLevel?(p)
            if let emit, take > 0 {
                emit(Array(UnsafeBufferPointer(start: ch, count: take)))
            }
            limit?()
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
    /// Duration of an audio file in seconds (nil if unreadable).
    public static func durationSeconds(url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// - Parameters:
    ///   - maxSamples: cap at 22050 Hz.
    ///   - truncate: true keeps the first `maxSamples` of a longer file (the free 30 s import);
    ///     false throws `durationLimitExceeded` instead.
    public static func loadMono22050(url: URL, maxSamples: Int = AudioRecorder.maxSamples,
                                     truncate: Bool = false) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        let dstFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: AudioRecorder.targetSampleRate,
                                      channels: 1, interleaved: false)!
        let sampleLimit = min(maxSamples, AudioRecorder.maxSamples)
        guard sampleLimit > 0 else { throw ImportError.durationLimitExceeded }
        if !truncate, srcFormat.sampleRate > 0,
           Double(file.length) / srcFormat.sampleRate > Double(sampleLimit) / dstFormat.sampleRate {
            throw ImportError.durationLimitExceeded
        }
        var out: [Float] = []
        out.reserveCapacity(min(Int(file.length), sampleLimit))

        if srcFormat.sampleRate == dstFormat.sampleRate, srcFormat.channelCount == 1,
           srcFormat.commonFormat == .pcmFormatFloat32, !srcFormat.isInterleaved {
            // Fast path: already the target format.
            // AVAudioFile.read(into:) throws (bridged as "nilError") when called at end of file
            // instead of returning 0 frames, so stop at file.length.
            while out.count < sampleLimit, file.framePosition < file.length {
                let n = min(8192, sampleLimit - out.count, Int(file.length - file.framePosition))
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
            if streamEnded || file.framePosition >= file.length {
                streamEnded = true
                outStatus.pointee = .endOfStream
                return nil
            }
            let n = min(Int(inNumPackets), 8192, Int(file.length - file.framePosition))
            guard let buf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(n)) else {
                outStatus.pointee = .noDataNow
                return nil
            }
            do {
                try file.read(into: buf, frameCount: AVAudioFrameCount(n))
            } catch {
                streamEnded = true
                outStatus.pointee = .endOfStream
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

        while out.count < sampleLimit {
            guard let dst = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: 8192) else { break }
            var err: NSError?
            let status = converter.convert(to: dst, error: &err, withInputFrom: inputBlock)
            if let err { throw err }
            if dst.frameLength > 0 {
                let count = min(Int(dst.frameLength), sampleLimit - out.count)
                out.append(contentsOf: UnsafeBufferPointer(start: dst.floatChannelData![0],
                                                           count: count))
            }
            if status == .endOfStream { break }
            if status == .inputRanDry { break }
        }
        return out
    }

    public enum ImportError: Error, Equatable {
        case durationLimitExceeded
        case conversionFailed
    }
}
