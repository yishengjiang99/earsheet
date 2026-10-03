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

    public init(model: BasicPitchModel) {
        self.model = model
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

    /// Decode notes from the frames collected so far (no end-trim).
    /// For the live preview; the trailing edge may shift as audio arrives.
    public func liveNotes() -> [NoteEvent] {
        decode(frames: snapshot(trimmed: false))
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

    private func decode(frames: ([[Float]], [[Float]], [[Float]])) -> [NoteEvent] {
        let raw = BasicPitchDecoder.decode(frames: frames.0, onset: frames.1, contour: frames.2)
        return raw.map { r in
            NoteEvent(
                onset: BasicPitchDecoder.frameToTime(frame: r.startFrame),
                offset: BasicPitchDecoder.frameToTime(frame: r.endFrame),
                midi: r.midi,
                velocity: min(127, max(1, Int((127 * r.amplitude).rounded()))))
        }.sorted { $0.onset < $1.onset }
    }
}
