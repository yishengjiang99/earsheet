# iOS work handoff: branch `ios/iap-server-integration` (paused 2026-10-03 11:52 PT)

The work was paused on the owner's request. The PR "iOS: StoreKit 2 IAP, server integration, fixes (WIP)" targets `main` and must not be merged until CI is green and the next steps below are done.

## Branch history
- `4fe3fbf` Server integration: `APIClient`, Keychain `installId` and `appAccountToken`, `Telemetry`, `PushManager` + `AppDelegate`, `AppLifecycle`, and push entitlements
- `dc875a3` HearSheet: explicit 10-minute take limit, cancellable transcription, per-model thresholds, tail-only live decode
- `76bb534` StoreKit 2: `ProStore`, `PaywallGate`, `PaywallView`, `ExportOptions`, `Sources/AIMusicRadar.storekit` (scheme Run action)
- `5a35628` App: Pro gates, shared model loader, cancellable import and live session, visible take limit, Settings, and onboarding and mic copy
- `8b76aa5` Tests: `MonetizationTests`, added to `ios-sim.yml`
- `7c06dd2` docs: `IOS_HANDOFF.md` §11 TODOs updated
- `5436cfc` Merge of `main` (`bfe5228`), which had picked up a parallel StoreKit implementation from `agent/ios-iap` (`c940b1e`, `283c564`, `8df2117`). See "Merge decisions".

## Done
- **StoreKit 2** (`ProStore.swift`)
  - Products: `com.ragnus.pnge.pro.monthly`, `.pro.yearly` and `com.ragnus.pnge.lifetime`.
  - Purchases carry `.appAccountToken`, a Keychain UUID.
  - The app listens to `Transaction.updates` and `Transaction.unfinished`.
  - Entitlement comes from `currentEntitlements`, with a UserDefaults cache.
  - Each verified JWS is queued, persisted, and retried to `POST /api/iap/verify` before `finish()`.
  - Restore runs `AppStore.sync()` and then `POST /api/iap/restore`.
  - `GET /api/iap/entitlement` is used only as a hint; the device stays authoritative.
  - Telemetry records only StoreKit error codes, never message text.
- **Paywall** (`PaywallView.swift`, as specified in `PAYWALL_FLOW.md` §3b)
  - Close button is visible from the first frame. Yearly is preselected.
  - Prices come from `displayPrice`. It shows a trial timeline, a Free vs Pro table, the privacy note and the auto-renew disclosure.
  - Restore, Terms and Privacy links are included.
  - After purchase, `ProUnlockedView` offers a "Turn on trial reminder" (local notification). This is the only place, besides the Settings toggle, where push permission is requested.
- **Gates** (free tier is the live view)
  - Saves are capped at 3. The 4th take stays viewable but isn't saved, and "Keep it with Pro" saves it after purchase.
  - Imports longer than 30 s get a choice: "first 30 s free" or "Whole file with Pro".
  - Free PDF covers the first 30 s. MIDI and MusicXML are locked.
  - The library shows a card after the 3rd transcription.
  - Caps live in `PaywallGate`: 1 per session, 2 per 7 days, a 72 h cooldown, and none after 5 dismissals.
- **Server** (`APIClient.swift`, base `https://grepawk.com/music-radar`, overridable with `MUSIC_RADAR_API_BASE`)
  - Device register: on launch, on version change, and on foreground at most every 6 h.
  - Push: register and unregister.
  - IAP: verify, restore and entitlement.
  - Telemetry batch: disk queue, flushed every 30 s, at 50 events, or on background (inside a background task). It honors Retry-After, backs off from 5 s to 10 min, drops on 4xx, and caps the queue at 5000. There is an opt-out toggle in Settings.
  - Event names follow `docs/telemetry.md`. No audio, notes, titles or file names are sent.
- **Push**
  - `CODE_SIGN_ENTITLEMENTS`: Debug uses `Sources/EarSheet-Debug.entitlements` (`aps-environment=development`). Release uses `Sources/EarSheet.entitlements` (`production`), which matches CI profile `GLML8673YB`.
  - The token goes to the server with environment `sandbox` in DEBUG and `production` otherwise.
- **Bug fixes**
  - `runDetached` passes cancellation through to detached work, and `Transcriber` checks for cancellation on each window.
  - Imports can be cancelled from the overlay. Leaving the listening screen cancels the model load, the mic and the final decode.
  - The take limit is now explicit at 10 min (`AppConfig.Limits`, `AudioRecorder.maxRecordingSeconds`). It shows `mm:ss / 10:00`, counts down in the last minute, and shows a notice when it stops the take. `onLimitReached` replaces the old silent drop. This also fixes a negative-count crash in the tap.
  - There is one model loader: `TranscriptionModel` over `ModelBox.shared`.
- **Model swap-in**
  - An optional `models/BasicPitchPoly.profile.json` (`{"name","onsetThreshold","frameThreshold"}`) sets the decoder thresholds and the `model` telemetry property.
  - Live decode only processes the last 20 s, so its cost stays flat on long takes.
- **Polish**
  - Settings: plan status, Go Pro or Manage subscription, Restore, Notifications and analytics toggles, Privacy, Terms and Support links, and version.
  - Onboarding and mic-permission copy no longer make "real-time" claims. If mic access is denied, "Open Settings" is offered.
- **Kept from main:** MIDI file import, video import from Photos (now with a free 30 s truncate option), and the `OMR_MODELS_DIR` fix in `StreamingExportTests`.

## Merge decisions (main's `agent/ios-iap` vs this branch)
At 11:45 PT, `main` merged a second, smaller StoreKit implementation with no server integration. That main build was **broken**: `ExportView.swift:81: cannot find type 'QuantizedScore'` (run 37145381406). The merge commit `5436cfc` keeps this branch's `ProStore`, `PaywallView`, `SettingsView` and `PaywallGate`. It **deletes** main's `PaywallTriggers.swift`, `ExportView.swift`, `TaskCancellation.swift`, `Products.storekit` and `Tests/EarSheetTests/ProStoreTests.swift`; `MonetizationTests` covers what those tests did. **The owner should confirm this choice before merging.**

## CI status at pause
- Run **37145025837** (branch, before the merge): the app and tests **compiled**, and the HearSheet and SF2Player package tests passed. `StreamingExportTests.testShortTakeMatchesBatch` and `testStreamingMatchesBatchOnTriadWav` failed. They also fail on `main` (runs 37143438239 and 37144357504) because the models directory was read from `TEST_RUNNER_OMR_MODELS_DIR`. Main's fix (`3cd0e8e`) is now merged in.
- Run **37145702243** (workflow_dispatch on `5436cfc`, after the merge) was **still in progress** at pause. Check it with `gh run view 37145702243`. A `pull_request` run also starts when the PR opens.

## Known issues / risks
- Nothing has been tested on a device: no sandbox purchase, no real APNs token, and no telemetry going to the live server from a build.
- The 10-minute live take holds roughly 200 MB at the end (raw samples, padded copy, and posteriorgram frames). Profile it on an older iPhone. If that's too much, lower `Transcriber.maxDurationSeconds`; it is the single knob.
- `AVAudioSession.recordPermission` is deprecated in iOS 17 (warning only). Moving to `AVAudioApplication` is a follow-up.
- Not built: the soft export interstitial (screen 1), "Replace an older take" on the save-limit flow, and the Lifetime $39.99 launch price.
- `ios-sim.yml` runs on `push` to main and on `pull_request` only. For branches, use `gh workflow run ios-sim.yml --ref <branch>`.
- TestFlight was **not** triggered from this branch. `ios-testflight.yml` archives the Release config, which now signs with the push entitlement and profile `GLML8673YB`. That has not been exercised yet.

## Next steps for whoever resumes
1. `git fetch && git checkout ios/iap-server-integration && git merge origin/main`. Use a merge, not a rebase: the branch is pushed and shared.
2. Get CI green: `gh run view 37145702243 --log-failed`. If compile errors show up, they will be in the files touched by `5436cfc` (`LibraryView` MIDI and video paths, `AudioImport.loadMono22050(asset:truncate:)`).
3. Have the owner confirm the merge decisions above, then merge the PR.
4. Run `gh workflow run ios-testflight.yml --ref main -f notes="StoreKit 2 + server"` and confirm the archive signs with the push entitlement.
5. On TestFlight, using a sandbox account, check:
   - A trial purchase shows up as `Sandbox` in the admin panel.
   - Restore works.
   - The trial reminder appears.
   - A test push from the admin panel arrives.
   - Telemetry appears in the admin Telemetry tab.
6. Follow-ups: the soft interstitial, replace-a-take, the launch price, and `AVAudioApplication`.
