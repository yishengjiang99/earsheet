// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import EarSheet
import HearSheet
import Foundation

/// Pure-logic tests for the paywall gate, free-tier export cut, telemetry queue, API request
/// shapes (docs/IOS_HANDOFF.md §8) and the model profile sidecar. No network, no StoreKit.
final class MonetizationTests: XCTestCase {
    // MARK: Paywall gate (PAYWALL_FLOW §2)

    func testProNeverSeesPaywall() {
        XCTAssertEqual(PaywallGate.decide(.exportLockedRow, state: .init(), isPro: true), .suppress("pro"))
    }

    func testUserInitiatedAlwaysShowsButNeverWhileRecording() {
        var s = PaywallGate.State()
        s.lifetimeDismissals = 9
        XCTAssertEqual(PaywallGate.decide(.saveLimit, state: s, isPro: false), .show)
        XCTAssertEqual(PaywallGate.decide(.saveLimit, state: s, isPro: false, isBusy: true), .suppress("recording"))
    }

    func testAutomaticCaps() {
        let now = Date()
        var s = PaywallGate.State()
        XCTAssertEqual(PaywallGate.decide(.exportSoft, state: s, isPro: false, now: now), .suppress("no_value_yet"))
        s.completedTranscriptions = 1
        XCTAssertEqual(PaywallGate.decide(.exportSoft, state: s, isPro: false, now: now), .show)
        s.sessionViews = 1
        XCTAssertEqual(PaywallGate.decide(.exportSoft, state: s, isPro: false, now: now), .suppress("cap_session"))
        s.sessionViews = 0
        s.lastDismiss = now.addingTimeInterval(-3600)
        XCTAssertEqual(PaywallGate.decide(.exportSoft, state: s, isPro: false, now: now), .suppress("cooldown"))
        s.lastDismiss = nil
        s.viewDates = [now.addingTimeInterval(-86400), now.addingTimeInterval(-2 * 86400)]
        XCTAssertEqual(PaywallGate.decide(.exportSoft, state: s, isPro: false, now: now), .suppress("cap_week"))
    }

    func testThirdTranscriptionCard() {
        var s = PaywallGate.State()
        s.completedTranscriptions = 2
        XCTAssertEqual(PaywallGate.decide(.thirdTranscription, state: s, isPro: false), .suppress("no_value_yet"))
        s.completedTranscriptions = 3
        XCTAssertEqual(PaywallGate.decide(.thirdTranscription, state: s, isPro: false), .show)
        s.thirdCardDismissals = 2
        XCTAssertEqual(PaywallGate.decide(.thirdTranscription, state: s, isPro: false), .suppress("card_done"))
    }

    // MARK: Free tier

    func testFreeExportsExcludeMidiAndMusicXML() {
        XCTAssertFalse(ExportFormat.available(isPro: false).contains(where: \.isProOnly))
        XCTAssertTrue(ExportFormat.available(isPro: true).contains(.midi))
        XCTAssertTrue(ExportFormat.available(isPro: true).contains(.musicXML))
    }

    func testTruncatedScoreKeepsFirstThirtySeconds() {
        // 0.125 s per 16th -> 30 s = 240 sixteenths.
        let notes = [QuantizedNote(midi: 60, velocity: 80, start16: 0, duration16: 8),
                     QuantizedNote(midi: 62, velocity: 80, start16: 236, duration16: 16),
                     QuantizedNote(midi: 64, velocity: 80, start16: 300, duration16: 4)]
        let score = QuantizedScore(notes: notes, tempoBPM: 120, meter: Meter(beatsPerBar: 4, beatUnit: 4),
                                   key: MusicalKey(tonic: 0, isMinor: false), secondsPer16th: 0.125)
        XCTAssertTrue(ExportPreview.isLongerThan(score, seconds: 30))
        let cut = ExportPreview.truncated(score, seconds: 30)
        XCTAssertEqual(cut.notes.map(\.midi), [60, 62])
        XCTAssertEqual(cut.notes[1].duration16, 4)
        XCTAssertFalse(ExportPreview.isLongerThan(cut, seconds: 30))
    }

    func testProductIDsMatchASC() {
        XCTAssertEqual(AppConfig.Product.monthly, "com.ragnus.pnge.pro.monthly")
        XCTAssertEqual(AppConfig.Product.yearly, "com.ragnus.pnge.pro.yearly")
        XCTAssertEqual(AppConfig.Product.lifetime, "com.ragnus.pnge.lifetime")
        XCTAssertEqual(ProStore.Plan(productID: "com.ragnus.pnge.lifetime"), .lifetime)
        XCTAssertNil(ProStore.Plan(productID: "com.ragnus.pnge.pro.lifetime"))
    }

    func testCachedEntitlementExpiry() {
        let now = Date()
        let sub = ProStore.CachedEntitlement(productID: AppConfig.Product.monthly, expiresAt: now.addingTimeInterval(60),
                                             isTrial: false, willAutoRenew: true, updatedAt: now)
        XCTAssertTrue(sub.isActive(now: now))
        XCTAssertFalse(sub.isActive(now: now.addingTimeInterval(120)))
        let life = ProStore.CachedEntitlement(productID: AppConfig.Product.lifetime, expiresAt: nil,
                                              isTrial: false, willAutoRenew: nil, updatedAt: now)
        XCTAssertTrue(life.isActive(now: now.addingTimeInterval(1e9)))
    }

    // MARK: Identity

    func testIdentitiesAreStableLowercaseableUUIDs() {
        XCTAssertEqual(InstallIdentity.installId, InstallIdentity.installId)
        XCTAssertEqual(InstallIdentity.appAccountToken, InstallIdentity.appAccountToken)
        XCTAssertNotEqual(InstallIdentity.installId, InstallIdentity.appAccountToken)
    }

    // MARK: API client request shapes

    func testRequestURLsAndBodies() throws {
        let api = APIClient(base: URL(string: "https://example.test/music-radar")!)
        XCTAssertEqual(api.url(APIClient.Path.iapVerify).absoluteString, "https://example.test/music-radar/api/iap/verify")
        XCTAssertEqual(api.url(APIClient.Path.telemetryBatch).absoluteString, "https://example.test/music-radar/api/telemetry/batch")
        XCTAssertEqual(api.url(APIClient.Path.deviceRegister).absoluteString, "https://example.test/music-radar/api/devices/register")
        XCTAssertEqual(AppConfig.defaultServerBase.absoluteString, "https://grepawk.com/music-radar")

        struct Body: Encodable { var signedTransaction: String; var appAccountToken: String }
        let req = try api.request(APIClient.Path.iapVerify, body: Body(signedTransaction: "x.y.z", appAccountToken: "abc"))
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: String])
        XCTAssertEqual(json["signedTransaction"], "x.y.z")
    }

    func testEntitlementDecodesServerShape() throws {
        let data = Data(#"{"pro":true,"plan":"com.ragnus.pnge.pro.yearly","status":"trial","expiresAt":"2026-10-10T18:00:00.000Z","items":[]}"#.utf8)
        let e = try JSONDecoder().decode(APIClient.Entitlement.self, from: data)
        XCTAssertTrue(e.pro)
        XCTAssertEqual(e.status, "trial")
        let free = try JSONDecoder().decode(APIClient.Entitlement.self,
                                            from: Data(#"{"pro":false,"plan":"free","status":"none","expiresAt":null,"items":[]}"#.utf8))
        XCTAssertFalse(free.pro)
        XCTAssertNil(free.expiresAt)
    }

    // MARK: Telemetry

    func testTelemetrySanitizeKeepsFlatScalarsOnly() {
        let out = Telemetry.sanitize(["a": 1, "b": true, "c": "x", "d": [1, 2], "e": Double.nan, "f": 2.5])
        XCTAssertEqual(out?["a"], .number(1))
        XCTAssertEqual(out?["b"], .bool(true))
        XCTAssertEqual(out?["c"], .string("x"))
        XCTAssertEqual(out?["f"], .number(2.5))
        XCTAssertNil(out?["d"])
        XCTAssertNil(out?["e"])
    }

    func testTelemetryQueuePersistsAndRespectsOptOut() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tq-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let offline = APIClient(base: URL(string: "http://127.0.0.1:9")!)
        var on = true
        let t = Telemetry(client: offline, storeURL: url, enabled: { on })
        t.track(.appOpen, ["cold": true])
        t.track(.paywallView, ["trigger": "settings"])
        XCTAssertEqual(t.pendingCount, 2)
        let events = t.pendingEvents
        XCTAssertEqual(events.map(\.name), ["app_open", "paywall_view"])
        XCTAssertNotNil(UUID(uuidString: events[0].installId))
        XCTAssertNotNil(events[0].sessionId.flatMap(UUID.init(uuidString:)))
        // Survives a relaunch.
        let reloaded = Telemetry(client: offline, storeURL: url, enabled: { on })
        XCTAssertEqual(reloaded.pendingCount, 2)
        on = false
        reloaded.track(.appOpen)
        XCTAssertEqual(reloaded.pendingCount, 2)
    }

    func testEventNamesMatchServerRule() {
        let re = try! NSRegularExpression(pattern: "^[a-z][a-z0-9_]{1,63}$")
        for e in Telemetry.Event.allCases {
            let n = e.rawValue
            XCTAssertNotNil(re.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)), n)
        }
    }

    // MARK: Limits and model profile

    func testLimitsAreExplicit() {
        XCTAssertEqual(AppConfig.Limits.liveRecordingSeconds, AudioRecorder.maxRecordingSeconds)
        XCTAssertEqual(AudioRecorder.maxSamples, Int(AudioRecorder.maxRecordingSeconds * AudioRecorder.targetSampleRate))
        XCTAssertLessThanOrEqual(AppConfig.Limits.importSeconds, Transcriber.maxDurationSeconds)
    }

    func testModelProfileSidecar() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(TranscriptionModel.profile(in: dir), .stock)
        XCTAssertEqual(TranscriptionModel.profile(in: dir).thresholds, BasicPitchDecoder.Thresholds())
        try Data(#"{"name":"ft-exp5","onsetThreshold":0.7}"#.utf8)
            .write(to: dir.appendingPathComponent(TranscriptionModel.profileFileName))
        let p = TranscriptionModel.profile(in: dir)
        XCTAssertEqual(p.name, "ft-exp5")
        XCTAssertEqual(p.thresholds, BasicPitchDecoder.Thresholds(onset: 0.7, frame: 0.3))
    }

    func testDetachedWorkSeesCancellation() async {
        let task = Task {
            try await runDetached { () -> Int in
                for _ in 0..<500 {
                    try Task.checkCancellation()
                    Thread.sleep(forTimeInterval: 0.01)
                }
                return 1
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
