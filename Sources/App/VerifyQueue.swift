// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Durable retry queue for `POST /api/iap/verify`.
///
/// ProStore enqueues the JWS of every verified StoreKit transaction (purchase, restore,
/// `Transaction.updates`). `drain()` posts them one by one; an item leaves the queue only after
/// the server accepted it (2xx), or after it was rejected as invalid `maxRejections` times
/// (e.g. Xcode's local StoreKit-test signatures, which Apple's root CA never accepts).
/// Offline, 408/429 and 5xx keep the item and stop the drain; it is retried on the next
/// heartbeat. The queue lives in Application Support, so it survives kills and relaunches.
/// After a drain that verified anything, `GET /api/iap/entitlement` refreshes `lastEntitlement`.
/// The server is the cross-device record only: ProStore (StoreKit) stays the source of truth.
actor VerifyQueue {
    struct Item: Codable, Equatable {
        var transactionId: String
        var signedTransaction: String
        var appAccountToken: String
        var attempts = 0
        var rejections = 0
    }

    static let maxRejections = 3
    static let maxItems = 200

    static let shared = VerifyQueue(client: .shared, storeURL: VerifyQueue.defaultStoreURL)

    static var defaultStoreURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EarSheet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("iap-verify-queue.json")
    }

    private let client: APIClient
    private let storeURL: URL
    private(set) var items: [Item] = []
    private(set) var lastEntitlement: APIClient.Entitlement?
    private var draining = false

    init(client: APIClient, storeURL: URL) {
        self.client = client
        self.storeURL = storeURL
        if let data = try? Data(contentsOf: storeURL),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        }
    }

    /// Adds (or refreshes) a transaction. Same transaction ID = one item.
    func enqueue(transactionId: String, signedTransaction: String, appAccountToken: String) {
        if let i = items.firstIndex(where: { $0.transactionId == transactionId }) {
            items[i].signedTransaction = signedTransaction
            items[i].appAccountToken = appAccountToken
        } else {
            items.append(Item(transactionId: transactionId, signedTransaction: signedTransaction,
                              appAccountToken: appAccountToken))
            if items.count > Self.maxItems { items.removeFirst(items.count - Self.maxItems) }
        }
        save()
    }

    /// Posts queued transactions. Returns how many the server accepted.
    @discardableResult
    func drain() async -> Int {
        guard !draining, !items.isEmpty else { return 0 }
        draining = true
        defer { draining = false }
        var verified = 0
        var token: String?
        for item in items {
            do {
                try await client.verify(signedTransaction: item.signedTransaction, appAccountToken: item.appAccountToken)
                items.removeAll { $0.transactionId == item.transactionId }
                verified += 1
                token = item.appAccountToken
            } catch let e as APIClient.APIError where e.isPermanent {
                guard let i = items.firstIndex(where: { $0.transactionId == item.transactionId }) else { continue }
                items[i].attempts += 1
                items[i].rejections += 1
                if items[i].rejections >= Self.maxRejections { items.remove(at: i) }
            } catch {
                // Offline / 5xx / rate limited: keep everything, retry on the next heartbeat.
                if let i = items.firstIndex(where: { $0.transactionId == item.transactionId }) { items[i].attempts += 1 }
                break
            }
            save()
        }
        save()
        if let token, let ent = try? await client.entitlement(appAccountToken: token) {
            lastEntitlement = ent
        }
        return verified
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
