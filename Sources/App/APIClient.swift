// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import UIKit

/// The one client for the AI Music Radar API (server/ in this repo, live at `AppConfig.serverBase`,
/// contract in docs/IOS_HANDOFF.md §8). Every call is best-effort: the app works fully offline, and
/// StoreKit stays the source of truth for entitlements on the device. Endpoints:
///   GET  /api/health                  GET  /api/iap/products
///   POST /api/devices/register        device row + heartbeat (launch, foreground)
///   POST /api/push/register           APNs token          POST /api/push/unregister
///   POST /api/iap/verify              one StoreKit 2 JWS  POST /api/iap/restore  (≤50 current JWS)
///   GET  /api/iap/entitlement?appAccountToken=
///   POST /api/telemetry/batch         analytics events (no audio, no PII)
final class APIClient: @unchecked Sendable {
    static let shared = APIClient()

    enum APIError: Error, CustomStringConvertible {
        case http(Int, String, retryAfter: TimeInterval?)
        case decoding(String)
        var statusCode: Int? { if case .http(let c, _, _) = self { return c } else { return nil } }
        var description: String {
            switch self {
            case .http(let code, let body, _): return "HTTP \(code): \(body.prefix(200))"
            case .decoding(let s): return "decoding: \(s)"
            }
        }
    }

    enum Path {
        static let health = "api/health"
        static let deviceRegister = "api/devices/register"
        static let pushRegister = "api/push/register"
        static let pushUnregister = "api/push/unregister"
        static let iapProducts = "api/iap/products"
        static let iapVerify = "api/iap/verify"
        static let iapRestore = "api/iap/restore"
        static let iapEntitlement = "api/iap/entitlement"
        static let telemetryBatch = "api/telemetry/batch"
    }

    let session: URLSession
    private let baseOverride: URL?
    var base: URL { baseOverride ?? AppConfig.serverBase }

    init(base: URL? = nil, session: URLSession? = nil) {
        self.baseOverride = base
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 20
            cfg.waitsForConnectivity = false
            cfg.httpAdditionalHeaders = ["User-Agent": "AIMusicRadar/\(AppConfig.appVersion) (\(AppConfig.buildNumber); iOS)"]
            self.session = URLSession(configuration: cfg)
        }
    }

    // MARK: - Models (mirror server JSON)

    struct DeviceInfo: Encodable, Equatable {
        var installId: String
        var appAccountToken: String?
        var platform = "ios"
        var osVersion: String
        var appVersion: String
        var buildNumber: String
        var deviceModel: String
        var locale: String
        var timezone: String

        @MainActor static func current() -> DeviceInfo {
            DeviceInfo(installId: InstallIdentity.installId.uuidString.lowercased(),
                       appAccountToken: InstallIdentity.appAccountToken.uuidString.lowercased(),
                       osVersion: UIDevice.current.systemVersion,
                       appVersion: AppConfig.appVersion,
                       buildNumber: AppConfig.buildNumber,
                       deviceModel: Self.hardwareModel(),
                       locale: Locale.current.identifier,
                       timezone: TimeZone.current.identifier)
        }

        /// e.g. "iPhone17,1" (model identifier, not the user-assigned device name).
        static func hardwareModel() -> String {
            if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
            var info = utsname()
            uname(&info)
            return withUnsafeBytes(of: &info.machine) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
    }

    struct DeviceRegisterResponse: Decodable { var ok: Bool; var deviceId: Int? }

    struct Entitlement: Codable, Equatable {
        var pro: Bool
        var plan: String
        var status: String
        var expiresAt: String?
    }

    struct VerifyResponse: Decodable { var ok: Bool; var entitlement: Entitlement?; var error: String? }
    struct RestoreResponse: Decodable { var ok: Bool; var entitlement: Entitlement? }

    struct TelemetryEvent: Codable, Equatable {
        var name: String
        var ts: Double           // epoch ms
        var installId: String
        var sessionId: String?
        var appVersion: String?
        var properties: [String: TelemetryValue]?
    }

    enum TelemetryValue: Codable, Equatable {
        case string(String), number(Double), bool(Bool)
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let s): try c.encode(s)
            case .number(let n): try c.encode(n)
            case .bool(let b): try c.encode(b)
            }
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else if let n = try? c.decode(Double.self) { self = .number(n) }
            else { self = .string(try c.decode(String.self)) }
        }
    }

    struct TelemetryResponse: Decodable { var ok: Bool; var accepted: Int?; var dropped: Int? }

    // MARK: - Endpoints

    @discardableResult
    func registerDevice(_ info: DeviceInfo) async throws -> DeviceRegisterResponse {
        try await post(Path.deviceRegister, body: info)
    }

    func registerPush(token: String, environment: String) async throws {
        struct Body: Encodable { var installId, token, environment: String; var appAccountToken: String? }
        let _: OK = try await post(Path.pushRegister, body: Body(
            installId: InstallIdentity.installId.uuidString.lowercased(), token: token,
            environment: environment, appAccountToken: InstallIdentity.appAccountToken.uuidString.lowercased()))
    }

    func unregisterPush(token: String) async throws {
        struct Body: Encodable { var installId, token: String }
        let _: OK = try await post(Path.pushUnregister, body: Body(
            installId: InstallIdentity.installId.uuidString.lowercased(), token: token))
    }

    func verify(signedTransaction jws: String, appAccountToken: UUID) async throws -> VerifyResponse {
        struct Body: Encodable { var signedTransaction, appAccountToken: String }
        return try await post(Path.iapVerify, body: Body(signedTransaction: jws,
                                                         appAccountToken: appAccountToken.uuidString.lowercased()))
    }

    func restore(signedTransactions: [String], appAccountToken: UUID) async throws -> RestoreResponse {
        struct Body: Encodable { var signedTransactions: [String]; var appAccountToken: String }
        return try await post(Path.iapRestore, body: Body(signedTransactions: Array(signedTransactions.prefix(50)),
                                                          appAccountToken: appAccountToken.uuidString.lowercased()))
    }

    func entitlement(appAccountToken: UUID) async throws -> Entitlement {
        var comps = URLComponents(url: url(Path.iapEntitlement), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "appAccountToken", value: appAccountToken.uuidString.lowercased())]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        return try await send(req)
    }

    struct Health: Decodable { var ok: Bool; var service: String?; var version: String?; var bundleId: String? }

    func health() async throws -> Health {
        var req = URLRequest(url: url(Path.health))
        req.httpMethod = "GET"
        return try await send(req)
    }

    func sendTelemetry(_ events: [TelemetryEvent]) async throws -> TelemetryResponse {
        struct Body: Encodable { var events: [TelemetryEvent] }
        return try await post(Path.telemetryBatch, body: Body(events: events))
    }

    // MARK: - Transport

    private struct OK: Decodable { var ok: Bool? }

    func url(_ path: String) -> URL { base.appendingPathComponent(path) }

    func request<B: Encodable>(_ path: String, body: B) throws -> URLRequest {
        var req = URLRequest(url: url(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONEncoder().encode(body)
        return req
    }

    private func post<B: Encodable, R: Decodable>(_ path: String, body: B) async throws -> R {
        try await send(try request(path, body: body))
    }

    private func send<R: Decodable>(_ req: URLRequest) async throws -> R {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let retry = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw APIError.http(code, String(decoding: data, as: UTF8.self), retryAfter: retry)
        }
        do {
            return try JSONDecoder().decode(R.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }
}
