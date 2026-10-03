// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// The one HTTP client for the AI Music Radar backend (`server/` in this repo,
/// live at https://grepawk.com/music-radar). No other code in the app calls
/// URLSession for the API.
///
/// Routes (server/src/{devices,iap,telemetry}.ts):
///   POST /api/devices/register   device row; re-posting it is the heartbeat (`last_seen_at`)
///   POST /api/push/register      APNs token          POST /api/push/unregister
///   POST /api/iap/verify         one StoreKit 2 JWS  GET  /api/iap/entitlement?appAccountToken=
///   POST /api/telemetry/batch    anonymous events (no audio, no PII)
///
/// Auth: the server takes no Authorization header or API key. Requests are keyed by the
/// anonymous Keychain `installId` (devices, push, telemetry) and the StoreKit
/// `appAccountToken` (IAP); purchases are trusted only after the server verifies Apple's JWS.
/// The client therefore never sends an Authorization header (asserted in tests).
final class APIClient: @unchecked Sendable {
    static let defaultBaseURL = URL(string: "https://grepawk.com/music-radar")!
    static let shared = APIClient()

    enum Path {
        static let deviceRegister = "api/devices/register"
        static let pushRegister = "api/push/register"
        static let pushUnregister = "api/push/unregister"
        static let iapVerify = "api/iap/verify"
        static let iapEntitlement = "api/iap/entitlement"
        static let telemetryBatch = "api/telemetry/batch"
    }

    enum APIError: Error, Equatable {
        /// Non-2xx reply. `retryAfter` from the `Retry-After` header (429).
        case http(status: Int, retryAfter: TimeInterval?)
        case badResponse

        /// 4xx other than 408/429: the server rejected the request itself; resending it unchanged won't help.
        var isPermanent: Bool {
            if case .http(let s, _) = self { return (400..<500).contains(s) && s != 408 && s != 429 }
            return false
        }
    }

    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = APIClient.defaultBaseURL, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 20
            cfg.waitsForConnectivity = false
            self.session = URLSession(configuration: cfg)
        }
    }

    // MARK: - Payloads (mirror the server JSON)

    struct DeviceInfo: Codable, Equatable {
        var installId: String
        var appAccountToken: String?
        var platform = "ios"
        var osVersion: String
        var appVersion: String
        var buildNumber: String
        var deviceModel: String
        var locale: String
        var timezone: String
    }

    struct Entitlement: Codable, Equatable {
        var pro: Bool
        var plan: String
        var status: String
        var expiresAt: String?
    }

    struct VerifyResponse: Decodable {
        var ok: Bool
        var entitlement: Entitlement?
    }

    // MARK: - Endpoints

    func registerDevice(_ info: DeviceInfo) async throws {
        try await send(try post(Path.deviceRegister, body: info))
    }

    func registerPush(installId: String, token: String, environment: String) async throws {
        struct Body: Encodable { var installId, token, environment: String }
        try await send(try post(Path.pushRegister, body: Body(installId: installId, token: token, environment: environment)))
    }

    func unregisterPush(installId: String, token: String) async throws {
        struct Body: Encodable { var installId, token: String }
        try await send(try post(Path.pushUnregister, body: Body(installId: installId, token: token)))
    }

    @discardableResult
    func verify(signedTransaction: String, appAccountToken: String) async throws -> VerifyResponse {
        try await decode(VerifyResponse.self, from: try verifyRequest(signedTransaction: signedTransaction,
                                                                       appAccountToken: appAccountToken))
    }

    func entitlement(appAccountToken: String) async throws -> Entitlement {
        try await decode(Entitlement.self, from: entitlementRequest(appAccountToken: appAccountToken))
    }

    func sendTelemetry(_ events: [TelemetryEvent]) async throws {
        try await send(try telemetryRequest(events))
    }

    // MARK: - Request building (internal for tests)

    func url(_ path: String) -> URL { baseURL.appendingPathComponent(path) }

    func verifyRequest(signedTransaction: String, appAccountToken: String) throws -> URLRequest {
        struct Body: Encodable { var signedTransaction, appAccountToken: String }
        return try post(Path.iapVerify, body: Body(signedTransaction: signedTransaction, appAccountToken: appAccountToken))
    }

    func entitlementRequest(appAccountToken: String) -> URLRequest {
        var comps = URLComponents(url: url(Path.iapEntitlement), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "appAccountToken", value: appAccountToken)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    func telemetryRequest(_ events: [TelemetryEvent]) throws -> URLRequest {
        struct Body: Encodable { var events: [TelemetryEvent] }
        return try post(Path.telemetryBatch, body: Body(events: events))
    }

    func post<B: Encodable>(_ path: String, body: B) throws -> URLRequest {
        var req = URLRequest(url: url(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        req.httpBody = try enc.encode(body)
        return req
    }

    // MARK: - Transport

    @discardableResult
    private func send(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw APIError.http(status: http.statusCode, retryAfter: retry)
        }
        return data
    }

    private func decode<R: Decodable>(_ type: R.Type, from req: URLRequest) async throws -> R {
        let data = try await send(req)
        do { return try JSONDecoder().decode(R.self, from: data) } catch { throw APIError.badResponse }
    }
}
