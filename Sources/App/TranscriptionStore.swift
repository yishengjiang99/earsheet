// SPDX-License-Identifier: AGPL-3.0-or-later
import AVFoundation
import Combine
import Foundation
import HearSheet
import SF2Player

/// Orchestrates record -> "Writing the page" -> page / play / share.
/// The package owns capture, inference, decode, quantize, MusicXML and
/// engraving; this object only drives UI state and SF2MIDIPlayer playback.
@MainActor
public final class TranscriptionStore: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case recording
        case writing(progress: Double)
        case ready
        case failed(message: String, offersImport: Bool)
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var elapsed: Double = 0
    @Published public private(set) var score: QuantizedScore?
    @Published public private(set) var activeNoteIDs: Set<Int> = []
    @Published public private(set) var notice: String?
    @Published public private(set) var isPlaying = false
    @Published public var showPianoRoll = false

    public let player = SF2MIDIPlayer()

    private let recorder = AudioRecorder()
    private let modelBox = ModelBox()
    private var cancellables = Set<AnyCancellable>()
    private var elapsedTimer: Timer?
    private var transcribeTask: Task<Void, Never>?

    public init() {
        player.$activeNoteIDs
            .sink { [weak self] in self?.activeNoteIDs = $0 }
            .store(in: &cancellables)
        player.$isPlaying
            .sink { [weak self] in self?.isPlaying = $0 }
            .store(in: &cancellables)
        player.onFinished = { [weak self] in
            self?.player.stop()
        }
    }

    // MARK: - Recording

    public func toggleRecord() {
        switch phase {
        case .recording: stopRecording()
        case .idle, .failed: startRecording()
        case .writing, .ready: break
        }
    }

    private func startRecording() {
        stopPlayback()
        score = nil
        notice = nil
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard granted else {
                    self.phase = .failed(
                        message: "Microphone access is denied. Enable it in Settings to record.",
                        offersImport: true)
                    return
                }
                do {
                    try self.recorder.start()
                    self.elapsed = 0
                    self.phase = .recording
                    self.startElapsedTimer()
                } catch {
                    self.phase = .failed(
                        message: "Could not start recording.",
                        offersImport: true)
                }
            }
        }
    }

    private func stopRecording() {
        stopElapsedTimer()
        let samples = recorder.stop()
        guard !samples.isEmpty else {
            phase = .failed(message: "The take was silent. Try again or import audio.",
                            offersImport: true)
            return
        }
        guard Transcriber.peakLevel(of: samples) >= 0.02 else {
            phase = .failed(message: "Too quiet to transcribe. Try again or import a file.",
                            offersImport: true)
            return
        }
        transcribe(samples: samples)
    }

    public func importAudio(url: URL) {
        stopPlayback()
        score = nil
        notice = nil
        transcribeTask?.cancel()
        phase = .writing(progress: 0)
        transcribeTask = Task.detached { [weak self] in
            guard let self else { return }
            let samples: [Float]
            do {
                samples = try AudioImport.loadMono22050(url: url)
            } catch {
                await MainActor.run {
                    self.phase = .failed(message: "Could not read that audio file.",
                                         offersImport: true)
                }
                return
            }
            guard !Task.isCancelled else { return }
            await self.runTranscription(samples: samples)
        }
    }

    private func transcribe(samples: [Float]) {
        transcribeTask?.cancel()
        phase = .writing(progress: 0)
        transcribeTask = Task.detached { [weak self] in
            guard let self else { return }
            await self.runTranscription(samples: samples)
        }
    }

    private func runTranscription(samples: [Float]) async {
        do {
            let notes = try await Task.detached(priority: .userInitiated) { [modelBox] in
                let model = try modelBox.get(modelsDirectory: BundledModels.modelsDirectory())
                return try Transcriber.transcribe(samples: samples, model: model) { p in
                    Task { @MainActor [weak self] in
                        guard let self, case .writing = self.phase else { return }
                        self.phase = .writing(progress: p)
                    }
                }
            }.value
            guard !Task.isCancelled else { return }
            let q = Quantizer.quantize(notes)
            await MainActor.run {
                if q.notes.isEmpty {
                    self.phase = .failed(message: "No notes found. Try again or import audio.",
                                         offersImport: true)
                } else {
                    self.score = q
                    self.phase = .ready
                }
            }
        } catch is CancellationError {
        } catch {
            await MainActor.run {
                self.phase = .failed(message: "Could not write the page: \(error.localizedDescription)",
                                     offersImport: true)
            }
        }
    }

    public func newTake() {
        transcribeTask?.cancel()
        stopPlayback()
        score = nil
        notice = nil
        phase = .idle
    }

    public func clearNotice() {
        notice = nil
    }

    // MARK: - Playback (SF2MIDIPlayer)

    public func togglePlay() {
        if player.isPlaying {
            player.pause()
            return
        }
        guard let score else { return }
        Task {
            do {
                let sf = try await BundledModels.soundFont()
                try player.load(soundFont: sf)
                let midi = SMFWriter.data(
                    notes: score.notes,
                    tempoBPM: score.tempoBPM,
                    timeSignature: SMFWriter.TimeSignature(
                        numerator: score.meter.beatsPerBar,
                        denominator: score.meter.beatUnit))
                try player.load(midi: midi)
                // The player reports these ids back via activeNoteIDs; the
                // staff view highlights them as the playhead.
                player.notePositions = score.notes.enumerated().map { i, n in
                    SF2NotePosition(id: i,
                                    startTick: n.start16 * QuantizedScore.ticksPer16th,
                                    endTick: (n.start16 + n.duration16) * QuantizedScore.ticksPer16th)
                }
                player.play()
            } catch {
                notice = "Playback failed: \(error.localizedDescription)"
            }
        }
    }

    public func stopPlayback() {
        if player.isPlaying { player.stop() }
        activeNoteIDs = []
    }

    // MARK: - Share

    public func shareItems() -> [Any] {
        guard let score else { return [] }
        let midi = SMFWriter.data(
            notes: score.notes,
            tempoBPM: score.tempoBPM,
            timeSignature: SMFWriter.TimeSignature(
                numerator: score.meter.beatsPerBar,
                denominator: score.meter.beatUnit))
        let xml = MusicXMLWriter.xml(score: score)
        let pdf = Engraver.pdfData(score: score, pageSize: CGSize(width: 612, height: 792))
        let dir = FileManager.default.temporaryDirectory
        let files: [(String, Data)] = [
            ("EarSheet.mid", midi),
            ("EarSheet.musicxml", Data(xml.utf8)),
            ("EarSheet.pdf", pdf),
        ]
        var urls: [URL] = []
        for (name, data) in files {
            let url = dir.appendingPathComponent(name, isDirectory: false)
            do {
                try data.write(to: url, options: .atomic)
                urls.append(url)
            } catch {
                notice = "Could not prepare \(name) for sharing."
            }
        }
        return urls
    }

    // MARK: - Private

    private final class ModelBox: Sendable {
        private let lock = NSLock()
        private var model: BasicPitchModel?
        func get(modelsDirectory: URL) throws -> BasicPitchModel {
            lock.lock()
            defer { lock.unlock() }
            if let m = model { return m }
            let m = try BasicPitchModel(modelsDirectory: modelsDirectory)
            model = m
            return m
        }
    }

    private func startElapsedTimer() {
        stopElapsedTimer()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, case .recording = self.phase else { return }
                self.elapsed = self.recorder.recordedSeconds
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }
}
