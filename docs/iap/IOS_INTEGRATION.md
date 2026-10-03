# iOS ↔ server integration: StoreKit 2, devices, push

Server: `server/` (Express 5 + MySQL), live at **`https://grepawk.com/music-radar`**. Endpoint shapes: [`../IOS_HANDOFF.md` §8](../IOS_HANDOFF.md#8-api-reference). Telemetry: [`../telemetry.md`](../telemetry.md).
Status: the server, the ASC products and ASSN v2 are live. **None of the client code below exists in `Sources/App` yet.**

## 1. Products (ASC, created by `asc-setup-iap.yml`)

| Product ID | Type | USD | Trial |
|---|---|---|---|
| `com.ragnus.pnge.pro.monthly` | auto-renewable, group "AI Music Radar Pro", level 2 | 4.99/mo | 7-day free (intro offer) |
| `com.ragnus.pnge.pro.yearly` | auto-renewable, same group, level 1 (higher) | 29.99/yr | 7-day free (intro offer) |
| `com.ragnus.pnge.lifetime` | non-consumable | 49.99 | – |

Note: `docs/paywall/PAYWALL_FLOW.md` used the placeholder `com.ragnus.pnge.pro.lifetime`. The real ID is `com.ragnus.pnge.lifetime`.
Pro = an `active`/`trial`/`grace` subscription **or** an owned lifetime. `GET /api/iap/products` returns the catalog. Display prices always come from `Product.displayPrice` (StoreKit), never from the server.

## 2. appAccountToken

The server keys entitlements by a UUID that the app owns.

```swift
enum AccountToken {
    static func current() -> UUID {           // Keychain, kSecAttrAccessibleAfterFirstUnlock, survives reinstall
        if let s = Keychain.read("appAccountToken"), let u = UUID(uuidString: s) { return u }
        let u = UUID(); Keychain.write("appAccountToken", u.uuidString); return u
    }
}
let result = try await product.purchase(options: [.appAccountToken(AccountToken.current())])
```

Apple embeds the token in the signed transaction. If you pass `appAccountToken` explicitly and it differs from the one inside the JWS, the server rejects the transaction (`appAccountToken does not match the transaction`). A purchase made without a token (for example, from another device before this code shipped) is still linked when you send it to `/restore` with this device's token.

## 3. Purchase → verify

```swift
switch result {
case .success(let verification):
    guard case .verified(let tx) = verification else { /* show error */ return }
    let ent = try await api.post("/api/iap/verify",
        ["signedTransaction": verification.jwsRepresentation, "appAccountToken": AccountToken.current().uuidString])
    await tx.finish()                     // finish after the server call (or after the retry queue has it)
    Entitlements.shared.update(fromStoreKit: true)
case .userCancelled, .pending: break
@unknown default: break
}
```

- The server verifies the JWS offline against Apple Root CA G3. It checks the bundle ID (`com.ragnus.pnge`) and that the product ID is known, then upserts `iap_transactions` and `subscriptions`.
- If the network fails, queue the JWS and retry. **Never** block unlocking on the server: StoreKit's verified transaction is enough to unlock locally.
- Also listen for `Transaction.updates` at app launch (renewals, Ask to Buy, purchases on other devices). Post each verified one to `/verify`, then call `finish()`.

## 4. Restore

```swift
var jws: [String] = []
for await r in Transaction.currentEntitlements { if case .verified = r { jws.append(r.jwsRepresentation) } }
try? await AppStore.sync()   // only from the explicit "Restore Purchases" button (it prompts for sign-in)
let resp = try await api.post("/api/iap/restore", ["signedTransactions": jws, "appAccountToken": token])  // ≤ 50
```

The response includes `results[]` (one per JWS, with `ok:false` plus an `error` for rejected ones) and the merged `entitlement`.

## 5. Entitlement source of truth

1. **StoreKit is authoritative on the device.** Compute `isPro` from `Transaction.currentEntitlements`, where a verified, non-revoked, unexpired transaction for one of the 3 IDs counts. Cache the result in `UserDefaults` for a cold start while offline.
2. **The server is the cross-device and analytics view:** `GET /api/iap/entitlement?appAccountToken=…` returns `{pro, plan, status, expiresAt, items[]}`. Use it for support and debugging, and as a hint when StoreKit has nothing yet. Don't let `pro:false` from the server override a verified local transaction.
3. App Store Server Notifications V2 (renewals, expirations, refunds, grace, billing retry) reach `POST /api/iap/notifications` for both production and sandbox. They keep the server state current without the app doing anything.

Server statuses: `active`, `trial`, `grace` (entitled); `billing_retry`, `expired`, `revoked` (not entitled). `plan` is `free`, `lifetime`, or the subscription product ID.

## 6. Paywall gating (free live view vs Pro)

From [`docs/paywall/PAYWALL_FLOW.md`](../paywall/PAYWALL_FLOW.md) (the owner signed off on pricing; the gates are still a draft):

- **Free, always:** listen live, see the score (Page and Piano roll), playback, MP3 of the take, photo of the page.
- **Free, limited:** 3 saved pieces, the first 30 s of imported audio, PDF of the first 30 s.
- **Pro:** unlimited saves, full-length import and PDF, MIDI and MusicXML export.
- Triggers, the never-show rules, and the mockups are in PAYWALL_FLOW.md. Gate with one `Entitlements.shared.isPro` check per feature. Never interrupt recording or transcription.

Copy that the review guidelines require on the paywall: price per period, trial length with "then $X/period", auto-renew and cancel text, and links to Terms (https://grepawk.com/music-radar/terms) and Privacy (https://grepawk.com/music-radar/privacy). Include a Restore button.

## 7. Device registration

On every launch, and when the app version changes:

```json
POST /api/devices/register
{"installId":"<UUID in Keychain>","appAccountToken":"<UUID>","osVersion":"18.0","appVersion":"1.0","buildNumber":"6",
 "deviceModel":"iPhone17,1","locale":"en_US","timezone":"America/Los_Angeles"}
→ {"ok":true,"deviceId":42,"serverTime":"2026-10-03T18:00:00.000Z"}
```

`installId` is a separate Keychain UUID. Don't use `identifierForVendor`, so that no device identifier leaves the phone. The call also works as the heartbeat (`last_seen_at`). Fields not sent keep their previous values.

## 8. Push (APNs)

Xcode setup, which **isn't done yet**:
- Add the Push Notifications capability to target `EarSheet`. That creates `EarSheet.entitlements` with `aps-environment` and sets `CODE_SIGN_ENTITLEMENTS`.
- Enable Push Notifications on App ID `com.ragnus.pnge` in the developer portal. Then the CI App Store profile (`ZVGVFXJTSU`, created by `ios-testflight.yml`) has to be **regenerated** so it carries the entitlement: delete it or let the workflow create a new one. Deleting a profile needs owner approval.
- Server topic: `com.ragnus.pnge`. The key is the team's APNs auth key (token-based, works for both environments).

```swift
UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])  // ask at a meaningful moment, not first launch
UIApplication.shared.registerForRemoteNotifications()
// AppDelegate:
func application(_ app: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken t: Data) {
    let hex = t.map { String(format: "%02x", $0) }.joined()
    #if DEBUG
    let env = "sandbox"       // Xcode builds → development APNs
    #else
    let env = "production"    // TestFlight + App Store → production APNs
    #endif
    api.post("/api/push/register", ["installId": installId, "token": hex, "environment": env])
}
```

- `POST /api/push/register` → `{"ok":true}`. It upserts the device as well, and re-enables a token that was disabled.
- On sign-out or when notifications are turned off: `POST /api/push/unregister {"installId","token"}` → `{"ok":true,"disabled":1}`.
- When a server send gets APNs 410, `BadDeviceToken`, `Unregistered` or `DeviceTokenNotForTopic`, the server disables that token. Test sends go through the admin panel (Push tokens → test push). No automated pushes exist yet.
