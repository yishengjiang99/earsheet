// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Security

/// Anonymous identifiers (docs/iap/IOS_INTEGRATION.md §7). No account, no PII, no IDFV.
/// - `installId`: random UUID in the Keychain; keys the device row, push tokens and telemetry.
///   It is the only identifier that leaves the phone with telemetry.
/// - `appAccountToken`: random UUID that StoreKit stamps into every purchase (ProStore); the
///   server keys entitlements by it. Kept under ProStore's original UserDefaults key.
enum InstallIdentity {
    private static let service = "com.ragnus.pnge.identity"
    private static let installAccount = "installId"
    private static let fallbackInstallKey = "identity.installId"
    static let appAccountTokenKey = "pro.appAccountToken"
    private static let lock = NSLock()
    private static var cachedInstallId: UUID?

    static var installId: UUID {
        lock.lock(); defer { lock.unlock() }
        if let u = cachedInstallId { return u }
        let u = readKeychain().flatMap(UUID.init(uuidString:))
            ?? UserDefaults.standard.string(forKey: fallbackInstallKey).flatMap(UUID.init(uuidString:))
            ?? UUID()
        writeKeychain(u.uuidString.lowercased())
        // Mirror so an unavailable Keychain (unsigned simulator hosts) never forks the identity.
        UserDefaults.standard.set(u.uuidString.lowercased(), forKey: fallbackInstallKey)
        cachedInstallId = u
        return u
    }

    static var installIdString: String { installId.uuidString.lowercased() }

    static var appAccountToken: UUID {
        lock.lock(); defer { lock.unlock() }
        if let s = UserDefaults.standard.string(forKey: appAccountTokenKey), let u = UUID(uuidString: s) { return u }
        let u = UUID()
        UserDefaults.standard.set(u.uuidString, forKey: appAccountTokenKey)
        return u
    }

    static var appAccountTokenString: String { appAccountToken.uuidString.lowercased() }

    // MARK: - Keychain

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: installAccount]
    }

    private static func readKeychain() -> String? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKeychain(_ value: String) {
        let attrs: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        if SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = baseQuery
            add.merge(attrs) { $1 }
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
