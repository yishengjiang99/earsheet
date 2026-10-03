// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Batched, anonymous product analytics -> `POST /api/telemetry/batch` (docs/telemetry.md).
///
/// Never sends audio, notes, titles, file names or anything a user typed: only event names plus
/// small scalar properties (product IDs, counts, durations, StoreKit error codes). Keyed by the
/// random Keychain `installId`. Events are queued on disk (survive offline and kills), flushed
/// every 30 s in the foreground, at 50 queued events, and when the app goes to the background.
/// A batch is removed only after a 2xx; 429 honors `Retry-After`; 5xx / offline back off
/// exponentially (5 s → 10 min); 400/413 drop the batch. Users can switch it off in Settings,
/// which clears the queue.
final class Telemetry: @unchecked Sendable {
    /// Unit-test hosts never queue or send real events.
    static let shared = Telemetry(enabled: {
        Telemetry.isEnabled && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    })

    /// Event names (keep in sync with docs/telemetry.md).
    enum Event: String, CaseIterable {
        case appOpen = "app_open"
        case sessionStart = "session_start"
        case sessionEnd = "session_end"
        case onboardingComplete = "onboarding_complete"
        case micPermissionPrompt = "mic_permission_prompt"
        case micPermissionGranted = "mic_permission_granted"
        case micPermissionDenied = "mic_permission_denied"
        case transcriptionStart = "transcription_start"
        case transcriptionStop = "transcription_stop"
        case transcriptionCancel = "transcription_cancel"
        case recordingLimitReached = "recording_limit_reached"
        case fileImport = "file_import"
        case takeSaved = "take_saved"
        case takeDeleted = "take_deleted"
        case exportMidi = "export_midi"
        case exportMusicXML = "export_musicxml"
        case exportPdf = "export_pdf"
        case exportMp3 = "export_mp3"
        case exportPhoto = "export_photo"
        case playbackStart = "playback_start"
        case paywallView = "paywall_view"
        case paywallDismiss = "paywall_dismiss"
        case paywallPlanSelect = "paywall_plan_select"
        case paywallTriggerSuppressed = "paywall_trigger_suppressed"
        case purchaseStart = "purchase_start"
        case purchaseSuccess = "purchase_success"
        case purchaseFail = "purchase_fail"
        case purchaseCancel = "purchase_cancel"
        case purchasePending = "purchase_pending"
        case trialStart = "trial_start"
        case restoreStart = "restore_start"
        case restoreSuccess = "restore_success"
        case restoreFail = "restore_fail"
        case pushPermissionPrompt = "push_permission_prompt"
        case pushPermissionGranted = "push_permission_granted"
        case pushPermissionDenied = "push_permission_denied"
        case error = "error"
    }

    static let enabledKey = "TelemetryEnabled"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if !newValue { shared.clear() }
        }
    }

    struct Queued: Codable, Equatable {
        var id: UUID
        var event: APIClient.TelemetryEvent
    }

    static let maxQueued = 5000
    static let batchSize = 100
    static let flushThreshold = 50
    static let sessionTimeout: TimeInterval = 30 * 60

    private let queue = DispatchQueue(label: "com.ragnus.pnge.telemetry")
    private var pending: [Queued] = []
    private var flushing = false
    private var nextAttempt = Date.distantPast
    private var backoff: TimeInterval = 0
    private var timer: DispatchSourceTimer?
    private(set) var sessionId = UUID()
    private var sessionStarted = false
    private var sessionStartedAt = Date()
    private var backgroundedAt: Date?
    private let client: APIClient
    private let storeURL: URL
    private let enabled: () -> Bool

    init(client: APIClient = .shared, storeURL: URL? = nil, enabled: (() -> Bool)? = nil) {
        self.client = client
        self.enabled = enabled ?? { Telemetry.isEnabled }
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.storeURL = dir.appendingPathComponent("telemetry-queue.json")
        }
        queue.sync { self.load() }
    }

    /// Starts the 30 s foreground flush timer (idempotent).
    func start() {
        queue.async {
            guard self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 30, repeating: 30)
            t.setEventHandler { [weak self] in self?.flushLocked() }
            t.resume()
            self.timer = t
        }
    }

    /// New session on launch and after more than 30 minutes in the background.
    func appDidBecomeActive() {
        queue.async {
            let now = Date()
            let expired = self.backgroundedAt.map { now.timeIntervalSince($0) > Self.sessionTimeout } ?? false
            if !self.sessionStarted || expired {
                if self.sessionStarted, let bg = self.backgroundedAt {
                    self.enqueueLocked(.sessionEnd, ["duration_s": bg.timeIntervalSince(self.sessionStartedAt).rounded()])
                }
                self.sessionId = UUID()
                self.sessionStarted = true
                self.sessionStartedAt = now
                self.enqueueLocked(.sessionStart, [:])
            }
            self.backgroundedAt = nil
        }
    }

    /// Flushes now; `completion` runs on the telemetry queue once the attempt finishes
    /// (use it to end a UIKit background task).
    func appDidEnterBackground(completion: (@Sendable () -> Void)? = nil) {
        queue.async {
            self.backgroundedAt = Date()
            self.nextAttempt = .distantPast
            self.flushLocked(force: true, completion: completion)
        }
    }

    func track(_ event: Event, _ properties: [String: Any] = [:]) {
        queue.async { self.enqueueLocked(event, properties) }
    }

    func flush(completion: (@Sendable () -> Void)? = nil) {
        queue.async { self.flushLocked(force: true, completion: completion) }
    }

    func clear() {
        queue.async {
            self.pending.removeAll()
            self.save()
        }
    }

    /// Flat scalars only (server rule); strings capped at 200 chars; everything else dropped.
    static func sanitize(_ props: [String: Any]) -> [String: APIClient.TelemetryValue]? {
        var out: [String: APIClient.TelemetryValue] = [:]
        for (k, v) in props.prefix(40) {
            switch v {
            case let b as Bool: out[k] = .bool(b)
            case let i as Int: out[k] = .number(Double(i))
            case let d as Double: if d.isFinite { out[k] = .number((d * 1000).rounded() / 1000) }
            case let f as Float: if f.isFinite { out[k] = .number(Double(f)) }
            case let s as String: out[k] = .string(String(s.prefix(200)))
            case let s as Substring: out[k] = .string(String(s.prefix(200)))
            default: continue
            }
        }
        return out.isEmpty ? nil : out
    }

    var pendingCount: Int { queue.sync { pending.count } }
    var pendingEvents: [APIClient.TelemetryEvent] { queue.sync { pending.map(\.event) } }

    // MARK: - Private (on `queue`)

    private func enqueueLocked(_ event: Event, _ properties: [String: Any]) {
        guard enabled() else { return }
        pending.append(Queued(id: UUID(), event: APIClient.TelemetryEvent(
            name: event.rawValue,
            ts: (Date().timeIntervalSince1970 * 1000).rounded(),
            installId: InstallIdentity.installId.uuidString.lowercased(),
            sessionId: sessionId.uuidString.lowercased(),
            appVersion: AppConfig.appVersion,
            properties: Self.sanitize(properties))))
        if pending.count > Self.maxQueued { pending.removeFirst(pending.count - Self.maxQueued) }
        save()
        if pending.count >= Self.flushThreshold { flushLocked() }
    }

    private func flushLocked(force: Bool = false, completion: (@Sendable () -> Void)? = nil) {
        guard enabled(), !flushing, !pending.isEmpty, force || Date() >= nextAttempt else {
            completion?()
            return
        }
        let batch = Array(pending.prefix(Self.batchSize))
        flushing = true
        let client = self.client
        Task.detached(priority: .utility) { [weak self] in
            enum Outcome { case sent, drop, retry(TimeInterval?) }
            let outcome: Outcome
            do {
                _ = try await client.sendTelemetry(batch.map(\.event))
                outcome = .sent
            } catch APIClient.APIError.http(let code, _, let retryAfter) {
                if code == 429 { outcome = .retry(retryAfter ?? 60) }
                else if (400..<500).contains(code) { outcome = .drop } // malformed / too large: never retry forever
                else { outcome = .retry(nil) }
            } catch {
                outcome = .retry(nil) // offline / decoding of a proxy page
            }
            guard let self else { completion?(); return }
            self.queue.async {
                self.flushing = false
                switch outcome {
                case .sent, .drop:
                    let ids = Set(batch.map(\.id))
                    self.pending.removeAll { ids.contains($0.id) }
                    self.backoff = 0
                    self.nextAttempt = .distantPast
                    self.save()
                case .retry(let after):
                    self.backoff = min(600, max(5, self.backoff * 2))
                    self.nextAttempt = Date().addingTimeInterval(after ?? self.backoff)
                }
                completion?()
                if case .sent = outcome, self.pending.count >= Self.flushThreshold { self.flushLocked() }
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let list = try? JSONDecoder().decode([Queued].self, from: data) else { return }
        // The server rejects events older than 30 days.
        let cutoff = (Date().timeIntervalSince1970 - 29 * 86400) * 1000
        pending = list.filter { $0.event.ts > cutoff }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
