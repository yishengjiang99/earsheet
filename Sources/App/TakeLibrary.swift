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
    var score: QuantizedScore
    var isSample: Bool

    // Navigation value: hash by identity (equal takes always share an id).
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var durationSeconds: Double {
        guard let last = score.notes.max(by: { $0.start16 < $1.start16 }) else { return 0 }
        return Double(last.start16 + last.duration16) * score.secondsPer16th
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

    /// Free keeps `AppConfig.Free.savedTakes` pieces; Pro is unlimited.
    func canSaveMore(isPro: Bool) -> Bool {
        isPro || takes.count < AppConfig.Free.savedTakes
    }

    /// A take that isn't in the library yet (shown, playable, shareable; saved by `save(_:)`).
    func makeTake(title: String? = nil, score: QuantizedScore) -> Take {
        Take(id: UUID(),
             title: title ?? "Take \(takes.count + 1)",
             createdAt: Date(),
             score: score,
             isSample: false)
    }

    func isSaved(_ take: Take) -> Bool { takes.contains { $0.id == take.id } }

    func save(_ take: Take) {
        guard !take.isSample, !isSaved(take) else { return }
        takes.insert(take, at: 0)
        save()
        Telemetry.shared.track(.takeSaved, ["count": takes.count])
    }

    func addTake(title: String? = nil, score: QuantizedScore) -> Take {
        let take = makeTake(title: title, score: score)
        save(take)
        return take
    }

    func delete(_ take: Take) {
        stopPlayback()
        takes.removeAll { $0.id == take.id }
        save()
        Telemetry.shared.track(.takeDeleted, ["count": takes.count])
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
                              score: score, isSample: true))
        }
        self.samples = built
        self.samplesReady = true
    }

    // MARK: - Playback (SF2Player, the vendored omr-sheet-cam package)

    func togglePlay(_ take: Take) {
        if playingTakeID == take.id {
            if player.isPlaying { player.pause() } else { player.play() }
            return
        }
        stopPlayback()
        Task {
            do {
                let sf = try await BundledModels.soundFont()
                try player.load(soundFont: sf)
                try player.load(midi: MIDISupport.data(for: take.score))
                // Ids are score note indices; the staff highlights them back.
                player.notePositions = take.score.notes.enumerated().map { i, n in
                    SF2NotePosition(id: i,
                                    startTick: n.start16 * QuantizedScore.ticksPer16th,
                                    endTick: (n.start16 + n.duration16) * QuantizedScore.ticksPer16th)
                }
                playingTakeID = take.id
                player.play()
                Telemetry.shared.track(.playbackStart, ["sample": take.isSample])
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
