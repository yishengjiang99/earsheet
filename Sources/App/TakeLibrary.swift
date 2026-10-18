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
    /// Folder holding takes.json and the session WAVs (Application Support unless a test injects one).
    let directory: URL
    /// Set when an unreadable library file could not be preserved: saving stays off so it is never overwritten.
    private var saveBlocked = false

    init(directory: URL = TakeLibrary.defaultDirectory) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        player.$activeNoteIDs
            .sink { [weak self] in self?.activeNoteIDs = $0 }
            .store(in: &cancellables)
        player.$isPlaying
            .sink { [weak self] in self?.isPlaying = $0 }
            .store(in: &cancellables)
        player.onFinished = { [weak self] in self?.player.stop() }
        // Sweep only after a clean load: an unreadable file means references are unknown.
        if load() {
            Self.sweepUnreferencedAudio(in: directory, keeping: Set(takes.compactMap(\.audioFileName)))
        }
        Task { await self.loadSamples() }
    }

    // MARK: - Takes

    var userTakes: [Take] { takes }

    /// "Take N" with N one more than the highest "Take N" in `titles` (not the count, so deleting
    /// "Take 2" of three and recording again gives "Take 4", never a second "Take 3").
    nonisolated static func nextDefaultTitle(among titles: [String]) -> String {
        let prefix = "Take "
        let highest = titles.compactMap { title -> Int? in
            guard title.hasPrefix(prefix) else { return nil }
            return Int(title.dropFirst(prefix.count))
        }.max() ?? 0
        return "\(prefix)\(highest + 1)"
    }

    /// Builds a take (default title included) without adding it to the library.
    func makeTake(title: String? = nil, score: QuantizedScore, events: [NoteEvent]? = nil,
                  audioFileName: String? = nil) -> Take {
        Take(id: UUID(),
             title: title ?? Self.nextDefaultTitle(among: takes.map(\.title)),
             createdAt: Date(),
             score: score,
             isSample: false,
             events: events,
             audioFileName: audioFileName)
    }

    func addTake(title: String? = nil, score: QuantizedScore, events: [NoteEvent]? = nil,
                 audioFileName: String? = nil) -> Take {
        let take = makeTake(title: title, score: score, events: events, audioFileName: audioFileName)
        takes.insert(take, at: 0)
        save()
        return take
    }

    /// Registers a take held by the free save limit so views can show and analyze it
    /// without it being in My Takes (`importTake` saves it after an upgrade).
    func hold(_ take: Take) { looseTakes[take.id] = take }

    /// Drops a held take (and its session audio, if any) without saving it.
    func discardHeld(_ take: Take) {
        looseTakes.removeValue(forKey: take.id)
        if let name = take.audioFileName {
            try? FileManager.default.removeItem(at: audioURL(for: name))
        }
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
            try? FileManager.default.removeItem(at: audioURL(for: name))
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
                notice = UserFacingError.message(for: error, context: .playback)
            }
        }
    }

    func stopPlayback() {
        if player.isPlaying { player.stop() }
        playingTakeID = nil
        activeNoteIDs = []
    }

    // MARK: - Persistence

    private var storeURL: URL { directory.appendingPathComponent("takes.json", isDirectory: false) }

    /// Application Support/<bundle id>, created on demand.
    nonisolated static var defaultDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(HearSheet.bundleIdentifier, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// URL of a take's session-audio WAV in the library's Application Support dir.
    /// Nonisolated: touches only FileManager, no actor state.
    nonisolated static func audioURL(fileName: String) -> URL {
        defaultDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// URL of a session-audio WAV in this library's directory.
    func audioURL(for fileName: String) -> URL {
        directory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Decodes a library file element by element so one bad element does not lose the rest.
    /// nil when the data is not a JSON array at all; `skipped` counts undecodable elements.
    nonisolated static func decodeTakes(_ data: Data) -> (takes: [Take], skipped: Int)? {
        if let all = try? JSONDecoder().decode([Take].self, from: data) { return (all, 0) }
        guard let items = try? JSONDecoder().decode([FailableTake].self, from: data) else { return nil }
        let valid = items.compactMap(\.take)
        return (valid, items.count - valid.count)
    }

    private struct FailableTake: Decodable {
        let take: Take?
        init(from decoder: Decoder) throws { take = try? Take(from: decoder) }
    }

    /// Loads takes.json. Returns true when the library is fully known (no file, or every element decoded).
    @discardableResult
    private func load() -> Bool {
        let url = storeURL
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        guard let data = try? Data(contentsOf: url) else {
            preserveUnreadable(url, move: true)
            postNotice("Your saved takes could not be read. The file was kept as a backup.")
            return false
        }
        guard let decoded = Self.decodeTakes(data) else {
            preserveUnreadable(url, move: true)
            postNotice("Your saved takes could not be read. The file was kept as a backup.")
            return false
        }
        takes = decoded.takes
        if decoded.skipped > 0 {
            preserveUnreadable(url, move: false)
            postNotice("\(decoded.skipped) saved take\(decoded.skipped == 1 ? "" : "s") could not be read and "
                       + "\(decoded.skipped == 1 ? "was" : "were") skipped. A backup of the original file was kept.")
            return false
        }
        return true
    }

    /// Deletes session WAVs in `dir` that no take references (leftovers of failed or discarded sessions;
    /// the folder is included in device backups). Returns how many files were removed.
    @discardableResult
    nonisolated static func sweepUnreferencedAudio(in dir: URL, keeping referenced: Set<String>) -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return 0 }
        var removed = 0
        for file in files where file.pathExtension.lowercased() == "wav" && !referenced.contains(file.lastPathComponent) {
            if (try? fm.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    /// Keeps the original bytes as takes.corrupt-<timestamp>.json before anything can overwrite them.
    /// If that fails, saving is switched off for this launch rather than risk the file.
    private func preserveUnreadable(_ url: URL, move: Bool) {
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let backup = directory.appendingPathComponent("takes.corrupt-\(stamp).json", isDirectory: false)
        do {
            if move {
                try FileManager.default.moveItem(at: url, to: backup)
            } else {
                try FileManager.default.copyItem(at: url, to: backup)
            }
        } catch {
            saveBlocked = true
        }
    }

    private func save() {
        guard !saveBlocked else {
            postNotice("Your saved takes file could not be backed up, so changes are not being saved right now. Restart the app.")
            return
        }
        do {
            let data = try JSONEncoder().encode(takes)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            postNotice(UserFacingError.message(for: error, context: .saveLibrary))
        }
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
