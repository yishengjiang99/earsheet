// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Security

/// Anonymous identifiers (docs/iap/IOS_INTEGRATION.md §2, §7). No account, no PII, no IDFV.
/// - `installId`: random UUID that keys the device row, push tokens and telemetry on the server.
/// - `appAccountToken`: random UUID passed to `Product.purchase(options: [.appAccountToken])` so
///   Apple stamps it into every transaction; the server keys entitlements by it. On restore, a
///   token already present on an owned transaction (bought on another device) is adopted so the
///   server's token check passes.
/// Both live in the Keychain (`AfterFirstUnlock`), so they survive reinstalls on the same device.
/// A UserDefaults copy is the fallback where the Keychain is unavailable (unsigned simulator hosts).
enum InstallIdentity {
    private static let service = "com.ragnus.pnge.identity"
    private static let lock = NSLock()
    private static var cache: [String: UUID] = [:]

    static var installId: UUID { value(for: "installId") }
    static var appAccountToken: UUID { value(for: "appAccountToken") }

    /// Adopt the token found on an owned transaction (restore on a new device / after reinstall).
    static func adopt(appAccountToken token: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard cache["appAccountToken"] != token else { return }
        write(token.uuidString.lowercased(), account: "appAccountToken")
        cache["appAccountToken"] = token
    }

    private static func value(for account: String) -> UUID {
        lock.lock(); defer { lock.unlock() }
        if let u = cache[account] { return u }
        if let s = read(account: account), let u = UUID(uuidString: s) {
            cache[account] = u
            return u
        }
        let u = UUID()
        write(u.uuidString.lowercased(), account: account)
        cache[account] = u
        return u
    }

    // MARK: - Keychain

    private static func fallbackKey(_ account: String) -> String { "MusicRadarIdentity.\(account)" }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func read(account: String) -> String? {
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
           let data = out as? Data, let s = String(data: data, encoding: .utf8) {
            return s
        }
        return UserDefaults.standard.string(forKey: fallbackKey(account))
    }

    private static func write(_ value: String, account: String) {
        let q = baseQuery(account)
        let attrs: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        var status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add.merge(attrs) { $1 }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        // Always keep the fallback in sync, so an unavailable Keychain never forks identities.
        UserDefaults.standard.set(value, forKey: fallbackKey(account))
    }
}
