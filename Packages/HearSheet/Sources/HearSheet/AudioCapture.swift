// SPDX-License-Identifier: AGPL-3.0-or-later
import AVFoundation
import Foundation

/// Records from the microphone at 22050 Hz mono float32, or imports an audio
/// file (m4a / wav / aac) converted to the same format. Audio never leaves
/// the device.
public final class AudioRecorder {
    public static let targetSampleRate = 22050.0
    /// Maximum take length: 60 seconds.
    public static let maxSamples = Transcriber.maxSamples

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var peak: Float = 0
    private var observers: [NSObjectProtocol] = []
    /// High-pass + adaptive noise floor + noise gate on the 22050 Hz mono signal, before the
    /// level meter and the model. Settings are re-read from UserDefaults at each `start()`.
    private var conditioner = InputConditioner(sampleRate: AudioRecorder.targetSampleRate)
    private var floorSnapshot: Double?
    private var thresholdSnapshot = NoiseGate.Settings.default.thresholdDB
    private var floorSaved = false
    /// Hardware sample rate the current tap was installed with.
    private var tapSampleRate: Double = 0
    public private(set) var isRecording = false

    /// Called on the audio thread with the current peak level (0...1).
    public var onLevel: ((Float) -> Void)?

    /// Called on the audio thread with each tap's samples (a copy).
    /// Used by the live-listening screen to feed the streaming transcriber.
    public var onSamples: (([Float]) -> Void)?

    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: AudioRecorder.targetSampleRate,
                                       channels: 1, interleaved: false)!

    public init() {}

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Call from the main thread. A second call while recording is a no-op.
    public func start() throws {
        guard !isRecording else { return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try session.setActive(true, options: [])
        #endif

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        peak = 0
        lock.unlock()
        conditioner.configure(InputConditioner.Settings.load())
        conditioner.reset()
        floorSnapshot = nil
        thresholdSnapshot = conditioner.thresholdDB
        floorSaved = false

        do {
            try installTap()
            engine.prepare()
            try engine.start()
        } catch {
            // Leave nothing behind: a stale tap makes the next installTap raise.
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
            throw error
        }
        isRecording = true
        observe()
    }

    /// (Re)installs the input tap in the current hardware format with a fresh converter to
    /// 22050 Hz mono. An input-node tap must use the hardware format (48 kHz on current
    /// iPhones): asking for 22050 Hz raises "format.sampleRate == hwFormat.sampleRate".
    private func installTap() throws {
        let format = self.format
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0,
              let converter = AVAudioConverter(from: hwFormat, to: format) else {
            throw NSError(domain: "HearSheet.AudioRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No microphone input is available."])
        }
        let ratio = format.sampleRate / hwFormat.sampleRate
        tapSampleRate = hwFormat.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] hwBuffer, _ in
            guard let self else { return }
            let capacity = AVAudioFrameCount(Double(hwBuffer.frameLength) * ratio) + 64
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var fed = false
            var convError: NSError?
            converter.convert(to: buffer, error: &convError) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return hwBuffer
            }
            if convError != nil { return }
            let n = Int(buffer.frameLength)
            guard n > 0, let channels = buffer.floatChannelData else { return }
            let ch = channels[0]
            self.conditioner.process(ch, count: n) // audio thread only; reset/configured before the tap starts
            let floor = self.conditioner.noiseFloorDB, threshold = self.conditioner.thresholdDB
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
            if localPeak > self.peak { self.peak = localPeak } else { self.peak *= 0.999 }
            self.floorSnapshot = floor
            self.thresholdSnapshot = threshold
            let firstFloor = floor != nil && !self.floorSaved
            if firstFloor { self.floorSaved = true }
            let p = self.peak
            let emit = self.onSamples
            self.lock.unlock()
            self.onLevel?(p)
            if firstFloor, let floor { Self.saveFloor(floor) } // Settings › Microphone shows it
            if let emit, take > 0 {
                emit(Array(UnsafeBufferPointer(start: ch, count: take)))
            }
        }
    }

    /// Interruptions (calls, Siri), route changes (headphones, AirPods) and engine
    /// configuration changes stop the engine and can change the hardware sample rate:
    /// rebuild the tap + converter and restart, keeping the samples recorded so far.
    private func observe() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        let restart: (Notification) -> Void = { [weak self] note in
            #if os(iOS)
            if note.name == AVAudioSession.interruptionNotification {
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard raw.flatMap(AVAudioSession.InterruptionType.init) == .ended else { return }
            }
            #endif
            DispatchQueue.main.async { self?.restartIfRecording() }
        }
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil, using: restart))
        #if os(iOS)
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil, using: restart))
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil, using: restart))
        #endif
    }

    private func restartIfRecording() {
        guard isRecording else { return }
        // Still running in the same hardware format (e.g. a route change that kept the rate): nothing to do.
        if engine.isRunning, engine.inputNode.outputFormat(forBus: 0).sampleRate == tapSampleRate { return }
        engine.stop()
        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            #endif
            try installTap()
            engine.prepare()
            try engine.start()
        } catch {
            // Mic unavailable right now (e.g. still in a call): keep the audio so far; the
            // next route/interruption notification retries.
            engine.inputNode.removeTap(onBus: 0)
        }
    }

    public func stop() -> [Float] {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        lock.lock()
        defer { lock.unlock() }
        isRecording = false
        if let floorSnapshot { Self.saveFloor(floorSnapshot) }
        return samples
    }

    /// Ambient noise floor measured in this recording (RMS dBFS after the high-pass), nil
    /// during the first 0.5 s.
    public var noiseFloorDB: Double? {
        lock.lock(); defer { lock.unlock() }
        return floorSnapshot
    }

    /// Gate threshold in use (floor + margin with Auto on, else the manual threshold).
    public var gateThresholdDB: Double {
        lock.lock(); defer { lock.unlock() }
        return thresholdSnapshot
    }

    private static func saveFloor(_ db: Double) {
        DispatchQueue.main.async {
            UserDefaults.standard.set(db, forKey: InputConditioner.Settings.Keys.lastFloorDB)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: InputConditioner.Settings.Keys.lastFloorAt)
        }
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
        let sampleLimit = min(maxSamples, AudioRecorder.maxSamples)
        guard sampleLimit > 0 else { throw ImportError.durationLimitExceeded }
        if srcFormat.sampleRate > 0,
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
        case noAudioTrack
    }

    /// Extracts the audio track of a video asset (e.g. from the Photos
    /// library), resampled to 22050 Hz mono float32 by the reader itself.
    /// No intermediate file and no lossy transcode.
    public static func loadMono22050(asset: AVAsset,
                                    maxSamples: Int = AudioRecorder.maxSamples) throws -> [Float] {
        guard asset.tracks(withMediaType: .audio).first != nil else {
            throw ImportError.noAudioTrack
        }
        let sampleLimit = min(maxSamples, AudioRecorder.maxSamples)
        guard sampleLimit > 0 else { throw ImportError.durationLimitExceeded }
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite,
              seconds <= Double(sampleLimit) / AudioRecorder.targetSampleRate else {
            throw ImportError.durationLimitExceeded
        }
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw ImportError.noAudioTrack
        }
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ImportError.conversionFailed
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioRecorder.targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { throw ImportError.conversionFailed }
        reader.add(output)
        guard reader.startReading() else { throw ImportError.conversionFailed }

        var out: [Float] = []
        out.reserveCapacity(min(sampleLimit, Int(seconds * AudioRecorder.targetSampleRate)))
        while out.count < sampleLimit, let sample = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sample) }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length,
                                              dataPointerOut: &pointer) == kCMBlockBufferNoErr,
                  let base = pointer else { continue }
            let count = min(length / MemoryLayout<Float>.size, sampleLimit - out.count)
            guard count > 0 else { break }
            base.withMemoryRebound(to: Float.self, capacity: count) { floats in
                out.append(contentsOf: UnsafeBufferPointer(start: floats, count: count))
            }
        }
        if reader.status == .failed { throw ImportError.conversionFailed }
        return out
    }
}
