// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
import UserNotifications
@testable import EarSheet

// MARK: - Stub transport

/// URLProtocol stub: records every request and answers from `handler`.
final class StubURLProtocol: URLProtocol {
    struct Recorded { var request: URLRequest; var body: Data? }
    static var handler: ((URLRequest) throws -> (Int, Data)) = { _ in (200, Data(#"{"ok":true}"#.utf8)) }
    static var recorded: [Recorded] = []
    private static let lock = NSLock()

    static func reset(_ h: @escaping (URLRequest) throws -> (Int, Data)) {
        lock.lock(); defer { lock.unlock() }
        handler = h
        recorded = []
    }

    static func requests(to path: String) -> [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return recorded.filter { $0.request.url?.path.hasSuffix(path) == true }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            stream.close()
            body = data
        }
        Self.lock.lock()
        Self.recorded.append(Recorded(request: request, body: body))
        let h = Self.handler
        Self.lock.unlock()
        do {
            let (status, data) = try h(request)
            let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

private func stubClient() -> APIClient {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [StubURLProtocol.self]
    return APIClient(session: URLSession(configuration: cfg))
}

private func tempFile(_ name: String) -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(name)
}

private let offline: (URLRequest) throws -> (Int, Data) = { _ in throw URLError(.notConnectedToInternet) }
private let entitlementJSON = Data(#"{"pro":true,"plan":"com.ragnus.pnge.pro.yearly","status":"trial","expiresAt":null,"items":[]}"#.utf8)

// MARK: - APIClient request building

final class APIClientTests: XCTestCase {
    func testBaseURLIsGrepawkMusicRadar() {
        XCTAssertEqual(APIClient.defaultBaseURL.absoluteString, "https://grepawk.com/music-radar")
        XCTAssertEqual(APIClient.shared.baseURL, APIClient.defaultBaseURL)
        XCTAssertEqual(APIClient().url(APIClient.Path.deviceRegister).absoluteString,
                       "https://grepawk.com/music-radar/api/devices/register")
    }

    func testVerifyRequestShapeAndNoAuthorizationHeader() throws {
        let req = try APIClient().verifyRequest(signedTransaction: "eyJ.jws.sig",
                                                appAccountToken: "3f6c0f7e-1111-4222-8333-444455556666")
        XCTAssertEqual(req.url?.absoluteString, "https://grepawk.com/music-radar/api/iap/verify")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        // server/src/iap.ts takes no Authorization header / API key; never send one.
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(req.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["signedTransaction": "eyJ.jws.sig",
                              "appAccountToken": "3f6c0f7e-1111-4222-8333-444455556666"])
    }

    func testEntitlementAndTelemetryRequests() throws {
        let api = APIClient()
        let ent = api.entitlementRequest(appAccountToken: "00000000-0000-4000-8000-000000000000")
        XCTAssertEqual(ent.httpMethod, "GET")
        XCTAssertEqual(ent.url?.absoluteString,
                       "https://grepawk.com/music-radar/api/iap/entitlement?appAccountToken=00000000-0000-4000-8000-000000000000")
        XCTAssertNil(ent.value(forHTTPHeaderField: "Authorization"))

        let tel = try api.telemetryRequest([TelemetryEvent(name: "app_open", ts: 1, installId: "x", sessionId: nil,
                                                           appVersion: "1.0", properties: nil)])
        XCTAssertEqual(tel.url?.absoluteString, "https://grepawk.com/music-radar/api/telemetry/batch")
        XCTAssertNil(tel.value(forHTTPHeaderField: "Authorization"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(tel.httpBody)) as? [String: Any])
        XCTAssertEqual((obj["events"] as? [Any])?.count, 1)
    }

    func testDeviceAndPushRoutesThroughStub() async throws {
        StubURLProtocol.reset { _ in (200, Data(#"{"ok":true,"deviceId":1}"#.utf8)) }
        let api = stubClient()
        try await api.registerDevice(.init(installId: "8f0c0000-0000-4000-8000-000000000001", appAccountToken: nil,
                                           osVersion: "18.0", appVersion: "1.0", buildNumber: "1",
                                           deviceModel: "iPhone17,1", locale: "en_US", timezone: "UTC"))
        try await api.registerPush(installId: "8f0c0000-0000-4000-8000-000000000001", token: "ab", environment: "sandbox")
        try await api.unregisterPush(installId: "8f0c0000-0000-4000-8000-000000000001", token: "ab")
        XCTAssertEqual(StubURLProtocol.requests(to: "/music-radar/api/devices/register").count, 1)
        XCTAssertEqual(StubURLProtocol.requests(to: "/music-radar/api/push/register").count, 1)
        XCTAssertEqual(StubURLProtocol.requests(to: "/music-radar/api/push/unregister").count, 1)
        for r in StubURLProtocol.recorded {
            XCTAssertEqual(r.request.url?.host, "grepawk.com")
            XCTAssertNil(r.request.value(forHTTPHeaderField: "Authorization"))
        }
    }
}

// MARK: - Verify retry queue

final class VerifyQueueTests: XCTestCase {
    func testFailedVerifyIsKeptAndRetriedUntilAccepted() async throws {
        let store = tempFile("verify.json")
        let token = "3f6c0f7e-1111-4222-8333-444455556666"

        // 1. Server down: the transaction stays queued (and on disk).
        StubURLProtocol.reset { _ in (503, Data(#"{"error":"down"}"#.utf8)) }
        let q1 = VerifyQueue(client: stubClient(), storeURL: store)
        await q1.enqueue(transactionId: "2000000123", signedTransaction: "JWS-1", appAccountToken: token)
        let sent1 = await q1.drain()
        XCTAssertEqual(sent1, 0)
        let after1 = await q1.items
        XCTAssertEqual(after1.map(\.transactionId), ["2000000123"])
        XCTAssertEqual(after1.first?.attempts, 1)

        // 2. Offline after a relaunch: still not lost.
        StubURLProtocol.reset(offline)
        let q2 = VerifyQueue(client: stubClient(), storeURL: store)
        _ = await q2.drain()
        let after2 = await q2.items
        XCTAssertEqual(after2.map(\.transactionId), ["2000000123"], "queue must survive a relaunch")

        // 3. Server back: verified, removed, then the entitlement is fetched.
        StubURLProtocol.reset { req in
            if req.url?.path.hasSuffix("/api/iap/entitlement") == true { return (200, entitlementJSON) }
            return (200, Data(#"{"ok":true,"transaction":{},"entitlement":null}"#.utf8))
        }
        let sent3 = await q2.drain()
        XCTAssertEqual(sent3, 1)
        let after3 = await q2.items
        XCTAssertTrue(after3.isEmpty)
        let verifyBody = try XCTUnwrap(StubURLProtocol.requests(to: "/api/iap/verify").last?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: verifyBody) as? [String: String])
        XCTAssertEqual(json["signedTransaction"], "JWS-1")
        XCTAssertEqual(json["appAccountToken"], token)
        XCTAssertEqual(StubURLProtocol.requests(to: "/api/iap/entitlement").count, 1, "GET entitlement after verify")
        let ent = await q2.lastEntitlement
        XCTAssertEqual(ent?.pro, true)

        // A fresh load from disk is empty too.
        let q3 = VerifyQueue(client: stubClient(), storeURL: store)
        let reloaded = await q3.items
        XCTAssertTrue(reloaded.isEmpty)
    }

    func testRejectedSignatureIsDroppedOnlyAfterRepeatedRejections() async {
        StubURLProtocol.reset { _ in (400, Data(#"{"ok":false,"error":"signature verification failed"}"#.utf8)) }
        let q = VerifyQueue(client: stubClient(), storeURL: tempFile("verify.json"))
        await q.enqueue(transactionId: "1", signedTransaction: "bad", appAccountToken: "t")
        for _ in 1..<VerifyQueue.maxRejections {
            _ = await q.drain()
            let n = await q.items.count
            XCTAssertEqual(n, 1)
        }
        _ = await q.drain()
        let n = await q.items.count
        XCTAssertEqual(n, 0)
    }

    func testEnqueueDedupesByTransactionID() async {
        let q = VerifyQueue(client: stubClient(), storeURL: tempFile("verify.json"))
        await q.enqueue(transactionId: "7", signedTransaction: "a", appAccountToken: "t")
        await q.enqueue(transactionId: "7", signedTransaction: "b", appAccountToken: "t")
        let items = await q.items
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.signedTransaction, "b")
    }
}

// MARK: - Telemetry batching + privacy

final class TelemetryTests: XCTestCase {
    private let installId = "8f0c1d2e-0000-4000-8000-0000000000aa"

    private func makeTelemetry(_ defaults: UserDefaults, store: URL = tempFile("telemetry.json")) -> Telemetry {
        Telemetry(client: stubClient(), storeURL: store, defaults: defaults,
                  installId: { [installId] in installId }, appVersion: "1.0")
    }

    private func freshDefaults() -> UserDefaults {
        let name = "telemetry-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testEventNamesMatchTicketList() {
        XCTAssertEqual(Set(Telemetry.Event.allCases.map(\.rawValue)), [
            "app_open", "session_start", "transcription_start", "transcription_stop", "paywall_view",
            "purchase_start", "purchase_success", "purchase_fail", "restore",
        ])
    }

    @MainActor
    func testEventsQueueOfflineAndFlushOnHeartbeat() async throws {
        let defaults = freshDefaults()
        let store = tempFile("telemetry.json")
        let t = makeTelemetry(defaults, store: store)
        StubURLProtocol.reset(offline)
        t.track(.appOpen, ["cold": true])
        t.track(.transcriptionStart, ["source": "mic"])
        let flushedOffline = await t.flush()
        XCTAssertFalse(flushedOffline)
        XCTAssertEqual(t.queued.map(\.name), ["app_open", "transcription_start"])
        // Survives a relaunch.
        XCTAssertEqual(makeTelemetry(defaults, store: store).queued.count, 2)

        // Back online: one heartbeat registers the device and flushes the queue.
        StubURLProtocol.reset { _ in (200, Data(#"{"ok":true,"accepted":2,"dropped":0}"#.utf8)) }
        let sync = ServerSync(client: stubClient(), telemetry: t,
                              verifyQueue: VerifyQueue(client: stubClient(), storeURL: tempFile("verify.json")),
                              deviceInfo: { [installId] in
                                  APIClient.DeviceInfo(installId: installId, appAccountToken: nil, osVersion: "18.0",
                                                       appVersion: "1.0", buildNumber: "1", deviceModel: "iPhone17,1",
                                                       locale: "en_US", timezone: "UTC")
                              })
        await sync.heartbeat()
        XCTAssertEqual(StubURLProtocol.requests(to: "/api/devices/register").count, 1)
        let batches = StubURLProtocol.requests(to: "/api/telemetry/batch")
        XCTAssertEqual(batches.count, 1)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(batches[0].body)) as? [String: Any])
        XCTAssertEqual((obj["events"] as? [[String: Any]])?.compactMap { $0["name"] as? String },
                       ["app_open", "transcription_start"])
        XCTAssertTrue(t.queued.isEmpty)
    }

    func testOptOutSuppressesAllSends() async {
        let defaults = freshDefaults()
        let t = makeTelemetry(defaults)
        StubURLProtocol.reset { _ in (200, Data(#"{"ok":true}"#.utf8)) }
        t.track(.paywallView)
        t.isEnabled = false
        XCTAssertTrue(t.queued.isEmpty, "opting out clears the queue")
        t.track(.purchaseStart, ["product": "com.ragnus.pnge.pro.yearly"])
        t.appDidBecomeActive()
        XCTAssertTrue(t.queued.isEmpty, "nothing is queued while opted out")
        _ = await t.flush()
        XCTAssertTrue(StubURLProtocol.requests(to: "/api/telemetry/batch").isEmpty, "nothing is sent while opted out")

        t.isEnabled = true
        t.track(.paywallView)
        XCTAssertEqual(t.queued.count, 1)
    }

    func testSampleBatchCarriesNoAudioNoContentAndOnlyTheInstallUUID() throws {
        let t = makeTelemetry(freshDefaults())
        let sampleAudio: [Float] = Array(repeating: 0.25, count: 22_050)
        t.appDidBecomeActive()
        t.track(.appOpen, ["cold": true])
        t.track(.transcriptionStart, ["source": "mic", "audio": sampleAudio, "samples": Data(count: 4096)])
        t.track(.transcriptionStop, ["source": "mic", "duration_s": 12.5, "notes": 42,
                                     "title": "Take 3 - my secret song", "text": "typed by user",
                                     "fileName": "Grandma's recital.m4a", "deviceName": "Yisheng's iPhone",
                                     "idfv": UUID().uuidString, "keystrokes": "abc"])
        t.track(.purchaseFail, ["product": "com.ragnus.pnge.lifetime", "reason": "error", "code": 2,
                                "message": "Payment declined for card ending"])
        let batch = try APIClient().telemetryRequest(t.queued)
        let body = try XCTUnwrap(batch.httpBody)
        let text = String(decoding: body, as: UTF8.self)

        // Size: a few hundred bytes per event, nowhere near an audio buffer.
        XCTAssertLessThan(body.count, 3000)
        for banned in ["audio", "samples", "title", "secret song", "typed by user", "fileName", "recital",
                       "deviceName", "iPhone", "idfv", "keystrokes", "message", "Payment declined"] {
            XCTAssertFalse(text.contains(banned), "payload leaked \(banned): \(text)")
        }

        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let events = try XCTUnwrap(obj["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 5)
        let allowedTop: Set<String> = ["name", "ts", "installId", "sessionId", "appVersion", "properties"]
        let uuidRE = try NSRegularExpression(pattern: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
                                             options: [.caseInsensitive])
        let sessionIds = Set(events.compactMap { $0["sessionId"] as? String })
        XCTAssertEqual(sessionIds.count, 1)
        for e in events {
            XCTAssertTrue(Set(e.keys).isSubset(of: allowedTop), "unexpected keys \(e.keys)")
            XCTAssertEqual(e["installId"] as? String, installId)
            if let props = e["properties"] as? [String: Any] {
                XCTAssertTrue(Set(props.keys).isSubset(of: Telemetry.allowedPropertyKeys), "\(props.keys)")
                for v in props.values {
                    XCTAssertTrue(v is String || v is NSNumber, "non-scalar property \(v)")
                }
            }
        }
        // The only UUIDs in the payload: the install UUID and the random session UUID.
        let found = Set(uuidRE.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            (text as NSString).substring(with: $0.range).lowercased()
        })
        XCTAssertEqual(found, Set([installId]).union(sessionIds))
    }
}

// MARK: - Push permission policy

@MainActor
final class PushPermissionTests: XCTestCase {
    final class FakeCenter: NotificationAuthorizing {
        var status: UNAuthorizationStatus = .notDetermined
        var requests = 0
        var grant = true
        func authorizationStatus() async -> UNAuthorizationStatus { status }
        func requestAuthorization() async throws -> Bool {
            requests += 1
            status = grant ? .authorized : .denied
            return grant
        }
    }

    private func freshDefaults() -> UserDefaults {
        let name = "push-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testLaunchAndForegroundNeverPrompt() async {
        let center = FakeCenter()
        var registered = 0
        let push = PushManager(center: center, client: stubClient(), defaults: freshDefaults(),
                               registerRemote: { registered += 1 }, unregisterRemote: {})
        await push.refresh()
        await push.refresh()
        XCTAssertEqual(center.requests, 0, "no permission prompt on launch / foreground")
        XCTAssertEqual(registered, 0)
        XCTAssertFalse(push.enabledInApp, "notifications are off until the user turns them on")
    }

    func testSettingsToggleAsksOnceThenRegistersTokenWithServer() async throws {
        StubURLProtocol.reset { _ in (200, Data(#"{"ok":true}"#.utf8)) }
        let center = FakeCenter()
        var registered = 0
        let defaults = freshDefaults()
        let push = PushManager(center: center, client: stubClient(), defaults: defaults,
                               registerRemote: { registered += 1 }, unregisterRemote: {})
        let on = await push.enable()
        XCTAssertTrue(on)
        XCTAssertEqual(center.requests, 1)
        XCTAssertEqual(registered, 1)

        await push.didRegister(deviceToken: Data([0xde, 0xad, 0xbe, 0xef]))
        let body = try XCTUnwrap(StubURLProtocol.requests(to: "/api/push/register").last?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["token"], "deadbeef")
        XCTAssertEqual(json["environment"], "sandbox", "Debug test builds use the APNs sandbox")
        XCTAssertEqual(json["installId"], InstallIdentity.installIdString)

        // Already authorized: re-enabling never prompts again.
        _ = await push.enable()
        XCTAssertEqual(center.requests, 1)

        await push.disable()
        XCTAssertFalse(push.enabledInApp)
        XCTAssertEqual(StubURLProtocol.requests(to: "/api/push/unregister").count, 1)
    }
}
