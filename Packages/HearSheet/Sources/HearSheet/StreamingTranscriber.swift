// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Incremental transcription for the live-listening screen.
///
/// Mirrors `Transcriber`'s windowing exactly (3840-sample front pad,
/// 36164-sample hop, 15 stripped frames per window edge), but runs inference
/// window-by-window as audio arrives and can decode notes from the frames
/// collected so far. `finalize()` applies the same end-trim as the batch
/// path, so the final result matches `Transcriber.transcribe` on the same
/// audio.
///
/// Threading: call `append` from anywhere (lock-protected). Call `pump` on
/// ONE dedicated serial queue — `BasicPitchModel` is not thread-safe.
/// Call `finish()` once on that queue when audio ends, then `finalize()`.
/// `liveNotes()` / `finalize()` only touch the frame buffers and may be
/// called from anywhere.
public final class StreamingTranscriber: @unchecked Sendable {
    private let model: BasicPitchModel
    private let lock = NSLock()
    private var padded: [Float] = []
    private var noteFrames: [[Float]] = []
    private var onsetFrames: [[Float]] = []
    private var contourFrames: [[Float]] = []
    private var nextWindow = 0
    private var audioSampleCount = 0
    public let thresholds: BasicPitchDecoder.Thresholds

    public init(model: BasicPitchModel, thresholds: BasicPitchDecoder.Thresholds = BasicPitchDecoder.Thresholds()) {
        self.model = model
        self.thresholds = thresholds
        padded = [Float](repeating: 0, count: Transcriber.frontPadSamples)
    }

    /// Append 22050 Hz mono samples. Thread-safe.
    public func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        padded.append(contentsOf: samples)
        audioSampleCount += samples.count
        lock.unlock()
    }

    public var sampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return audioSampleCount
    }

    /// Run inference for every window that is now complete.
    /// Must be called on a single serial queue.
    /// - Returns: number of new frames appended (0 when caught up).
    /// - Note: the trailing partial window is left for `finish()`.
    @discardableResult
    public func pump() throws -> Int {
        let windowSamples = HearSheet.windowSamples
        let hop = Transcriber.hopSamples
        let strip = Transcriber.stripFrames
        var newFrames = 0
        while true {
            lock.lock()
            let start = nextWindow * hop
            guard padded.count >= start + windowSamples else {
                lock.unlock()
                break
            }
            var window = [Float](repeating: 0, count: windowSamples)
            window.replaceSubrange(0..<windowSamples, with: padded[start..<(start + windowSamples)])
            nextWindow += 1
            lock.unlock()

            let post = try model.predict(waveform: window)

            lock.lock()
            noteFrames.append(contentsOf: post.note[strip..<(172 - strip)])
            onsetFrames.append(contentsOf: post.onset[strip..<(172 - strip)])
            contourFrames.append(contentsOf: post.contour[strip..<(172 - strip)])
            newFrames += Transcriber.usableFramesPerWindow
            lock.unlock()
        }
        return newFrames
    }

    /// Drain all remaining audio, then process the final partial window(s).
    ///
    /// Mirrors the batch path exactly: complete windows first (as in `pump()`),
    /// then `while start < padded.count`, zero-padding the last window to
    /// `windowSamples`. Without this, a take shorter than one window — or any
    /// take whose tail doesn't fill a window — would lose its trailing frames
    /// (batch `Transcriber.transcribe` always runs the ceiling-division
    /// window count). Must be called on the single serial queue, once, before
    /// `finalize()`.
    public func finish() throws {
        try pump()
        let windowSamples = HearSheet.windowSamples
        let hop = Transcriber.hopSamples
        let strip = Transcriber.stripFrames
        while true {
            lock.lock()
            let start = nextWindow * hop
            guard start < padded.count else {
                lock.unlock()
                break
            }
            let avail = min(windowSamples, padded.count - start)
            var window = [Float](repeating: 0, count: windowSamples)
            window.replaceSubrange(0..<avail, with: padded[start..<(start + avail)])
            nextWindow += 1
            lock.unlock()

            let post = try model.predict(waveform: window)

            lock.lock()
            noteFrames.append(contentsOf: post.note[strip..<(172 - strip)])
            onsetFrames.append(contentsOf: post.onset[strip..<(172 - strip)])
            contourFrames.append(contentsOf: post.contour[strip..<(172 - strip)])
            lock.unlock()
        }
    }

    /// Decode notes from the frames collected so far (no end-trim).
    /// For the live preview; the trailing edge may shift as audio arrives.
    /// - Parameter tailSeconds: decode only the most recent frames (the live staff shows a
    ///   rolling window), so the cost stays flat on long takes. nil decodes everything.
    public func liveNotes(tailSeconds: Double? = nil) -> [NoteEvent] {
        guard let tail = tailSeconds else { return decode(frames: snapshot(trimmed: false)) }
        // Copy only the tail under the lock (the full buffers grow to ~90 MB on a 10 min take).
        let keep = max(1, Int(tail * 22050.0 / 256.0))
        lock.lock()
        let first = max(0, noteFrames.count - keep)
        let n = Array(noteFrames[first...]), o = Array(onsetFrames[first...]), c = Array(contourFrames[first...])
        lock.unlock()
        return decode(frames: (n, o, c), frameOffset: first)
    }

    /// Final notes with the batch path's end-trim applied.
    public func finalize() -> [NoteEvent] {
        decode(frames: snapshot(trimmed: true))
    }

    private func snapshot(trimmed: Bool) -> ([[Float]], [[Float]], [[Float]]) {
        lock.lock()
        var n = noteFrames, o = onsetFrames, c = contourFrames
        let count = audioSampleCount
        lock.unlock()
        if trimmed {
            let keep = Int((Double(count) / Double(Transcriber.hopSamples))
                * Double(Transcriber.usableFramesPerWindow))
            if keep < n.count {
                n.removeLast(n.count - keep)
                o.removeLast(o.count - keep)
                c.removeLast(c.count - keep)
            }
        }
        return (n, o, c)
    }

    private func decode(frames: ([[Float]], [[Float]], [[Float]]), frameOffset: Int = 0) -> [NoteEvent] {
        let raw = BasicPitchDecoder.decode(frames: frames.0, onset: frames.1, contour: frames.2,
                                           thresholds: thresholds)
        return raw.map { r in
            NoteEvent(
                onset: BasicPitchDecoder.frameToTime(frame: r.startFrame + frameOffset),
                offset: BasicPitchDecoder.frameToTime(frame: r.endFrame + frameOffset),
                midi: r.midi,
                velocity: min(127, max(1, Int((127 * r.amplitude).rounded()))))
        }.sorted { $0.onset < $1.onset }
    }
}
