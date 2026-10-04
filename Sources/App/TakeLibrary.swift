// SPDX-License-Identifier: AGPL-3.0-or-later
import Combine
import Foundation
import HearSheet
import SF2Player

/// A saved transcription: a quantized score plus metadata.
struct Take: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var createdAt: Date
    /// Playback / piano-roll grid (quantized when the take was made). Not shown as tempo/key.
    var score: QuantizedScore
    var isSample: Bool
    /// Raw detected notes in seconds (nil for takes saved before they were kept).
    var events: [NoteEvent]? = nil
    /// Session mic-audio WAV filename in the library's Application Support dir
    /// (nil for takes recorded before it was kept, imports, and samples).
    var audioFileName: String? = nil
    /// Tempo the user assumed for the sheet (quarter-note BPM); nil = estimated.
    var tempoOverride: Double? = nil
    /// Sheet-music analysis (tempo, meter, key, quantization), computed on request only.
    var sheet: QuantizedScore? = nil
    /// `analysisKey` the cached `sheet` was computed from.
    var sheetSource: UInt64? = nil

    // Navigation value: hash by identity (equal takes always share an id).
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var durationSeconds: Double {
        guard let last = score.notes.max(by: { $0.start16 < $1.start16 }) else { return 0 }
        return Double(last.start16 + last.duration16) * score.secondsPer16th
    }

    var noteEvents: [NoteEvent] { events ?? Quantizer.events(from: score) }

    /// Stable (cross-launch) key of what the analysis depends on: the notes and the assumed tempo.
    var analysisKey: UInt64 {
        var h: UInt64 = 0xcbf29ce484222325 // FNV-1a
        func mix(_ v: UInt64) { h = (h ^ v) &* 0x100000001b3 }
        for e in noteEvents {
            mix(e.onset.bitPattern); mix(e.offset.bitPattern); mix(UInt64(bitPattern: Int64(e.midi))); mix(UInt64(bitPattern: Int64(e.velocity)))
        }
        mix((tempoOverride ?? -1).bitPattern)
        return h
    }

    /// The cached sheet analysis if it is current, without computing it.
    var currentSheet: QuantizedScore? { sheetSource == analysisKey ? sheet : nil }

    /// Returns the sheet analysis, running it only if there is no current cached one.
    mutating func analyzeSheet() -> (score: QuantizedScore, computed: Bool) {
        if let s = currentSheet { return (s, false) }
        let s = Quantizer.quantize(noteEvents, tempoBPM: tempoOverride)
        sheet = s
        sheetSource = analysisKey
        return (s, true)
    }
}

/// The take library: built-in samples + the user's recorded/imported takes,
/// persisted as JSON in Application Support. Also owns SF2 playback so rows
/// and the detail screen share one player.
@MainActor
final class TakeLibrary: ObservableObject {
    @Published private(set) var takes: [Take] = []
    @Published private(set) var samples: [Take] = []
    @Published private(set) var playingTakeID: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var activeNoteIDs: Set<Int> = []
    @Published private(set) var notice: String?
    @Published private(set) var samplesReady = false

    let player = SF2MIDIPlayer()
    private var cancellables = Set<AnyCancellable>()

    init() {
        player.$activeNoteIDs
            .sink { [weak self] in self?.activeNoteIDs = $0 }
            .store(in: &cancellables)
        player.$isPlaying
            .sink { [weak self] in self?.isPlaying = $0 }
            .store(in: &cancellables)
        player.onFinished = { [weak self] in self?.player.stop() }
        load()
        Task { await self.loadSamples() }
    }

    // MARK: - Takes

    var userTakes: [Take] { takes }

    func addTake(title: String? = nil, score: QuantizedScore, events: [NoteEvent]? = nil,
                 audioFileName: String? = nil) -> Take {
        let take = Take(id: UUID(),
                        title: title ?? "Take \(takes.count + 1)",
                        createdAt: Date(),
                        score: score,
                        isSample: false,
                        events: events,
                        audioFileName: audioFileName)
        takes.insert(take, at: 0)
        save()
        return take
    }

    /// Analysis state for takes not in the library (e.g. one held by the free save limit).
    @Published private var looseTakes: [UUID: Take] = [:]

    /// Latest stored version of a take (views hold value copies).
    func current(_ take: Take) -> Take {
        takes.first { $0.id == take.id } ?? samples.first { $0.id == take.id } ?? looseTakes[take.id] ?? take
    }

    /// Sheet analysis for the Page view and exports: computed on first request, cached on the
    /// take (persisted), recomputed only when its notes or assumed tempo change.
    /// Call from actions, not from `body` (it may publish a change).
    @discardableResult
    func sheetScore(for take: Take) -> QuantizedScore {
        let stored = current(take)
        if let cached = stored.currentSheet { return cached } // no mutation, nothing published
        analysisRuns += 1
        var t = stored
        let s = t.analyzeSheet().score
        if let i = takes.firstIndex(where: { $0.id == take.id }) {
            takes[i] = t
            save()
        } else if let i = samples.firstIndex(where: { $0.id == take.id }) {
            samples[i] = t
        } else {
            looseTakes[take.id] = t
        }
        return s
    }

    /// Number of sheet analyses run (diagnostics/tests: the analysis is lazy and cached).
    private(set) var analysisRuns = 0

    /// The tempo the analysis estimates on its own (for "Use estimated").
    func estimatedTempo(for take: Take) -> Double {
        Quantizer.quantize(current(take).noteEvents).tempoBPM
    }

    /// Sets (or clears) the assumed tempo; the sheet is re-analyzed on the next request.
    func setTempo(_ bpm: Double?, for take: Take) {
        let value = bpm.map { min(Quantizer.tempoRange.upperBound, max(Quantizer.tempoRange.lowerBound, $0.rounded())) }
        if let i = takes.firstIndex(where: { $0.id == take.id }) {
            takes[i].tempoOverride = value
            save()
        } else if let i = samples.firstIndex(where: { $0.id == take.id }) {
            samples[i].tempoOverride = value
        } else {
            var t = current(take)
            t.tempoOverride = value
            looseTakes[take.id] = t
        }
    }

    /// Insert an already-built Take (e.g. a take held pending a Pro upgrade).
    func importTake(_ take: Take) {
        // Keep any analysis / assumed tempo made while it was held.
        takes.insert(looseTakes.removeValue(forKey: take.id) ?? take, at: 0)
        save()
    }

    func delete(_ take: Take) {
        stopPlayback()
        if let name = take.audioFileName {
            try? FileManager.default.removeItem(at: Self.audioURL(fileName: name))
        }
        takes.removeAll { $0.id == take.id }
        save()
    }

    func clearNotice() { notice = nil }

    func postNotice(_ message: String) { notice = message }

    // MARK: - Samples

    private func loadSamples() async {
        let pairs = [SampleScores.cMajorScale, SampleScores.swedishFolkTune]
        var built: [Take] = []
        for pair in pairs {
            let score = await Task.detached(priority: .userInitiated) {
                Quantizer.quantize(pair.notes)
            }.value
            built.append(Take(id: UUID(), title: pair.title, createdAt: Date(),
                              score: score, isSample: true, events: pair.notes))
        }
        self.samples = built
        self.samplesReady = true
    }

    // MARK: - Playback (SF2Player, the vendored omr-sheet-cam package)

    /// Plays `score` (default: the take's playback score). Note ids are indices into it.
    func togglePlay(_ take: Take, score: QuantizedScore? = nil) {
        let score = score ?? take.score
        if playingTakeID == take.id {
            if player.isPlaying { player.pause() } else { player.play() }
            return
        }
        stopPlayback()
        Task {
            do {
                let sf = try await BundledModels.soundFont()
                try player.load(soundFont: sf)
                try player.load(midi: MIDISupport.data(for: score))
                // Ids are score note indices; the staff highlights them back.
                player.notePositions = score.notes.enumerated().map { i, n in
                    SF2NotePosition(id: i,
                                    startTick: n.start16 * QuantizedScore.ticksPer16th,
                                    endTick: (n.start16 + n.duration16) * QuantizedScore.ticksPer16th)
                }
                playingTakeID = take.id
                player.play()
            } catch {
                notice = "Playback failed: \(error.localizedDescription)"
            }
        }
    }

    func stopPlayback() {
        if player.isPlaying { player.stop() }
        playingTakeID = nil
        activeNoteIDs = []
    }

    // MARK: - Persistence

    private func storeURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(HearSheet.bundleIdentifier, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("takes.json", isDirectory: false)
    }

    /// URL of a take's session-audio WAV in the library's Application Support dir.
    static func audioURL(fileName: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(HearSheet.bundleIdentifier, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName, isDirectory: false)
    }

    private func load() {
        let url = storeURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Take].self, from: data)
        else { return }
        takes = decoded
    }

    private func save() {
        let url = storeURL()
        guard let data = try? JSONEncoder().encode(takes) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// MIDI bytes for a score, shared by playback and export.
enum MIDISupport {
    static func data(for score: QuantizedScore) -> Data {
        SMFWriter.data(
            notes: score.notes,
            tempoBPM: score.tempoBPM,
            timeSignature: SMFWriter.TimeSignature(
                numerator: score.meter.beatsPerBar,
                denominator: score.meter.beatUnit))
    }
}
