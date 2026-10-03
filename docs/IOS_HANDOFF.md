# iOS developer handoff: AI Music Radar

Start here. This page is the map, and the detail lives in the linked docs. Everything here is taken from code on `main` and the deployed server (checked 2026-10-03).

## 1. App identity (locked: [`asc/APP_IDENTITY.md`](asc/APP_IDENTITY.md))

| | |
|---|---|
| App / display name | **AI Music Radar** |
| Bundle ID | `com.ragnus.pnge` (tests `com.ragnus.pnge.tests`) |
| ASC app | `6818838017`, SKU `SI-music-radar` |
| Team | `83D36RPMUM` (GrepAwk LLC) |
| Xcode | `EarSheet.xcodeproj`, scheme and target **`EarSheet`** (internal name), version 1.0, iOS 17.0+, iPhone portrait, iPad all orientations |
| Info.plist | generated (`INFOPLIST_KEY_*` build settings): mic and photo-add usage strings, `ITSAppUsesNonExemptEncryption = NO` |
| Legal | https://grepawk.com/music-radar/support · /privacy · /terms (source [`legal/music-radar/`](legal/music-radar/)) |

## 2. Repo layout

- `Sources/App`: the SwiftUI app (`EarSheetApp`, `ListeningView` for live listening, `LibraryView`, `SheetDetailView`, `StaffPageView`, `OnboardingView`, `TakeLibrary`, exporters, `BundledModels`).
- `Packages/HearSheet`: transcription (Basic Pitch Core ML → notes → score). `Packages/SF2Player`: playback. `Packages/LAME`: MP3.
- `Tests/EarSheetTests`: `SmokeTests`, `ImportTranscriptionTests` (Core ML triad), `StreamingExportTests`.
- `scripts/fetch-models` + `models.lock`: downloads and pins the Core ML model into `models/` (it isn't committed). `scripts/asc/`: App Store Connect automation.
- `server/`: the backend described below. `web/`: browser demo. `docs/`: everything else.

## 3. Build and run

```sh
scripts/fetch-models                      # required: the app bundles models/ (the Core ML package)
open EarSheet.xcodeproj                   # scheme EarSheet; set your own team for device runs, or use 83D36RPMUM
swift test --package-path Packages/HearSheet
```

Simulator tests as CI runs them:
`xcodebuild test -project EarSheet.xcodeproj -scheme EarSheet -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:EarSheetTests/SmokeTests -only-testing:EarSheetTests/ImportTranscriptionTests -only-testing:EarSheetTests/StreamingExportTests CODE_SIGNING_ALLOWED=NO` (set `TEST_RUNNER_OMR_MODELS_DIR=$PWD/models`).

## 4. CI and TestFlight (`.github/workflows/`)

- `ios-sim.yml`: runs on every push and PR to main (docs and ASC-only changes are ignored). Simulator tests above plus the HearSheet and SF2Player package tests.
- `ios-testflight.yml` (manual, input `notes`): checks that ASC app 6818838017 has bundle ID `com.ragnus.pnge`. It then reuses or creates the App Store profile via the ASC API ("AI Music Radar App Store (CI)", `ZVGVFXJTSU`), archives with build number = run number, uploads, and waits for processing. `gh workflow run ios-testflight.yml --ref main -f notes="…"`.
  - Latest: **build 6**, VALID and ready for beta testing. TestFlight group "Internal" (all builds).
- Secrets (names only): `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY_P8`, `IOS_DISTRIBUTION_P12_BASE64`, `IOS_DISTRIBUTION_P12_PASSWORD`, and the optional, unset `IOS_APPSTORE_PROFILE_PNGE_BASE64`. See [`../AGENTS.md`](../AGENTS.md).
- ASC helpers: `asc-status`, `asc-assign-internal-testing`, `asc-beta-group-remove-testers`, `asc-set-urls`, `asc-setup-iap`, `asc-submit-app-store`, `asc-cancel-review`, `asc-clear-export-compliance`, `ios-screenshots`. Server: `server-ci.yml`.

## 5. Products and pricing (live in ASC)

| Product ID | Type | USD | Trial |
|---|---|---|---|
| `com.ragnus.pnge.pro.monthly` | auto-renewable, group "AI Music Radar Pro" | $4.99/month | 7-day free |
| `com.ragnus.pnge.pro.yearly` | auto-renewable, same group (higher level) | $29.99/year | 7-day free |
| `com.ragnus.pnge.lifetime` | non-consumable | $49.99 | – |

Prices for 175 territories (Apple-equalized from USA) and availability are set, ASSN v2 points at the server, and all three are in `MISSING_METADATA` until each gets a review screenshot. Created by `scripts/asc/setup_iap.py` / `asc-setup-iap.yml`, which is idempotent and create-only.

## 6. StoreKit 2, entitlements, paywall → [`iap/IOS_INTEGRATION.md`](iap/IOS_INTEGRATION.md)

- **appAccountToken:** a Keychain UUID passed as `.appAccountToken(_)` on every `purchase`. The server keys entitlements by it.
- **Verify:** after each verified purchase and each `Transaction.updates` item, `POST /api/iap/verify` with `jwsRepresentation`, then call `finish()`.
- **Restore:** send `Transaction.currentEntitlements` JWS to `POST /api/iap/restore` (`AppStore.sync()` only from the Restore button).
- **Entitlement:** StoreKit on the device is authoritative. `GET /api/iap/entitlement` is the server cross-check. Pro = active, trial or grace subscription, or lifetime.
- **Paywall:** the live view, the score, playback, MP3 and the page photo stay free. Pro unlocks unlimited saves (free: 3), full-length import and PDF (free: 30 s), and MIDI/MusicXML. Triggers and mockups: [`paywall/PAYWALL_FLOW.md`](paywall/PAYWALL_FLOW.md).

## 7. Devices, push, telemetry

- **Device:** `POST /api/devices/register` on launch with a Keychain `installId` (not the IDFV). Details in [IOS_INTEGRATION §7](iap/IOS_INTEGRATION.md#7-device-registration).
- **Push:** add the Push Notifications capability (`aps-environment` entitlement, `EarSheet.entitlements`) and enable Push on App ID `com.ragnus.pnge`, then regenerate the CI profile. Send the hex token to `POST /api/push/register` with `environment` set to `sandbox` for Xcode/debug builds or `production` for TestFlight/App Store. Topic `com.ragnus.pnge`. Details in [IOS_INTEGRATION §8](iap/IOS_INTEGRATION.md#8-push-apns).
- **Telemetry:** on-disk queue, flushed every 30 s, at 50 events, or on background; backoff, and honor `Retry-After`. No audio or PII. Event list and limits: [`telemetry.md`](telemetry.md).

## 8. API reference

Base URL **`https://grepawk.com/music-radar`** (`server/`, Express 5 + MySQL; systemd `music-radar-api` on grepawk.com). JSON in and out. Errors are `{"error": "..."}` (verify returns `{"ok":false,"error":...}`), with 400 for bad input, 413 for too large, and 429 when rate-limited.

| Method | Path | Body / query | Limit |
|---|---|---|---|
| GET | `/api/health` | – | – |
| GET | `/api/iap/products` | – | – |
| POST | `/api/iap/verify` | `{signedTransaction, appAccountToken?}` | 60/min/IP |
| POST | `/api/iap/restore` | `{signedTransactions[≤50], appAccountToken}` | 60/min/IP |
| GET | `/api/iap/entitlement` | `?appAccountToken=UUID` | – |
| POST | `/api/iap/notifications` | `{signedPayload}` (Apple only, ASSN v2) | – |
| POST | `/api/devices/register` | see below | 30/min/IP |
| POST | `/api/push/register` | `{installId, token, environment}` | 30/min/IP |
| POST | `/api/push/unregister` | `{installId, token}` | 30/min/IP |
| POST | `/api/telemetry/batch` | `{events:[…]}` | 30/min per IP and per install |

Examples (the health, products, entitlement and error responses are real output from the live server):

```jsonc
GET /api/health
{"ok":true,"service":"music-radar-api","version":"1.0.0","db":true,"bundleId":"com.ragnus.pnge","apns":true,"admin":true}

GET /api/iap/products
{"bundleId":"com.ragnus.pnge","subscriptionGroup":"AI Music Radar Pro","products":[
 {"id":"com.ragnus.pnge.pro.monthly","kind":"subscription","plan":"monthly","priceUsd":4.99,"trialDays":7},
 {"id":"com.ragnus.pnge.pro.yearly","kind":"subscription","plan":"yearly","priceUsd":29.99,"trialDays":7},
 {"id":"com.ragnus.pnge.lifetime","kind":"lifetime","plan":"lifetime","priceUsd":49.99,"trialDays":0}]}

POST /api/iap/verify  {"signedTransaction":"<Transaction JWS>","appAccountToken":"3f6c…-uuid"}
{"ok":true,
 "transaction":{"ok":true,"productId":"com.ragnus.pnge.pro.yearly","originalTransactionId":"2000000…","status":"trial",
                "expiresAt":"2026-10-10T18:00:00.000Z","kind":"subscription"},
 "entitlement":{"pro":true,"plan":"com.ragnus.pnge.pro.yearly","status":"trial","expiresAt":"2026-10-10T18:00:00.000Z","items":[…]}}
// bad JWS → 400 {"ok":false,"error":"signature verification failed: invalid JWS"}
// other 400s: "bundleId mismatch (expected com.ragnus.pnge)", "unknown productId …", "appAccountToken does not match the transaction"

POST /api/iap/restore  {"signedTransactions":["<JWS>", …],"appAccountToken":"3f6c…"}
{"ok":true,"results":[{"ok":true,"productId":"com.ragnus.pnge.lifetime",…}],"entitlement":{"pro":true,"plan":"lifetime","status":"active","expiresAt":null,"items":[…]}}

GET /api/iap/entitlement?appAccountToken=00000000-0000-4000-8000-000000000000
{"pro":false,"plan":"free","status":"none","expiresAt":null,"items":[]}
// items[]: {originalTransactionId, productId, kind, environment (Sandbox|Production), status, expiresAt, autoRenew, trial}
// status: active | trial | grace (entitled) | billing_retry | expired | revoked

POST /api/devices/register  {"installId":"…","appAccountToken":"…","osVersion":"18.0","appVersion":"1.0","buildNumber":"6","deviceModel":"iPhone17,1","locale":"en_US","timezone":"America/Los_Angeles"}
{"ok":true,"deviceId":42,"serverTime":"2026-10-03T18:00:00.000Z"}

POST /api/push/register  {"installId":"…","token":"<64+ hex>","environment":"production"}   → {"ok":true}
// 400 {"error":"token must be the hex APNs device token"} | "environment must be 'sandbox' or 'production'"
POST /api/push/unregister {"installId":"…","token":"…"}  → {"ok":true,"disabled":1}

POST /api/telemetry/batch {"events":[{"name":"app_open","ts":1791313200,"installId":"…","sessionId":"…","appVersion":"1.0","properties":{"cold":true}}]}
{"ok":true,"accepted":1,"dropped":0}      // invalid events are dropped, not fatal: {"ok":true,"accepted":0,"dropped":1}
```

Server code: `server/src/{iap,devices,telemetry,subscriptions}.ts`. Schema: `server/migrations/001_init.sql`. Tests: `server/test/` (`npm test` against MySQL).

## 9. Admin panel

`https://grepawk.com/music-radar/admin` is password-protected; ask the owner for access. It shows devices, push tokens (with a test-push form), subscriptions and transactions, ASSN events, and telemetry.

## 10. ML model → [`finetune/IOS_MODEL_HANDOFF.md`](finetune/IOS_MODEL_HANDOFF.md)

Release [`model-latest`](https://github.com/yishengjiang99/earsheet/releases/tag/model-latest) (`basic-pitch-model-ft-exp0-{coreml,savedmodel,tfjs}.zip`, `SHA256SUMS`, `models.lock.snippet`). `exp0` is the stock Basic Pitch exported through the pipeline. Pin it in `models.lock` and run `scripts/fetch-models`. The repo is private, so download with `gh release download`. Experiments: [`finetune/EXPERIMENTS.md`](finetune/EXPERIMENTS.md).

## 11. Open TODOs

- [ ] **StoreKit 2 client** (none in `Sources/App` yet): products, purchase with appAccountToken, `Transaction.updates`, verify/restore calls, the `Entitlements` cache, the Restore button.
- [ ] **Paywall UI and gates** per PAYWALL_FLOW (save cap 3, 30 s import/PDF cap, MIDI/MusicXML lock). Lifetime launch price ($39.99 for 30 days) isn't configured.
- [ ] **Push:** capability and `aps-environment` entitlement, enable Push on the App ID, regenerate the CI profile, token registration, and a permission prompt at a sensible moment.
- [ ] **Device registration** and the **telemetry client** (queue, flush, opt-out toggle in Settings).
- [ ] **ASC:** a review screenshot for each of the 3 products, then submit them with the next app version. Marketing URL, EULA and subtitle aren't set.
- [ ] Add a StoreKit configuration file (`.storekit`) for local and simulator testing with the IDs above. Test sandbox purchases on TestFlight (environment `Sandbox` shows up in the admin panel).
- [ ] Ship a fine-tuned model once an experiment beats exp0 (see EXPERIMENTS.md).
- [ ] The server doesn't call the App Store Server API (verification is offline JWS plus ASSN). Add it only if status refresh or refund lookups become necessary.
