# Fixer stream plan (round 2, AI Music Radar)

Repo `yishengjiang99/earsheet`. Prep PR #6 (merged, squash `0dba134`): `ios-sim.yml` is `workflow_dispatch`-only (concurrency kept) and the allowlist already contains `EntitlementManagerTests, PurchaseFlowTests, RestoreFlowTests, QuotaGateTests, PaywallTriggersTests, UpgradePromptPolicyTests, ListeningFlowTests, LibraryStorageTests, ExportFlowTests, SettingsTests, OnboardingTests, TelemetryPrivacyTests`. **Fixers must not edit `ios-sim.yml` or `TODO.md`.**

## Merge order
`PR #6 (done)` → **Stream A** → **Stream B** (B1 then B2) → **Stream C** (F13.1 last) → **Stream D** (stack, bottom-up). Squash-merge with `--match-head-commit <sha>`; no `--delete-branch` on stacked bases; `Fixes #N` only when a PR fully fixes the issue, else `Refs #N`. Do not merge on red (main is unprotected). Sim CI is manual: the CoS dispatches `gh workflow run ios-sim.yml --ref <branch>` one at a time; one final run on `main` before TestFlight.

## Project facts for fixers
- `Sources/App` and `Tests/EarSheetTests` are Xcode synchronized folders (`PBXFileSystemSynchronizedRootGroup`): **new .swift/test files need no pbxproj edit** (unlike round one). New tests must live in one of the allowlisted classes (new files in `Tests/EarSheetTests`, class name from the list).
- No feature flags; analytics anonymous (allow-listed scalar props, no PII); never touch `docs/asc/APP_IDENTITY.md`; never dispatch asc-* workflows; do not print secrets.
- StoreKit tests: `SKTestSession(contentsOf: Products.storekit)` (see `PaywallPricingTests.testProductsLoadFromLocalStoreKitSession`); skip gracefully when unavailable.
- Update `ServerIntegrationTests.testEventNamesMatchTicketList` when adding telemetry events (#29).

## Stream A — shared infrastructure: StoreKit / entitlement / paywall / Settings (merges FIRST)

Issues (in suggested PR order): #9 [P7.4] P1, #28 [P4.2] P3, #16 [P6.4] P2, #15 [P6.2] P2, #29 [P10.2] P3, #13 [P5.3] P2, #14 [P2.8] P2, #25 [F12.6] P2

Issue numbers: #9, #28, #16, #15, #29, #13, #14, #25  (8)

Files: Sources/App/ProStore.swift, ContentView.swift, EarSheetApp.swift, PaywallView.swift, SettingsView.swift, Telemetry.swift, Tests/EarSheetTests/ServerIntegrationTests.swift (event-name list test, #29 only)
Test classes: EntitlementManagerTests, PurchaseFlowTests, RestoreFlowTests, SettingsTests, TelemetryPrivacyTests
Notes: Suggested PR order inside A to keep rebases trivial (ProStore first, views after): P7.4 → P4.2 → P6.4 → P6.2 → P10.2 → P5.3 → P2.8 → F12.6. P6.2/P6.4 share a `RestoreResult`; P5.3/P2.8 both edit PaywallView (one Pro branch + one onChange). Do not touch LibraryView/ListeningView/ExportView.

## Stream B — quota / scan gate / core input flow (merges after A)

Issues (in suggested PR order): #7 [F9.4] P1, #8 [P1.5] P1, #12 [F9.6] P2, #22 [F9.2] P2, #23 [F9.5] P2, #30 [F9.8] P3, #17 [F3.3] P2, #18 [F4.3] P2, #19 [F4.7] P2, #10 [F5.6] P1, #21 [F7.1] P2, #20 [F7.3] P2, #35 [F2.5] P3, #26 [F4.6] P2, #33 [F4.4] P3, #36 [P1.8] P3, #32 [F10.7] P3

Issue numbers: #7, #8, #12, #22, #23, #30, #17, #18, #19, #10, #21, #20, #35, #26, #33, #36, #32  (17)

Files: Sources/App/LibraryView.swift, ListeningView.swift, TakeLibrary.swift, ShareSheet.swift (AudioImporter), SessionDebugExport.swift, ExportView.swift (#32 F10.7 only, debug section + clipboard), PaywallView.swift (#8 P1.5 copy lines 110/244/255 only; rebase on A)
Test classes: QuotaGateTests, ListeningFlowTests, LibraryStorageTests, PaywallTriggersTests (#36 P1.8)
Notes: Two fixers may work in parallel, merged B1 then B2. **B1 (LibraryView/import chain):** F9.4 → P1.5 → F9.6 → F9.2 → F9.5 → F9.8. **B2 (ListeningView/TakeLibrary chain):** F3.3 → F4.3 → F4.7 → F5.6 → F7.1 → F7.3 → F2.5 → F4.6 → F4.4 → P1.8 → F10.7. F5.6 before F7.3 (discard path); F7.1 lands before F7.3's launch sweep (both touch TakeLibrary load/init). P1.5 decides the import policy (default: free 30 s, Pro 60 s); it must NOT edit docs/asc/review_notes.txt (Stream C's P11.1 owns that file and aligns it with the P1.5 outcome).

## Stream C — library/export/docs/misc (independent of A; merge after B for shared files)

Issues (in suggested PR order): #11 [P10.4] P1, #24 [F10.3] P2, #31 [F10.6] P3, #27 [P11.1] P2, #34 [P11.2] P3, #38 [F1.5] P3, #37 [F13.1] P3

Issue numbers: #11, #24, #31, #27, #34, #38, #37  (7)

Files: Sources/App/PrivacyInfo.xcprivacy (new), ExportView.swift, OnboardingView.swift, docs/asc/review_notes.txt, docs/asc/metadata/en-US/*.txt, and (F13.1 only) ListeningView.swift, TakeLibrary.swift, SheetDetailView.swift, BundledModels.swift
Test classes: ExportFlowTests, OnboardingTests, SettingsTests (review-notes lint), TelemetryPrivacyTests (manifest)
Notes: P10.4, F10.6/F10.3 (ExportView), P11.2, F1.5 have no overlap with A and can open in parallel; merge them after B (ExportView is touched by B's F10.7). P11.1 merges after B's P1.5 (same sentence). F13.1 is cross-cutting and merges LAST in C, after A and B. Docs/metadata edits are repo-only: NEVER run asc-* workflows; the owner uploads to ASC.

## Stream D — upgrade prompts / UX enhancements (stacked, merges LAST, bottom-up)

Issues (in suggested PR order): #39 [P1.9] ENH, #40 [P1.11] ENH, #41 [P2.1] ENH, #42 [P1.12] ENH, #43 [P1.10] ENH, #44 [P3.5] ENH, #45 [P9.4] ENH

Issue numbers: #39, #40, #41, #42, #43, #44, #45  (7)

Files: Sources/App/PaywallTriggers.swift, UpgradePromptPolicy.swift (new), LibraryView.swift, ExportView.swift, PaywallView.swift, SettingsView.swift, new sheet/card views
Test classes: UpgradePromptPolicyTests, PaywallTriggersTests, PurchaseFlowTests (#44)
Notes: Stack: P1.9 ← P1.11 ← P2.1 ← P1.12 ← P1.10 ← P3.5 ← P9.4, each branch based on the previous. Start only after A, B, C are merged (P1.11 needs B's P1.5, P9.4 needs A's P2.8, P1.9 needs B's P1.8). Never delete a stack base branch; retarget dependents to main before merging a base; merge bottom-up. No feature flags; analytics anonymous.

## Per-issue file ownership (grep of each issue's Location)

| Issue | Stream | Primary files |
|---|---|---|
| #9 [P7.4] | A | Sources/App/ContentView.swift, Sources/App/EarSheetApp.swift, Sources/App/ProStore.swift |
| #28 [P4.2] | A | Sources/App/ProStore.swift |
| #16 [P6.4] | A | Sources/App/ProStore.swift |
| #15 [P6.2] | A | Sources/App/PaywallView.swift, Sources/App/ProStore.swift, Sources/App/SettingsView.swift |
| #29 [P10.2] | A | Sources/App/ProStore.swift, Sources/App/Telemetry.swift |
| #13 [P5.3] | A | Sources/App/PaywallView.swift, Sources/App/ProStore.swift |
| #14 [P2.8] | A | Sources/App/PaywallView.swift, Sources/App/SettingsView.swift |
| #25 [F12.6] | A | Sources/App/SettingsView.swift |
| #7 [F9.4] | B | Sources/App/LibraryView.swift |
| #8 [P1.5] | B | Packages/HearSheet/Sources/HearSheet/AudioCapture.swift, Sources/App/LibraryView.swift, Sources/App/PaywallView.swift, Sources/App/ProStore.swift, docs/asc/review_notes.txt |
| #12 [F9.6] | B | Packages/HearSheet/Sources/HearSheet/AudioCapture.swift, Sources/App/LibraryView.swift |
| #22 [F9.2] | B | Sources/App/LibraryView.swift |
| #23 [F9.5] | B | Sources/App/LibraryView.swift |
| #30 [F9.8] | B | Sources/App/LibraryView.swift, Sources/App/ShareSheet.swift |
| #17 [F3.3] | B | Sources/App/ListeningView.swift |
| #18 [F4.3] | B | Sources/App/ListeningView.swift |
| #19 [F4.7] | B | Sources/App/ListeningView.swift |
| #10 [F5.6] | B | Sources/App/ListeningView.swift |
| #20 [F7.3] | B | Sources/App/ListeningView.swift, Sources/App/SessionDebugExport.swift |
| #21 [F7.1] | B | Sources/App/TakeLibrary.swift |
| #35 [F2.5] | B | Sources/App/ListeningView.swift, Sources/App/TakeLibrary.swift |
| #26 [F4.6] | B | Packages/HearSheet/Sources/HearSheet/AudioCapture.swift, Sources/App/EarSheetApp.swift, Sources/App/ListeningView.swift |
| #33 [F4.4] | B | Sources/App/LibraryView.swift, Sources/App/ListeningView.swift |
| #36 [P1.8] | B | Sources/App/ListeningView.swift, Sources/App/PaywallTriggers.swift |
| #32 [F10.7] | B | Sources/App/ExportView.swift, Sources/App/ListeningView.swift, Sources/App/SessionDebugExport.swift |
| #11 [P10.4] | C | Sources/App |
| #24 [F10.3] | C | Sources/App/ExportView.swift |
| #31 [F10.6] | C | Sources/App/ExportView.swift, Sources/App/LibraryView.swift |
| #27 [P11.1] | C | Sources/App/LibraryView.swift, Sources/App/ListeningView.swift, docs/asc/review_notes.txt |
| #34 [P11.2] | C | Sources/App/ListeningView.swift, Sources/App/SheetDetailView.swift, docs/asc/metadata/en-US/{subtitle,description,promotional_text}.txt |
| #38 [F1.5] | C | Sources/App/OnboardingView.swift, docs/legal/music-radar/privacy.html |
| #37 [F13.1] | C | Sources/App/BundledModels.swift, Sources/App/ExportView.swift, Sources/App/ListeningView.swift, Sources/App/SheetDetailView.swift, Sources/App/TakeLibrary.swift |
| #39 [P1.9] | D | Sources/App/PaywallTriggers.swift |
| #40 [P1.11] | D | Sources/App/LibraryView.swift |
| #41 [P2.1] | D | Sources/App/ExportView.swift |
| #42 [P1.12] | D | Sources/App/LibraryView.swift |
| #43 [P1.10] | D | Sources/App/LibraryView.swift |
| #44 [P3.5] | D | Sources/App/ExportView.swift, Sources/App/PaywallView.swift |
| #45 [P9.4] | D | Sources/App/LibraryView.swift, Sources/App/SettingsView.swift |
