// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// One analytics event as sent to `POST /api/telemetry/batch` (docs/telemetry.md).
struct TelemetryEvent: Codable, Equatable {
    var name: String
    /// Epoch milliseconds.
    var ts: Int64
    /// The anonymous Keychain install UUID: the only identifier in a payload.
    var installId: String
    /// Random per-foreground-session UUID (not a device identifier).
    var sessionId: String?
    var appVersion: String?
    var properties: [String: TelemetryValue]?
}

enum TelemetryValue: Codable, Equatable {
    case string(String), int(Int), double(Double), bool(Bool)

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else { self = .string(try c.decode(String.self)) }
    }
}

/// Batched, anonymous product analytics.
///
/// Privacy: no audio, no note content, no titles, file names or anything typed. Only the event
/// name, a timestamp, the install UUID, a session UUID, the app version and a few scalar
/// properties from `allowedPropertyKeys` (anything else is dropped before it is queued).
/// Events queue on disk (offline-safe) and are sent on each heartbeat (`ServerSync`) and when
/// the app goes to the background. A batch is removed only after a 2xx, or dropped on a
/// 400/413 (malformed, never retried forever). Opting out in Settings clears the queue and
/// suppresses all queuing and sending.
final class Telemetry: @unchecked Sendable {
    enum Event: String, CaseIterable {
        case appOpen = "app_open"
        case sessionStart = "session_start"
        case transcriptionStart = "transcription_start"
        case transcriptionStop = "transcription_stop"
        case paywallView = "paywall_view"
        case purchaseStart = "purchase_start"
        case purchaseSuccess = "purchase_success"
        case purchaseFail = "purchase_fail"
        case restore = "restore"
    }

    /// The only property keys that may leave the phone.
    static let allowedPropertyKeys: Set<String> = [
        "cold", "source", "duration_s", "notes", "product", "reason", "code", "result", "restored",
    ]
    static let maxQueued = 5000
    static let batchSize = 100
    static let optOutKey = "telemetry.optedOut"
    static let sessionTimeout: TimeInterval = 30 * 60

    static let shared = Telemetry(client: .shared, storeURL: Telemetry.defaultStoreURL)

    static var defaultStoreURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EarSheet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("telemetry-queue.json")
    }

    private let client: APIClient
    private let storeURL: URL
    private let defaults: UserDefaults
    private let installId: () -> String
    private let appVersion: String
    private let lock = NSLock()
    private var pending: [TelemetryEvent] = []
    private var flushing = false
    private var sessionId = UUID()
    private var backgroundedAt: Date?
    private var sessionStarted = false

    init(client: APIClient, storeURL: URL, defaults: UserDefaults = .standard,
         installId: @escaping () -> String = { InstallIdentity.installIdString },
         appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") {
        self.client = client
        self.storeURL = storeURL
        self.defaults = defaults
        self.installId = installId
        self.appVersion = appVersion
        if let data = try? Data(contentsOf: storeURL),
           let saved = try? JSONDecoder().decode([TelemetryEvent].self, from: data) {
            // The server rejects events older than 30 days.
            let cutoff = Int64((Date().timeIntervalSince1970 - 29 * 86400) * 1000)
            pending = saved.filter { $0.ts > cutoff }
        }
    }

    /// Settings toggle. Turning it off clears everything queued.
    var isEnabled: Bool {
        get { !defaults.bool(forKey: Self.optOutKey) }
        set {
            defaults.set(!newValue, forKey: Self.optOutKey)
            if !newValue { clear() }
        }
    }

    var queued: [TelemetryEvent] {
        lock.lock(); defer { lock.unlock() }
        return pending
    }

    func track(_ event: Event, _ properties: [String: Any] = [:]) {
        guard isEnabled else { return }
        lock.lock()
        let e = TelemetryEvent(
            name: event.rawValue,
            ts: Int64((Date().timeIntervalSince1970 * 1000).rounded()),
            installId: installId(),
            sessionId: sessionId.uuidString.lowercased(),
            appVersion: appVersion,
            properties: Self.sanitize(properties))
        pending.append(e)
        if pending.count > Self.maxQueued { pending.removeFirst(pending.count - Self.maxQueued) }
        saveLocked()
        lock.unlock()
    }

    /// Foreground: a new session on first activation and after more than 30 min in the background.
    func appDidBecomeActive(now: Date = Date()) {
        lock.lock()
        let expired = backgroundedAt.map { now.timeIntervalSince($0) > Self.sessionTimeout } ?? false
        let start = !sessionStarted || expired
        if start {
            sessionId = UUID()
            sessionStarted = true
        }
        backgroundedAt = nil
        lock.unlock()
        if start { track(.sessionStart) }
    }

    func appDidEnterBackground(now: Date = Date()) {
        lock.lock()
        backgroundedAt = now
        lock.unlock()
    }

    /// Sends everything queued, in batches. Returns true when the queue is empty afterwards.
    @discardableResult
    func flush() async -> Bool {
        guard isEnabled else {
            clear()
            return true
        }
        let started: Bool = lock.withLock {
            if flushing { return false }
            flushing = true
            return true
        }
        guard started else { return false }
        defer { lock.withLock { flushing = false } }

        while true {
            let batch: [TelemetryEvent] = lock.withLock { Array(pending.prefix(Self.batchSize)) }
            if batch.isEmpty { return true }
            do {
                try await client.sendTelemetry(batch)
            } catch let e as APIClient.APIError where e.isPermanent {
                // 400/413: this batch will never be accepted; drop it rather than retry forever.
            } catch {
                return false // offline / 429 / 5xx: keep, retry on the next heartbeat
            }
            guard isEnabled else { clear(); return true }
            lock.withLock {
                pending.removeFirst(min(batch.count, pending.count))
                saveLocked()
            }
        }
    }

    func clear() {
        lock.lock()
        pending.removeAll()
        try? FileManager.default.removeItem(at: storeURL)
        lock.unlock()
    }

    /// Keeps only allow-listed keys with flat scalar values (strings capped at 64 chars).
    static func sanitize(_ properties: [String: Any]) -> [String: TelemetryValue]? {
        var out: [String: TelemetryValue] = [:]
        for (k, v) in properties where allowedPropertyKeys.contains(k) {
            switch v {
            case let b as Bool: out[k] = .bool(b)
            case let i as Int: out[k] = .int(i)
            case let d as Double where d.isFinite: out[k] = .double((d * 1000).rounded() / 1000)
            case let f as Float where f.isFinite: out[k] = .double((Double(f) * 1000).rounded() / 1000)
            case let s as String: out[k] = .string(String(s.prefix(64)))
            default: continue
            }
        }
        return out.isEmpty ? nil : out
    }

    private func saveLocked() {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
