# Product & design review — "AI Music Radar" (EarSheet) iOS — round two

Repo `yishengjiang99/earsheet` @ `0dba134` (main; only a CI-workflow change since `5e56458`) · Review date: Sat 2026-10-17 (America/Los_Angeles) · Author: product-review pass (Grok Bot) for Yisheng
**Constraint:** nothing here changes the recognition engine (Basic Pitch / HearSheet), quantizer, engraver or the SF2 playback engine. Every backlog row has a **Touches core?** column: `No` (copy, layout, analytics, store), `Around` (UI wrapped around an unchanged core step), `Additive` (new capability — parked, needs Yisheng's OK).
Companions: `product-tracker.md` (R-table, risks, decisions). The separate auditor owns `flows.md` and bug issues; I cite code locations and mark **[bug candidate]** where something looks like a defect, but file nothing.
Evidence tags: `[CODE path:line]` read in repo · `[S#]` external source (§15) · `[INFERENCE]` my reasoning · `[UNVERIFIED]` could not confirm. I did static reads only; I did **not** run the app (Linux box), so on-device feel is `[INFERENCE]` unless a test/doc says otherwise. No benchmark is invented.

---

## 1. Executive summary

### 1.1 What the app is today (evidence snapshot)

| Area | Fact | Source |
|---|---|---|
| Promise | Hum/play/sing into the mic (≤60 s) → note detection on-device (Core ML Basic Pitch fine-tune) → piano roll, engraved page, playback with highlight, export | [CODE README.md; ListeningView.swift:7-9; Transcriber.swift:13] |
| What you see **while** recording | A **piano roll only** (rolling 10 s window). "No staff, tempo or key yet" | [CODE ListeningView.swift:478-482] |
| What you see **after** | Take opens on **Piano roll**; sheet music is the other tab ("Page"), analysed on first open | [CODE SheetDetailView.swift:10-17,121-125; test SheetAnalysisTests.swift:20] |
| Free / Pro | Free: unlimited recording, **3 saved takes**, MP3 + PNG photo, **PDF of first 30 s**. Pro: unlimited saves, MIDI, MusicXML, full-length PDF | [CODE ProStore.swift:29-31; ExportView.swift:25-72] |
| Plans | Yearly **$29.99** (preselected), Monthly **$4.99**, Lifetime **$49.99**; 7-day free trial on both subs (shown only if StoreKit says eligible) | [CODE Products.storekit; PaywallView.swift:13; ProStore.swift:7-12] |
| Computed | $29.99/12 = **$2.50/mo**; vs 12×$4.99 = $59.88 → yearly saves **49.9%**, and the code floors to **"Save 49%"** (`PaywallPricing.savingsPercent` rounds down) while docs/mockups say "50%". Lifetime = 1.67× yearly = 10 months of monthly | computed [CODE PaywallPricing.swift:95-107] |
| Onboarding | 2 swipe pages ("Hear the music." / "Get the page.") + Skip; no sample, no mic primer, no tips | [CODE OnboardingView.swift:20-27] |
| Library | Two built-in samples ("C Major Scale", "Swedish Folk Tune") + "My Takes"; floating mic button; video-import button; ⌄ import menu; gear → Settings | [CODE LibraryView.swift:28-125; TakeLibrary.swift:182] |
| Paywall triggers | **Only one automatic trigger is wired**: the import-save-limit path (`canShowAuto(.saveLimit)`). `thirdTranscription`, `importLimit`, `exportLockedRow`, `settings` are declared but unused; there is no soft interstitial | [CODE PaywallTriggers.swift; grep: only LibraryView.swift:210-211] |
| Analytics | 9 events: `app_open, session_start, transcription_start/stop, paywall_view, purchase_start/success/fail, restore`; 9 allow-listed property keys; random Keychain install UUID; **opt-out toggle exists** (Settings → "Share anonymous usage data") | [CODE Telemetry.swift:49-70; SettingsView.swift:71] |
| Accessibility | 22 `accessibilityLabel`s across 6 files; staff + piano-roll are custom `UIView`s with **no accessibility info**; whole app forced to light mode | [CODE grep; StaffPageView.swift; ContentView.swift:19] |
| Store | Name "AI Music Radar" (locked), subtitle "Live Audio to Sheet Music", 99-char keywords, 5+5 screenshots, review notes | [CODE docs/asc/metadata; APP_IDENTITY.md] |
| Live status | iTunes lookup for `com.ragnus.pnge` returned `resultCount:0` on 2026-10-17 → **not on the App Store**; no real ratings/funnel data exist | [S12] |

### 1.2 Three strategic findings

1. **The marketing promise ("live", "real-time", "writes the score as you play") is not what the app does — and the repo's own marketing plan already says so.** The live screen shows a piano roll; the staff appears only after Stop, behind a tab. Yet the shipped subtitle ("Live Audio to Sheet Music"), promo text ("It writes the score while you play. Real-time…"), description opener ("writes the score live"), onboarding page 2 ("Watch the score write itself in real time"), and the Library caption ("writes the score as you play") all say otherwise. `MARKETING_PLAN.md` §4 says "Avoid 'live' in store copy: the iOS app transcribes after you stop recording" and `PAYWALL_FLOW.md` §5 says "No 'live' or 'real-time' claims". Guideline 2.3.1 treats promoting functionality the app does not offer as grounds for removal [S2]; the closest comparable's most-quoted negative review is a "false advertisement" complaint about expectations vs. reality [S5]. The truthful version is still a strong differentiator: **a live piano roll while you play, sheet music the moment you stop, on-device, no account** — and cloud rivals explicitly cannot show live note recognition [S5][S6].
2. **The Pro story, the paywall and the code disagree, and upgrade prompts are mostly not wired.** The paywall, review notes and docs promise "full-length audio & video imports" and a Free-vs-Pro row "Import length: First 30 s / Full length" — but the code has **no 30 s cap and a hard 60 s limit for everyone**: a longer file throws `durationLimitExceeded` and the user sees only "Could not read that audio file." [CODE AudioCapture.swift:228-240, 316-326; LibraryView.swift:297-306]. The Settings "Go Pro" row opens the full purchase paywall **even for Pro users** (risk of a second purchase) [CODE SettingsView.swift:33-52]. Meanwhile the natural conversion moments (locked export row, 3rd take, library cap) have no soft step. Fixing truth first, then adding tasteful prompts (Stream D), is the order that protects review and trust.
3. **The first 60 seconds are decent plumbing with no guidance, and several dead-ends sit exactly where first-timers fail.** Cold mic permission on first tap; a 4 pt level bar as the only feedback; every failure (silent, too quiet, no notes, denied, model error with raw `localizedDescription`) lands on one text-plus-"Back to library" screen with no Retry and no "Open Settings"; the prominent video-import button fails for any video over 60 s; and the 4th take is "held" with a banner that does not say it will be **discarded if you leave** [CODE ListeningView.swift:62,92,109,157,455,468,549]. Add dev/debug surfaces still visible to users (mic WAV + note-JSON export, ten-slider noise-gate panel) [CODE ExportView.swift:39-54; ListeningView.swift:408-437; SettingsView.swift:98-133].

### 1.3 Top 5 recommendations (ranked by impact ÷ effort)

| # | Recommendation | Why (one line) | Effort | Impact | Type |
|---|---|---|---|---|---|
| **R1** | **Make "live" claims truthful everywhere**: "live piano roll as you play → sheet music when you stop" in subtitle, promo, description, screenshots, onboarding, Library caption, paywall table | 2.3.1 risk + expectation gap; truthful claim is still unique vs cloud apps | S | High | Listing/copy + string changes |
| **R2** | **Paywall integrity**: copy = actual gates (drop "full-length imports"/"Live transcription" row), Pro users never see purchase UI (Settings → plan status + Manage Subscription), Restore feedback in Settings, trigger-aware headline | 3.1.2/2.3.1; prevents double-purchase and "nothing happened" Restore | S–M | High | Code (Stream D for suppression/copy; Restore feedback = bug candidate) |
| **R3** | **Upgrade-prompt stack (Stream D)**: one `PaywallGate`, saved-pieces meter ("2 of 3 kept"), soft export interstitial with the user's own score, one-time 3rd-take card, held-take fixes (warn on leave, replace-older-take), contextual "PDF shows first 30 of 52 s" line, weekly soft card; caps + Pro/first-session/in-flight suppression | Apple recommends contextual prompts near limits [S1]; generous-free apps tolerate a weekly ask [S4] | M | High | Code — **Stream D** |
| **R4** | **First-run, permission/error/empty states and capture coaching**: sample-first onboarding with mic primer, "Open Settings"/"Try again" on every failure, friendly copy (no raw errors), live level hint, pre-record tips, import >60 s → "Use first 60 s" instead of failing | Day 0 decides conversion and retention [S4]; today every failure is a dead end | M | High | Code (UI only) |
| **R5** | **Store presence**: subtitle/keywords/promo rewrite, screenshots v2 (add the listening screen, mark Pro, refresh stale UI), review-notes fixes, accessibility label plan | Cheapest discoverability win; 2.3.2/2.3.3 hygiene | S–M | High | Listing/assets |

Next in line: R6 remove debug surfaces from the shipped UI · R7 analytics expansion · R8 accessibility · R9 trial timeline + success state · R10 privacy minimisation (push toggle, device heartbeat).

### 1.4 Launch-risk callouts (App Review / trust, not growth)

1. **2.3.1/2.3.7 — "live/real-time" marketing vs behaviour** (R1). High.
2. **3.1.2 / 2.3.1 — Pro benefit that does not exist** ("full-length imports", 30 s free import cap) in paywall + review notes (R2). High.
3. **App Review demo path**: a reviewer in a quiet room taps the mic and gets "Too quiet to transcribe" → could read as non-functional (2.1). Review notes never mention the Samples rows (no mic needed) or "play music near the phone" (R5). Medium.
4. **Pro user shown the purchase paywall** from Settings (R2). Medium.
5. **2.3.2** — screenshot 5 headline "Export MIDI, MusicXML & PDF" with no Pro marker; description does separate Pro, screenshots do not (R5). Medium.
6. **2.3.3 / accuracy of screenshots** — segmented control order and Library chrome in screenshots no longer match the build (§9.4). Medium.
7. **5.1.1/5.1.2 minimisation** — a Notifications toggle that asks for push permission although no push is ever sent ("No automated pushes exist yet" [CODE docs/iap/IOS_INTEGRATION.md §8]); device record/heartbeat continues when usage analytics are off (disclosed in policy, but not needed for an offline app) (R10). Low–Medium.
8. **3.1.2(a) ongoing value** — Pro = export formats + unlimited saves on a v1 product; Lifetime option mitigates. Keep promises to what ships; add an update roadmap to notes (R15/R16). Low–Medium.
9. **Data loss surprise** — a held 4th take is lost when the user taps Library, with no warning (R3). Medium (1★ risk).
10. **Legal/support URL drift** — two privacy-policy sources disagree on operator and host (`web/privacy.html` "grepawk / Yisheng Jiang" vs `docs/legal/music-radar/privacy.html` "GrepAwk LLC", `music.grepawk.com`); ASC `support_url.txt` points to `grepawk.com/music-hear/support.html` while `APP_IDENTITY.md` lists `…/music-radar/support`; the description carries a personal Gmail address and a link to the browser demo. Verify what the live URLs serve before submission (R5/R10, owner). Low–Medium.
11. Review notes in the (public) repo carry a personal phone number; consider keeping contact details in ASC only. Low.

---

## 2. Market & competitor read

All pages read 2026-10-17 unless marked. Prices change often.

### 2.1 Comparable apps — pricing, free tier, paywall pattern

| App (US) | What it does | Free tier | Paid | Notes |
|---|---|---|---|---|
| **Piano2Notes** (Klangio) | Cloud piano transcription; upload/record → score | 20-s demo of each song ("first seconds"), unlimited demos; PDF only | Pro $9.99/mo, $99.99/yr; tokens $2.99–$24.99; Instrument Pro $14.99/mo ($6.24/mo billed annually) | Needs internet and a Klangio account; "not able to show you live note recognition"; 4.27★ (294) [S5][S7][S12] |
| **Melody Scanner** (Klangio) | Cloud; mic/YouTube/file | Mic + YouTube free; **40 bars** cap; uploads are premium | $5.99/mo, $44.99/yr | Account required; 1.7★ (35); review: "needs a login or your email", "amazingly off" results [S6] |
| **Klangio Transcription Studio** (web) | Multi-instrument | **No login, unlimited demos, 20 s/song, PDF**; MIDI/MusicXML paid | $19.99/mo ($8.33 billed annually) | Free plan is explicitly "ideal for testing" [S7] |
| **Reprise: Transcribe Music** | Notes fall onto a keyboard; link/file/mic | not read | not read | Practice tools: slow down, transpose, note names, metronome, mix slider; MIDI+MusicXML export; 4.54★ (435) [S13][S12] |
| **Piano Transcriptionist** | On-device piano → MIDI/score | Free | not read | Note editing, Apple Pencil, follows a played digital piano; 4.3★ (46) [S13] |
| **Anytune: Transcribe & Practice** | Practice/slow-down tool | Free + IAP | not read | 4.8★ (8,543) — proof that *practice tooling* (tempo, loops) earns ratings in this niche [S13][S12] |
| **Shazam** (recognition benchmark) | Song recognition | Free | n/a | Identify-offline-then-sync, **Library with history**, notification when done, Control Center entry, optional auto-listen [S8] |

[INFERENCE] **Positioning gap AI Music Radar can own:** on-device (works offline, no account), a *live* piano roll, a real engraved page, and a generous free tier (60 s recordings, PDF, MP3, 3 saves) versus rivals' 20-second demos and account walls. The risk is the reverse: over-claiming "live sheet music" (finding 1).

### 2.2 What users complain about / want (from the pages actually read)

- "Spent my free point not knowing that I did my recording wrong so it came out splotched… a bit unforgiving"; "just remember to have the room completely silent" → **capture coaching matters** [S5].
- "False advertisement… I clicked 'transcribe rest of piece'… tickets… the app did not advertise any cost" → **be explicit about what is free vs Pro, before the tap** [S5].
- "It needs a login or your email", "Good at first but…", results "jokingly off", notes "6 at a time for one hand" → account walls and accuracy over-promising dominate low ratings; the 1.7★ app is the cloud one [S6].
- A positive on UI: "there is a guide pop-up that tells you about things it can do. I think the UI is well made for such app" → a short guided intro is appreciated even in a utility [S6].
- Search landscape ("audio to sheet music", US store, today): Musician: Audio to Sheet Music (4.0★, 3), Piano2Notes (4.27★, 294), Piano Transcriptionist (4.3★, 46), Flat (4.6★, 6,953), MuseScore (4.61★, 79,071), Musicnotes (4.83★, 43,214), Anytune (4.8★, 8,543). Small apps can reach the first page; AI Music Radar is not yet listed [S12].

### 2.3 Subscription benchmarks that matter here (RevenueCat State of Subscription Apps 2026)

All from [S4]; medians across 115k apps, not music-specific:
- **Freemium download→paid D35: 2.1% median** (hard paywall 10.7%); **North America freemium-style overall 2.8%** (global 2.0%); for freemium, **23% of conversions arrive 6+ weeks after download**, ~**1/3 on day 0**; overall **50.6% of conversions on Day 0**.
- **Trials:** 5–9-day trials convert **37.4%** trial→paid vs **25.5%** for ≤4 days; 7-day trials see **39.8%** of cancellations on Day 0. → The current 7-day trial is in the sweet-spot band; make Day 0 count.
- **Pricing architecture:** yearly median $34.80; "$29.99 or $39.99 yearly in eight of 11 categories"; $4.99–$9.99 monthly typical → **$29.99 / $4.99 is a normal, not aggressive, price point**. One in four apps offers a lifetime plan; apps whose best-seller is yearly show ~2× RPI of monthly/lifetime-dominant apps.
- **Paywall UI:** highlighted pricing 74.5%, "cancel anytime" near the CTA is table stakes, **countdown timers ≤1.4%**, two-plan paywalls dominate (41–60%), 3+ plans 6–27%, "Continue" is the commonest CTA.
- **Contributor findings used below:** Mojo — a paywall once per week on app open drove **15% of new revenue with no backlash; "the more generous your free tier, the more users tolerate the ask"**; Duolingo — **show a timeline of the trial; clarity beats persuasion**; App Masters — "reverse trial" after a dismissed paywall (reported 0.4%→4.5%, single-source anecdote); Yousician — check refunds/renewals before celebrating a conversion win.
- Apple's own guidance: metered paywalls and **contextual prompts "when they near their limit"**, offer a prompt "throughout the app interface", present benefits in onboarding, billed amount must be the most prominent price, and let people manage subscriptions in-app via `showManageSubscriptions` [S1].

---

## 3. First-run & activation

### 3.1 Current journey (code-verified) and friction

1. **Launch → OnboardingView** (2 pages, Skip) [CODE ContentView.swift:11-16; OnboardingView.swift]. Page 1 "Hear the music… Point your phone at any music — a piano, a street performer, your own playing". Page 2 "Watch the score write itself in real time…" (**inaccurate**, R1). No sample, no tips, no analytics event.
2. **Library:** Samples (2) + "No takes yet — tap the microphone and play something." Caption under the mic: "Tap to listen — AI Music Radar writes the score as you play." (**inaccurate**) [CODE LibraryView.swift:74, 89].
3. **Tap mic →** `ListeningSession.start()` calls `requestRecordPermission` immediately; the system prompt appears cold, over a "Warming up…" spinner [CODE ListeningView.swift:57-68, 281-283]. No primer. (HIG: ask when the feature is used, explain specifically — the tap *is* in-context, so the cold prompt is acceptable, but a one-line primer lifts grant rate [INFERENCE]. Secondary sources, [S11].)
4. **Listening:** "Play music near your phone — notes appear as they are heard." (accurate) + 4 pt level meter + piano roll + timer + Stop. In silence nothing happens for ~1.6 s windows [CODE ListeningView.swift:100,347-371]; no "move closer" hint.
5. **Stop → "Finishing the take…" → take screen opens on Piano roll**; sheet music requires tapping "Page" and waiting for "Analyzing tempo and key…" [CODE SheetDetailView.swift:50-77]. The marketing hero (engraved page) is one tap away, not the default — a deliberate choice documented in code ("no tempo/key guesses until asked") [CODE SheetDetailView.swift:10-13; test :20].
6. **Samples** open the same detail screen and play via SF2 — they need no mic, no network and no quota: **the best zero-friction demo already exists** but is just two quiet rows under "Samples".

### 3.2 Friction summary

| # | Friction | Evidence |
|---|---|---|
| F1 | Onboarding says "real time"; shows no result. Nothing leads to a sample | OnboardingView.swift:28 |
| F2 | Mic permission has no primer; denial → dead end without "Open Settings" | ListeningView.swift:62, 462-471 |
| F3 | First model load shows only "Warming up…" with no expectation | ListeningView.swift:281-283; ModelBox |
| F4 | Aha (engraved page) is behind a tab and a spinner | SheetDetailView.swift:50-77 |
| F5 | The 2nd primary button (video import) fails for any video > 60 s with a generic message | AudioCapture.swift:316-326; LibraryView.swift:263-275 |
| F6 | No in-flight feedback for imports (no `ProgressView`; grep found none in LibraryView) | LibraryView.swift `importAudio`/`importVideo` |

### 3.3 Recommendations

**A1 — Sample-first onboarding (R4a).** Replace the two pages with three, ending on an action (Apple: keep onboarding brief, focused, benefits first [S1]):
1. *"Hear any melody."* — "Play, sing or hum near your iPhone. Watch the notes appear as you go."
2. *"Get the page."* — "Stop, and your notes become sheet music you can play back, print or open in MuseScore."
3. *"Private by design."* — "Everything runs on your iPhone. No account, no upload, works offline. Anonymous usage stats are on by default; turn them off any time in Settings." Primary button **"Hear a sample"** (opens *Swedish Folk Tune* on the **Page** tab with playback armed); secondary **"Start listening"**; small "Skip".
This also gives the analytics disclosure line the earlier decision asked for (§7.2). `[Touches core: No]`

**A2 — Mic primer inside the listening screen (R4a).** Before the system dialog, show one sentence in the "Warming up…" slot: *"AI Music Radar listens through your microphone to write down the notes. Recordings stay on your iPhone."* + **Continue** (use "Continue", never "Enable microphone" — reviewers have rejected primer buttons that imply they flip the permission [S11, anecdotal]). Only on first request (`.undetermined`).

**A3 — Coach marks on the first take (R4a).** One-time: after the first successful take, a dismissible line over the Piano roll: *"Tap Page to see it as sheet music."* After first Page open: *"Tempo is an estimate — tap the ♩ mark to adjust."* Remember the last-used tab per install (keep default Piano roll; see Decision D14). `[Touches core: No]`

**A4 — Make the sample the aha (R4a).** The empty-library message gains a button **"Try a sample"** (opens sample on Page tab). `[No]`

---

## 4. Free→Pro funnel & paywall

### 4.1 Current funnel (as built)

`Settings → Go Pro` (always) · `ExportView` MIDI/MusicXML row tap → paywall (no soft step) · 4th take held → banner "Keep it" · imports hitting the limit → paywall via `canShowAuto(.saveLimit)` else an alert ("held for now") · `paywall_view` event only; no `source`, no dismiss, no plan-select [CODE ExportView.swift:131-139; ListeningView.swift:169-182, 539-565; LibraryView.swift:205-216; PaywallView.swift:84].

**Gaps vs the project's own design doc (`PAYWALL_FLOW.md`, status "design draft"):** soft interstitial (screen 1), trial timeline, trial-started screen with reminder (screen 4), import-limit (screen 7), save-limit sheet with *Replace an older take* (screen 6) — none exist in code. `PaywallTriggers` implements the caps but only one trigger calls it.

**Bug candidates for the auditor (not filed):** (a) audio **import bypasses the 3-take cap** — `importAudio` calls `library.addTake` directly instead of `saveImportedScore` [CODE LibraryView.swift:297-305 vs 205-216] — free users can exceed 3 saves, undermining Pro; (b) Settings **Restore** shows no result: `store.restore()` sets `purchaseError` but the alert lives only in `PaywallView`, so "No Pro purchase found" never appears when restoring from Settings [CODE SettingsView.swift:50-56; PaywallView.swift:89-96]; (c) pending Ask-to-Buy is surfaced as an error alert ("Purchase is pending approval.") [CODE ProStore.swift:126-129]; (d) purchase success dismisses silently (no "You're Pro" confirmation or resume of the blocked action beyond held takes).

### 4.2 Where upgrade prompts can appear more often, tastefully (**Stream D spec**)

Principle: ask **right after value is seen**, at a natural limit, in a form the user can ignore; never during recording/writing; never for Pro. Supported by [S1] (contextual prompts near limits; prompt "throughout the app interface"), [S4/Mojo] (weekly ask works when free tier is generous), and the repo's own `PAYWALL_FLOW.md` §2.

| ID | Surface | Trigger | Form | Auto? | Cap |
|---|---|---|---|---|---|
| U1 | Library header **meter** | ≥1 saved take, not Pro | Quiet row: "**2 of 3 pieces kept** · Keep unlimited" (tap → plans) | Persistent, non-modal | none (passive) |
| U2 | Library **inline card** | 3rd successful take saved (first time) | Dismissible card: "Three pieces kept. Pro keeps every one and exports MIDI & MusicXML." | Auto | once; may return once after 14 d; never after dismiss ×2 |
| U3 | Export sheet **soft interstitial** | First tap on a locked row (MIDI/MusicXML) | Half sheet showing the user's own first system of the score; "Try Pro free for 7 days" / "Share free PDF instead" | User-initiated (does not count against caps) | none |
| U4 | Export rows **contextual line** | Take longer than 30 s | PDF row subtitle "First 30 s of 52 s · full length with Pro" (replaces static "First 30 seconds") | Passive | none |
| U5 | **Held take** (4th) | Take finished, cap reached | Banner gains *Replace an older take* and a **"Leaving discards this take"** line; "Keep it" stays | Auto banner (exists) | n/a |
| U6 | Library **weekly soft card** | App open, free user, ≥3 takes recorded, ≥7 d since install | Same inline card as U2 (not a modal) | Auto | ≤1 per 7 d; stops after 3 dismisses |
| U7 | Post-trial-start | After trial start | "You're in" screen: what unlocked, trial end date, opt-in local reminder, resumes the blocked action | n/a | n/a |
| U8 | Settings "Go Pro" | User taps | Full paywall (not a prompt) | User | none |

**Global caps (reuse `PaywallTriggers`; already implemented, wire it):** max 1 automatic prompt per session, 2 per rolling 7 days, 72 h cooldown after a dismiss, stop all automatic prompts after 5 lifetime dismissals [CODE PaywallTriggers.swift:1-12, 34-52]. **Add:** U1/U4 are passive and exempt.

**Suppression (the gate must return `false` when any holds; add them inside `canShowAuto`):**
1. **Pro** in any form — `isPro` (active sub, trial, grace, or Lifetime). Today `canShowAuto` ignores Pro [CODE PaywallTriggers.swift:34] and Settings opens the paywall for Pro users.
2. **First session / before the first successful take** ("no value seen = no ask").
3. Recording / writing in progress (`ListeningSession.phase` ∈ `.listening,.writing,.preparing`).
4. **Purchase in flight or pending** (Ask to Buy) — and for the rest of that session after a purchase failure.
5. A system sheet/picker is up (mic prompt, Files, Photos).
6. Within 72 h of any paywall dismissal; after a successful Restore; within the first 24 h of install for card-type prompts (U2/U6).
7. Telemetry-off users get the same rules (caps are local, not analytics-driven).

**Not recommended:** modal-on-launch, countdown timers (≤1.4% of paywalls use them [S4]; also at odds with `PAYWALL_FLOW.md` §5), "are you sure?" guilt modals, fake scarcity, reverse trial for now (single-source anecdote [S4]; revisit after baseline).

### 4.3 Paywall redesign spec (App-Review-safe, all in `PaywallView`)

Keep: close button from first frame, yearly preselected, StoreKit-localised prices, full disclosure text, Restore + Terms + Privacy [CODE PaywallView.swift]. Change:

1. **Header by trigger** (`source` param): export → "Export MIDI & MusicXML"; save limit → "Keep every take"; settings → "AI Music Radar Pro". Sub-line is one sentence of *actual* gates.
2. **Truth sync (R2):** benefits list becomes *Unlimited saved pieces · MIDI & MusicXML export · Full-length PDF*. Delete "Full-length audio & video imports". Free-vs-Pro table: replace "Live transcription / Unlimited" with **"Recording — Unlimited (up to 60 s each)"**; delete the "Import length" row; keep "MP3 & photo — Included". (Re-add import only if/when D2 reverses.)
3. **Plan row hierarchy** is already correct (billed price headline, ≈/month in subtitle) — keep; keep the computed "Save 49%" (honest floor) and fix docs/screenshots that say 50% [CODE PaywallPricing.swift:95-107].
4. **Trial timeline** when the selected plan has an eligible trial: *Today — Pro unlocks · Day 5 — reminder (if you opt in) · Day 7 — $29.99/year starts unless you cancel* (Duolingo: clarity wins [S4]); mockup `docs/paywall/mockups/02-paywall.png` already designs this.
5. **CTA** stays "Try 7 days free, then $29.99/year" (dynamic) — [S1] requires trial length + price after trial next to the CTA.
6. **Post-purchase state** (U7) and **pending** shown as an informational sheet ("Waiting for approval — Pro unlocks automatically"), not an error alert.
7. **Pro users never see this view**: Settings row becomes a **Plan** screen: status ("Pro · renews Nov 17" / "Pro (trial) · ends Oct 24" / "Lifetime Pro"), **Manage subscription** (`showManageSubscriptions` / SwiftUI `manageSubscriptionsSheet`) [S1], **Restore Purchases** with visible result, Terms/Privacy.

### 4.4 Trial / pricing / Lifetime — decisions

- **Keep the 7-day trial on both subscriptions.** It is inside the 5–9-day band that converted best at the median (37.4% vs 25.5% for ≤4 d) [S4]; PAYWALL_FLOW's A/B ideas can follow data.
- **Keep $29.99/yr and $4.99/mo.** Matches the most common yearly price point and sits well below the cloud rivals ($44.99 Melody Scanner; $99.99 Piano2Notes) [S4][S6][S5].
- **Keep Lifetime $49.99, shown last, no countdown, no "launch price" timer.** One in four apps offer a lifetime [S4]; here marginal cost is ~0 (on-device), and Lifetime directly answers the "credits/subscription" complaints in the category. Risk: it can cannibalise yearly (lifetime-dominant apps show lower RPI [S4]) — so keep it visually quieter than Yearly and watch plan mix (§10).
- **Price experiments:** none until ≥ ~100 paywall views per arm are plausible; with a tiny base use **sequential before/after** with a stable control week; ASC Product Page Optimization only tests listing assets.
- **Offers to configure in ASC (owner action; I did not touch ASC):** a **win-back offer** and **offer codes** for creators/teachers (Apple supports both [S1]); MARKETING_PLAN already plans creator codes.

### 4.5 What Pro should include to justify "ongoing value" (honest)

Today Pro = capacity (saves) + export formats. That is a *capability* paywall, defensible for a v1 with a Lifetime alternative, but 3.1.2(a) wants ongoing value for subscriptions [S2]. Ordered by evidence:
1. Practice tools — **slow-down/tempo, loop, transpose, note names** (competitors lead with these: Reprise, Anytune [S13]); additive playback features → §11 (R15).
2. Note editing/correction (Piano Transcriptionist [S13]) → §11.
3. Longer imports (true "full-length") → needs chunked transcription = engine-adjacent → §11.
4. Free-PDF footer removal (R12) — tiny, honest Pro perk.
Do **not** advertise any of these until they ship (PAYWALL_FLOW §1 already says so).

---

## 5. Core experience polish (empty / error / permission states, capture coaching, library, playback, export)

### 5.1 State inventory (code-verified) and what to change

| State | Today | Recommendation | R |
|---|---|---|---|
| Mic permission **denied** | "Microphone access is denied. Enable it in Settings to listen." + only **Back to library** [CODE ListeningView.swift:62,468] | Same sentence + primary **Open Settings** (`UIApplication.openSettingsURLString`) + secondary "Back". Also show the same on the Library mic button's next tap | R4 |
| Mic permission **restricted** (parental) | Same as denied | Copy: "Microphone use is restricted on this iPhone." (no Settings button) | R4 |
| **Preparing** | "Warming up…" spinner [ListeningView.swift:282] | First model load: "Getting ready — the first time takes a few seconds." Track `model_ms` (§10) | R4 |
| **Listening** in silence | Nothing for ~1.6 s windows; 4 pt level bar [ListeningView.swift:100,355] | Live hint line from `session.level`: <~2 s of near-silence → "I can't hear anything yet — move closer to the music."; clipping → "Too loud — move back a little." Uses existing level value only | R4 |
| **Too quiet / silent / no notes** | One generic failed screen: text + Back [ListeningView.swift:123,128,168] | Failed screen gets **Try again** (calls `restart()`), a one-line cause, and 2 tips (below). Keep "Back to library" secondary | R4 |
| **Engine/model error** | "Could not start listening: \(error.localizedDescription)", "Transcription failed: …", "Could not write the page: …" [ListeningView.swift:92,109,157] | Never show raw Swift/Cocoa strings; map to "Something went wrong while listening. Try again." + `error` event (domain+code only). Matches the "no raw error strings" rule in the playbook | R4 |
| **Import >60 s** (audio or video) | Throws `durationLimitExceeded`; user sees "Could not read that audio file." / "…video's audio." [AudioCapture.swift:236-240,322-326; LibraryView.swift:275,305] | Show duration + choice: "That clip is 3:12. AI Music Radar reads up to 60 seconds at a time." **[Use first 60 s]** / Cancel. Loader reads the first N samples instead of throwing — a loader change, **not** a recognition change | R4 |
| **Import in progress** | No spinner (grep found no `ProgressView` in LibraryView) | Inline "Reading your file…" row at top of My Takes with Cancel | R4 |
| Empty library | "No takes yet — tap the microphone and play something." | Add **Try a sample** button | R4 |
| Held take (cap) | Banner "Not saved yet — Free keeps 3 pieces. You can still play and export it." [ListeningView.swift:549] — does not say **leaving discards it** (back button just dismisses; `pendingTake` is only saved on Pro) | Banner second line: "Leaving this screen discards it." + **Replace an older take** (pick one → delete → save) + keep "Keep it". Alert copy at LibraryView.swift:213 ("held for now") has the same gap | R3 |
| Photos "Save photo" denied | Good copy, no Settings link [SheetDetailView.swift:210,216] | Add Open Settings | R4 |

### 5.2 Capture coaching (the biggest accuracy lever, no engine change)

The engine is only as good as the input, and the comparable reviews say so [S5]. Rules from the app's own docs/description: "most accurate on a single instrument or voice in a quiet room" [CODE description.txt]. Surface that **before** and **during** the take, using existing signals (`session.level`, `Transcriber.peakLevel`, elapsed):

1. **Pre-record card** (shown on first 3 listens, then collapsible "Tips"): *Quiet room · one instrument or voice · phone about an arm's length from the sound · up to 60 seconds.* Reuse the exact failure copy so tips and errors agree.
2. **Live hint line** under the instruction text (see state table).
3. **Post-take quality chip** when `peak` is low: "Quiet recording — notes may be missing."
4. **Expectation line** on the take screen: "A first draft — best on one instrument or voice." (the description already says this; the app does not).

`[Touches core: No — Around]` Effort M for all four.

### 5.3 Library
- Takes are named "Take N" and cannot be renamed; deletion is swipe-only in the Library [CODE TakeLibrary.swift:96,166; LibraryView.swift:46]. Add **Rename** and **Delete** to the take screen (title tap / ⋯ menu). Recording experiments (people try 3–5 takes on day 0) otherwise burn the 3 free slots: add **Discard** right after a take.
- Show **"n of 3 kept"** (U1). Rows already show date · notes · duration — good.
- Shazam's lesson: a Library with history and search is the retention surface [S8] — later (search/sort), not now.

### 5.4 Playback & the take screen
- Playback is play/pause only (no scrub, tempo, loop). The tempo sheet changes *notation*, not playback speed. Competitors lead with practice tools [S13] → §11.
- Highlight on the page is a 45%-alpha yellow ellipse (computed contrast vs white ≈1.2:1) [CODE StaffPageView.swift:57-62]; piano-roll active note is red. Make the highlight stronger (outline + fill) for low-vision users (R8).
- The take screen's four glyph buttons (Play, Export, Record again, Save photo) have labels and hints but 28 pt glyphs without a 44 pt hit frame (R8).

### 5.5 Export
- Free: PDF (first 30 s), MP3, PNG. Pro: MIDI, MusicXML, full PDF [CODE ExportView.swift]. The footer "MIDI and MusicXML export require AI Music Radar Pro." is clear; locked rows carry a lock icon — good, and tapping goes straight to the paywall (add U3 soft step).
- **Remove the "Session recording / Debug export" section** (mic WAV + note-JSON that is also copied to the clipboard) and the toolbar "Export session audio and notes" button from the shipped UI (R6): they contradict the calm "private by design" story, expose clipboard writes without consent, and read as unfinished.
- Free-PDF footer line "Made with AI Music Radar" (R12): organic sharing loop; Pro removes it.
- Consider a share-sheet preview thumbnail with filename = take title (title is sanitised to `[a-zA-Z0-9-_ ]`, so non-Latin titles export as an empty base name [CODE ExportView.swift:109-111] — **bug candidate**).

### 5.6 Settings
- The Microphone section exposes about a dozen controls (gate threshold in dB, attack/hold/release ms, high-pass Hz, "Measure now") [CODE SettingsView.swift:98-133]. Great for tuning, daunting for a first-timer who opens Settings to find Restore. Move it under a collapsed **Advanced microphone** disclosure at the bottom (R6); keep the auto defaults.
- Order: **Plan** (status/Manage/Restore) → Privacy → About → Advanced.

---

## 6. Retention

Evidence is thin by design (no live data). What the comparables and Apple suggest, scoped to this app:

| Hook | What | Evidence | Fit |
|---|---|---|---|
| Trial reminder (local) | Opt-in notification on trial Day 5, requested *only* when the user starts a trial | Duolingo: trial timeline + reminder clarity lifts conversion [S4]; Apple: notifications must be opt-in and purposeful [S1] | R9 |
| Ratings prompt | `requestReview` after the 3rd successful take **and** ≥20 s on the take screen (or after playback ends), ≤once per app version; never in a session where a paywall showed | Apple: ask after a completed task, not on launch, system caps at 3/365 d [S10] | R11 |
| "Record again" loop | Already on the take screen; add "Record another" on empty-state completion | [CODE SheetDetailView.swift:99-107] | exists |
| Library as history | Rename/search/sort | Shazam Library is the product's memory [S8] | R11 / later |
| Share loop | Free-PDF footer; share sheet includes the PNG | — | R12 |
| Win-back | ASC win-back offer for lapsed subscribers | [S1] | R14 (owner) |
| Practice tools | Slow-down, loop, transpose | Reprise/Anytune [S13][S12] | R15 (parked) |

Do **not** add push marketing until there is something to say (Apple requires explicit marketing opt-in with consent language [S1]).

---

## 7. Trust (privacy story, analytics, expectations, subscription honesty)

### 7.1 Privacy story — strong, make it visible
Claims the code supports: transcription on-device; no account; mic audio never uploaded; telemetry allow-listed and opt-out-able; install UUID in Keychain; no third-party SDKs [CODE Telemetry.swift; InstallIdentity.swift; privacy.html]. Make it visible in onboarding page 3, the paywall ("Your music stays on your iPhone"), and screenshot 6. Comparable listings show the opposite pattern — Klangio apps list Purchases/Identifiers/Usage as "used to track you" and require accounts [S5][S6] — so on-device + no account is a credible wedge.

### 7.2 Analytics: anonymous, with toggle (decided; rules honoured)
Per the working rules: **no feature flags; analytics anonymous**. The app already has an opt-out ("Share anonymous usage data", default on) and a property allow-list [CODE SettingsView.swift:71; Telemetry.swift:62-64]. Decision D5: keep **default-on + Settings toggle + a one-line disclosure in onboarding**, no consent prompt; send nothing that is not in the allow-list; never send titles, file names, note content, free text, locale/time zone in events (the device record carries locale/time zone/model — see §7.3). If App Review pushes back, move to opt-in (reversible).
**App Privacy labels (ASC, owner action):** an install UUID and an `appAccountToken` that both reach the same server row, plus purchase records, are conservatively **Linked to the device/user** — I recommend declaring *Purchases*, *Identifiers (device-level install ID)* and *Usage/Product Interaction* as collected, **linked**, **not used for tracking** (decision D11; consistent with the playbook's "install UUID tied to purchase history is conservatively Linked"). The privacy page's phrasing "not linked to your identity" is still true (no name/email/Apple ID) — keep it, but make the ASC label and privacy page tell the same story.

### 7.3 Data minimisation to-do (R10)
1. **Notifications toggle** requests push permission and registers an APNs token although **no push is ever sent** (`docs/iap/IOS_INTEGRATION.md` §8: "No automated pushes exist yet"); permission without a use is a trust and 5.1.1 smell. Remove the toggle for 1.0; use a **local** trial reminder (R9) instead. Keep the server push infrastructure dormant.
2. **Device record/heartbeat** (`/api/devices/register` every foreground and 5 min) sends install ID, `appAccountToken`, OS/app/build, device model, **locale, time zone** [CODE ServerSync.swift:37-60,100-105; APIClient.swift:68] and ignores the analytics toggle. The app is offline-first and does not need it for any feature (purchase verification posts its own JWS). Recommend: **skip the heartbeat when "Share anonymous usage data" is off** and drop locale/time-zone from the payload unless needed for pricing support; update the policy sentence accordingly.
3. **Two privacy-policy sources disagree.** `docs/legal/music-radar/privacy.html` (canonical `music.grepawk.com`, operator "GrepAwk LLC", device-record + push-token paragraph) vs `web/privacy.html` (operator "grepawk / Yisheng Jiang", mentions the browser demo). ASC points at `grepawk.com/music-radar/privacy` [CODE docs/asc/APP_IDENTITY.md:15]. Confirm which is served at that URL, make operator name and host consistent, and re-check on the live URL before submission (R5/R10, owner). Also `docs/asc/metadata/en-US/support_url.txt` is `grepawk.com/music-hear/support.html` while APP_IDENTITY lists `…/music-radar/support` — make the metadata file match the identity doc.
4. When new events ship (R7) update the policy's event list (it enumerates events today).

### 7.4 Setting accuracy expectations (without touching the engine)
Add the "first draft" line (R11), surface "Tempo is estimated" (A3), keep the description's "TIPS FOR THE BEST RESULTS" and lift it to the first screenshot caption area. Competitors' worst reviews are accuracy disappointment [S6]; honest expectations convert disappointment into "it did what it said."

### 7.5 Subscription honesty checklist (as built vs needed)
| Item | Status |
|---|---|
| Price + period from StoreKit, billed amount most prominent | ✔ [CODE PaywallView.swift PlanRow; S1] |
| Trial length + price after trial next to CTA | ✔ `ctaTitle` |
| Auto-renew + cancel text, Terms, Privacy, Restore on paywall | ✔ |
| Restore in Settings **with visible result** | ✘ (bug candidate §4.1b) |
| Manage/cancel entry in app | ✘ (R2) |
| Visible close from first frame | ✔ |
| Copy matches gates | ✘ imports (R2) |
| Pro user never sees purchase UI | ✘ (R2) |
| Terms + Privacy in ASC description | ✔ [CODE description.txt] |

---

## 8. Accessibility

Evidence is code-only; on-device VoiceOver/Dynamic Type behaviour is `[INFERENCE]`. Apple's Accessibility Nutrition Labels are voluntary now but "over time, you'll be required to share accessibility support details"; labels appear on the product page and users can search by them; to claim a feature **all common tasks** (including first launch, purchase, settings) must work with it [S9].

| Area | Finding | Fix | R8 priority |
|---|---|---|---|
| **Score output is invisible to VoiceOver** | `StaffRenderView` and `PianoRollPageView` are UIKit canvases with no accessibility label/value (the live piano roll *does* have a label+count) [CODE StaffPageView.swift; ListeningView.swift:531-532] | `isAccessibilityElement`, label "Sheet music, 4/4, G major, 105 notes", value = measure/note position during playback; add `accessibilityCustomContent` summary; optional "Read notes" rotor later | P1 |
| Icon buttons | 28 pt glyph buttons without ≥44 pt frames (take screen, Library video button 56 pt OK) [CODE SheetDetailView.swift:91-113] | `.frame(minWidth: 44, minHeight: 44)` + `.contentShape` | P1 |
| Dynamic Type | Mostly semantic fonts ✔; onboarding title fixed 40 pt; take-row play glyph 38 pt; piano-roll "C4" labels 9 pt [CODE OnboardingView.swift:73; LibraryView.swift:320; ListeningView.swift:515] | Use `.largeTitle`/`@ScaledMetric`; test at AX3 | P2 |
| Colour only | Highlight is yellow-on-white (~1.2:1) and piano roll active = red vs blue | Add outline/weight change + pattern; verify contrast | P2 |
| Contrast (brand) | white on teal 6.3:1, teal on paper 5.9:1, ink on paper 16:1 (computed from `Ink`) ✔ | none | ok |
| Dark Interface | `preferredColorScheme(.light)` forced; custom canvases hard-code light colours [CODE ContentView.swift:19] | Keep light for 1.0 (D6); **do not claim** the Dark Interface label | parked R17 |
| Reduced motion | No custom animation beyond tab slide; no `accessibilityReduceMotion` use | Nothing to do now; if the live piano roll animates continuously add a static summary | later |
| Recording UX | Stop button has label+hint ✔; timer has a spoken label ✔ [CODE ListeningView.swift:374-375,394-395] | Add `UIAccessibility.post(.announcement)` at start/stop/finish | P2 |
| Captions | Explainer/preview videos (docs/explainer) — add captions before using in ASC | — | with R13 |

**Nutrition-label plan:** after P1 fixes, claim **VoiceOver** only if first launch → record → take → export → paywall → Settings are all completable (include Plan/Restore); claim **Larger Text** after the Dynamic Type pass; skip Dark Interface; evaluate Sufficient Contrast and Differentiate Without Color after the highlight change. Publish an accessibility URL later (ASC owner action).

---

## 9. Listing / ASO / screenshots

### 9.1 What Apple says drives search [S3]
Text relevance across **title, subtitle, keywords, primary category**, plus user behaviour (downloads, ratings, reviews). Keywords: 100 chars, comma-separated, **don't repeat words already in name, subtitle or category**, avoid plurals/filler/"app", no competitor names or unauthorised trademarks; **promotional text does not affect search ranking**. Subtitle: ≤30 chars, describe value/typical use, not generic claims; and 2.3.7 forbids subtitle claims that are unverifiable or reference other apps [S2]. App Store metadata can be localised by territory (en-GB/en-AU/en-CA carry separate keyword fields) [S3 synthesis; UNVERIFIED which English storefronts index which locale — check in ASC].

### 9.2 Competitive search snapshot (iTunes Search API, US, 2026-10-17) [S12]
- "audio to sheet music": Musician: Audio to Sheet Music · Piano2Notes · Piano Transcriptionist · Flat · Sing2Notes · Midi Sheet Music · Guitar2Tabs · Anytune · MuseScore · Musicnotes. Several top slots are low-rating-count apps → winnable.
- "transcribe music": Anytune · Reprise · Slow Down Music · Notation Pad · … Piano2Notes.
- "audio to midi": a long tail of 0–5-rating apps; Piano Transcriptionist #2.
- "AI Music Radar" returns **AI song generators** (Jukebox, Mureka, "AI Song") — the *brand name attracts the wrong intent* (generation vs transcription). [INFERENCE] Subtitle and screenshot 1 must say "transcribe/sheet music" unmistakably.

### 9.3 Name / subtitle / keywords / promo — proposals (lengths verified by `len()`)

Name: **keep "AI Music Radar"** (14 chars; locked in `APP_IDENTITY.md`). Using the unused 16 chars (e.g. "AI Music Radar: Sheet Music", per the marketing plan) is tempting and would raise relevance, but identity changes are the owner's call — see Open Decision O1 (default: keep).

| Field | Now | Proposed | Why |
|---|---|---|---|
| Subtitle (≤30) | "Live Audio to Sheet Music" (25) | **"Audio to Sheet Music, Offline"** (29) — alt "Hum, Play, Get Sheet Music" (26) | Drops the untrue "Live" (R1); "Offline" is verifiable and cloud rivals need internet [S5][S6]; keeps *audio / sheet / music* |
| Keywords (≤100) | `transcribe,transcription,piano,sheet,score,notes,melody,midi,musicxml,songwriter,offline,guitar,pdf` (99) — **"sheet" duplicates the subtitle** and wastes 6 chars | `transcribe,piano,score,notes,melody,midi,musicxml,hum,sing,voice,ear,songwriter,guitar,pdf,convert` (**98**) | Adds *hum/sing/voice/ear/convert* (input intents the app serves); removes duplicate "sheet"/"offline" (now in subtitle) and the near-duplicate "transcription" (Apple discourages variants) |
| Promo text (≤170, not indexed) | "It writes the score while you play. Real-time…" | "Play, sing or hum and watch the notes appear on a piano roll. Stop, and get engraved sheet music, MIDI and PDF. All on your iPhone: no account, works offline." (**158**) | Truthful; benefit-first; free to change anytime |
| Description opener | "Play it, see it. AI Music Radar listens as you play, sing, or hum — and writes the score live…" | "Play it, see it. AI Music Radar listens as you play, sing or hum. Notes appear on a live piano roll while you play, and the moment you stop you get an engraved page you can play back, print, or open in MuseScore." | R1 |
| "Tap the mic and notes appear while you play: an engraved staff page with tempo…" | untrue as worded | "Tap the mic and notes appear as you play. Stop, and see them engraved with tempo, time signature and key estimates." | R1 |
| FREE INCLUDES bullet | "Real-time transcription from the microphone" | "Record up to 60 seconds per take, with notes on a live piano roll" | R1/R2 |
| Import sentence | "Import an audio file or grab the sound straight from a video in your Photos" | add "(up to 60 seconds at a time)" | honesty, matches limit |
| Pro bullet | "Unlimited saved pieces · MIDI and MusicXML export · Full-length PDF" | unchanged ✔ — and keep "(7-day free trial)" wording eligible-only: "7-day free trial for eligible new subscribers" | 3.1.2 |

Apple 2.3.7: avoid price info in name/subtitle/screenshots ("free", "$") — current screenshot copy complies [S2].

### 9.4 Screenshots (5 iPhone 6.9" + 5 iPad 13" exist) — audit [CODE docs/asc/screenshots/en-US]
Looked at iPhone 01, 02, 03, 04, 05:
1. **01 "Hear it. Then read it."** shows the Library with *one* sample, Take 1–5, **no gear icon**, mic button without the caption — the build now has two samples, a gear, and a caption (stale).
2. **02/03/04** show the segmented control as **Page | Piano roll** with Page selected — the build defaults to **Piano roll first** and the order is Piano roll | Page [CODE SheetDetailView.swift:50-56] (stale; 2.3.3 wants the app in use — accuracy matters).
3. **05 "Export MIDI, MusicXML & PDF"** is a composited card with pills; no real export screen; MIDI/MusicXML are Pro but shown without a Pro marker (2.3.2: indicate what requires purchase [S2]).
4. **No screenshot shows the listening screen** (the "wow" and the privacy angle) or the Samples/offline angle; **no paywall/plan screenshot**.
5. Only the first three screenshots appear in search results [S3, per Apple search page cited in round one; **UNVERIFIED this round**] → the first three must carry the pitch.

**Proposed set (iPhone; mirror for iPad):**
1. *"Play, sing or hum. Watch the notes appear."* — real listening screen with a populated piano roll.
2. *"Stop — and it's sheet music."* — Page tab, key/tempo chip visible.
3. *"Every note lights up as it plays."* — playback highlight (keep 03, refresh chrome).
4. *"Private. On your iPhone. No account."* — Library with samples + airplane-mode glyph (no claim beyond what's true).
5. *"Export to MuseScore, Logic and more."* — real Export sheet with **Pro** pills on MIDI/MusicXML.
6. *"Start free. Go Pro when you're ready."* — Free vs Pro summary (no prices on image, per 2.3.7).
Regenerate from the real app (`ios-screenshots.yml` exists) rather than composites; keep captions truthful ("sheet music in seconds" is fine — 'seconds' is an [INFERENCE] about typical latency; verify on device before shipping).

### 9.5 Other listing items
- **App Preview (15–30 s)**: record the real screen: tap mic → piano roll fills → stop → Page → play. Captions for accessibility. (`docs/explainer` MP4s are marketing videos, not screen captures; 2.3.4 requires previews to be screen captures of the app [S2]).
- **Custom Product Pages** for teachers / songwriters / "hum to notes" once traffic exists (Apple supports; owner action in ASC).
- **Ratings:** R11 prompt; reply to every review in ASC [S10 ratings page].
- **Review notes** (`docs/asc/review_notes.txt`): (a) remove "full-length imports" (R2); (b) add "No microphone is needed to review: open *Samples* → Swedish Folk Tune to see the page and playback. To test recording, play any music near the phone for ~10 seconds"; (c) say mic is used only while recording and nothing is uploaded; (d) keep sandbox purchase + Restore steps; (e) move contact phone number out of repo docs.

---

## 10. Metrics: anonymous funnel events and properties

Rules: anonymous only; keys must be added to the allow-list in `Telemetry.swift` (the sanitiser drops anything else); no titles/file names/free text/locale; bucketed numbers where possible; policy event list updated with the release (§7.3). Existing events (not re-audited here): app open, record/take/export/paywall/purchase events [CODE Telemetry.swift]. **New / changed** (snake_case):

| Funnel | Event | Properties (enumerated, no free text) | Answers |
|---|---|---|---|
| Activation | `onboarding_step` | `step` (1-3), `action` (next/sample/listen/skip) | Where do first-timers drop? |
| | `mic_primer_shown`, `mic_permission_result` | `result` granted/denied | Permission loss |
| | `first_take_completed` | `ms_since_install` bucket, `source` mic/sample | Time-to-value |
| Core | `listen_started`, `listen_failed` | `reason` denied/silent/quiet/no_notes/engine/model, `elapsed_bucket` | Which failures dominate |
| | `listen_model_ready` | `model_ms` bucket | Cold-start cost |
| | `take_viewed_tab` | `tab` piano_roll/page, `first` bool | Do people find the page? (D14) |
| | `import_started/failed/truncated` | `kind` audio/video, `duration_bucket`, `reason` | Is 60 s limiting? (§11) |
| Funnel | `paywall_shown` | `trigger` (saveLimit/export_midi/export_xml/pdf_limit/meter/weekly/settings), `session_index` bucket, `entitlement` free | Which prompt works |
| | `paywall_dismissed` | `trigger`, `dwell_bucket` | Annoyance vs interest |
| | `paywall_plan_selected`, `purchase_started/result`, `restore_started/result` | `plan`, `result` success/pending/cancelled/failed/none | Plan mix, Restore health |
| | `soft_prompt_shown/tapped/dismissed` | `kind` (meter/third_take/pdf_limit/weekly) | Stream D prompts |
| | `manage_subscription_tapped`, `plan_screen_viewed` | `status` free/trial/pro/lifetime | Retention intent |
| Retention | `held_take_resolved` | `outcome` upgrade/replace/discard/abandoned | Data-loss rate |
| | `review_prompt_requested` | `takes_bucket` | Rating attempts |
| | `take_saved/deleted/renamed` | `library_size_bucket` | Library use |
| Trust | *(none)* | Opt-out must send nothing, including "opted out"; read opt-out indirectly from ASC analytics | Opt-out rate (indirect) |

Do **not** derive per-user histories beyond the install UUID; no IDFA. Derived funnels: install → onboarding_step 3 → mic_permission granted → first_take_completed → take_viewed_tab page → export → paywall_shown → purchase. Weekly reading: failures by `reason`, import `duration_bucket`, plan mix (yearly:monthly:lifetime), trial→paid via ASC (not in-app), D1/D7 retention via `app_open`.
Benchmarks to compare against once there is data: freemium download→paid D35 2.1% median [S4]; trial→paid 37.4% at 5–9 days [S4]. With only a handful of users, read these as sanity checks, not targets.

---

## 11. Parked additive ideas (not for this loop; no core change)

| Idea | Why parked | Evidence | R |
|---|---|---|---|
| Practice tools: playback speed, loop section, transpose, note names | Real differentiator for subscription "ongoing value"; needs playback-engine UI work | Reprise/Anytune [S13][S12] | R15 |
| Note editing / correction on the page | Large; touches model-output representation | Piano Transcriptionist [S13] | R15 |
| Imports >60 s (segment-by-segment) | Recognition/engine boundary; keep 60 s, ship "Use first 60 s" (R4) now | Klangio limits demos to 20 s; paid to 15 min [S7] | R16 |
| Dark Interface | Custom canvases hard-code light colours; cost > value pre-launch | §8 | R17 |
| Localization (es, de, fr, ja, pt-BR) | Cheap ASO win later; needs string catalog | [S3] | R18 |
| Library search/sort, iCloud sync, Shazam-style Control Center entry | Retention features; after real usage data | [S8] | later |
| Widgets / Live Activity for recording | Delight; later | — | later |

---

## 12. Prioritised backlog

Effort: S ≤ 0.5 d · M ≈ 1–3 d · L > 3 d. Impact: High/Med/Low = expected effect on review-pass risk, activation or revenue. **Touches core?** = changes the recognition/transcription pipeline (`HearSheet` package, Transcriber, quantizer, engraver, SF2Player); every row is **No** — items that wrap, label or surround it say "Around".

| R | Item | Type | Effort | Impact | Touches core? | Stream |
|---|---|---|---|---|---|---|
| R1 | Truthful "live" copy: subtitle, promo, description, onboarding, Library caption, a11y hint, paywall table, screenshots | Listing/copy + string edits | S | High | No | Fixer (strings) + owner (ASC) |
| R2 | Paywall integrity: copy=gates, Pro suppression/Plan screen/Manage, Restore feedback, pending/cancelled messaging, trigger-aware headline | Code | S–M | High | No | **D** (+ auditor bug candidates) |
| R3 | Upgrade-prompt stack with caps/suppression, held-take fixes, meter, soft export interstitial, contextual PDF line, weekly card | Code | M | High | No | **D** |
| R4 | First-run sample-first onboarding, mic primer, permission/error/empty states, live hints, pre-record tips, import "Use first 60 s" + progress, Try a sample | Code (UI) | M | High | Around | Fixer stream A/B (activation) |
| R5 | ASO + screenshots v2 + review notes + URL drift fixes | Listing/assets | S–M | High | No | Owner/listing |
| R6 | Remove Session-recording/debug export from shipped UI; collapse Advanced mic settings; Settings order | Code | S | Med | Around (UI only) | Fixer |
| R7 | Analytics events (§10) + policy event list | Code + doc | M | Med | No | Fixer |
| R8 | Accessibility P1/P2 (score labels, 44 pt targets, announcements, Dynamic Type, highlight contrast) + nutrition-label claims | Code + ASC | M | High (inclusion; label) | Around | Fixer |
| R9 | Trial timeline on paywall + opt-in local reminder + post-purchase success state | Code | S–M | Med | No | **D** |
| R10 | Privacy minimisation: remove push toggle for 1.0, gate heartbeat on analytics toggle, drop locale/time zone; ASC labels (Linked-conservative); policy alignment | Code + ASC + doc | S–M | Med | No | Fixer + owner |
| R11 | Ratings prompt (D12); "first draft" expectation line; take rename/delete/discard; "n of 3 kept" copy | Code | S–M | Med | No | Fixer (meter → D) |
| R12 | Free-PDF footer "Made with AI Music Radar" (Pro removes) | Code | S | Low–Med | No | Fixer — Open Decision O4 |
| R13 | Real-screen App Preview video (15–30 s) + captions | Asset | S–M | Med | No | Owner |
| R14 | ASC offers: win-back, creator/teacher offer codes; Custom Product Pages | ASC (owner) | S | Low–Med | No | Owner |
| R15 | Practice tools / note editing (Pro ongoing value) | Code | L | High (retention) | Around | Parked |
| R16 | Long imports (>60 s) + Pro-value roadmap note in review notes | Code/doc | L | Med | **Yes** (engine boundary) | Parked |
| R17 | Dark Interface | Code | M–L | Low | No | Parked |
| R18 | Localization | Listing + code | M | Med | No | Parked |

**Code enhancements suitable for later fixer streams:** R2, R3, R9 (Stream D) · R4, R6, R7, R8, R10, R11, R12 (other fixer streams; R4a onboarding and R4b error states can split). **Listing/copy changes** (no code or code only for strings): R1, R5, R13, R14 and the ASC parts of R10. **Parked:** R15–R18.

---

## 13. Sequencing

1. **Truth before polish (days 0–1):** R1 strings + listing copy, R2 copy/Plan-screen/Restore feedback. Zero engine risk; removes the highest review risk.
2. **Stream D (days 1–3):** R3 + R9 on top of R2 (single `PaywallGate`, shared caps in `PaywallTriggers`, Pro suppression). Ship without flags; constants live in one place.
3. **Activation (days 2–4, parallel):** R4 onboarding/error states, R6 debug removal, R11 rename/discard + review prompt.
4. **Instrumentation (with 2–3):** R7, so TestFlight 1 already measures the funnel.
5. **Listing (while code settles):** R5 screenshots regenerated from the *final* UI (screenshots last), R10 labels, R13 preview.
6. **TestFlight:** run the §14 on-device checks (VoiceOver pass, AX3, mic denied, airplane mode, import 90 s clip, 4th-take hold, trial purchase/restore in sandbox).

---

## 14. Open questions (defaults recorded in the tracker)

1. Keep "AI Music Radar" or add a descriptor (e.g. "AI Music Radar: Sheet Music") to the name? Default: keep.
2. Keep 60 s import hard cap for 1.0 and add "Use first 60 s"? Default: yes.
3. Lifetime placement (visible third row vs hidden until "More plans")? Default: visible, quiet.
4. Free-PDF footer? Default: yes, one line, Pro removes.
5. Price test post-launch? Default: none until volume.
6. Dark mode for 1.0? Default: no.
7. Subscription ongoing-value roadmap: practice tools first? Default: yes (R15), after launch.
8. ASC privacy labels: Linked (conservative) or Not Linked? Default: Linked-conservative.
9. Analytics default-on or opt-in? Default: default-on + toggle + disclosure.

---

## 15. Sources (all read on 2026-10-17 PT unless noted)

| S | Source | Used for | Note |
|---|---|---|---|
| S1 | Apple — Auto-renewable subscriptions: https://developer.apple.com/app-store/subscriptions/ ; HIG In-app purchase: https://developer.apple.com/design/human-interface-guidelines/in-app-purchase ; `showManageSubscriptions(in:)`: https://developer.apple.com/documentation/storekit/appstore/showmanagesubscriptions(in:) | Metered paywall, contextual prompts, billed amount prominence, Manage Subscriptions, win-back/offer codes | HIG page renders empty in the fetch tool; HIG text taken from search synthesis + earlier read of the subscriptions page — [UNVERIFIED primary] for HIG wording |
| S2 | Apple — App Review Guidelines: https://developer.apple.com/app-store/review/guidelines/ (saved copy `src/guidelines.txt`) | 2.3.1/2.3.2/2.3.3/2.3.4/2.3.7, 3.1.2, 5.1.1, 5.1.2 | read |
| S3 | Apple — App Store search: https://developer.apple.com/app-store/search/ ; Product page: https://developer.apple.com/app-store/product-page/ | Keyword/subtitle rules, what is indexed, promo not indexed | "first three screenshots shown in search" is [UNVERIFIED this round] |
| S4 | RevenueCat — State of Subscription Apps 2026: https://www.revenuecat.com/state-of-subscription-apps/ ; trial length: https://www.revenuecat.com/blog/growth/free-trial-length ; codelab: https://revenuecat.github.io/codelabs/monetization-success-formula/trial-length/ | Trial/price/conversion benchmarks (25.5/37.4/42.5%), freemium D35 2.1%, Lifetime share, reverse-trial anecdote | Medians across many apps, not music-specific; correlational (RevenueCat says so); Mojo/Duolingo/reverse-trial items are single-source anecdotes |
| S5 | Piano2Notes (App Store listing/reviews): https://apps.apple.com/us/app/piano2notes/id1589420929 | Pricing, token model, review complaints | listing text; reviews are individual anecdotes |
| S6 | Melody Scanner (App Store): https://apps.apple.com/us/app/melody-scanner/id6472921068 | $5.99/$44.99, account requirement, 1.7★ (35) | anecdotal reviews |
| S7 | Klangio help — Compare apps/plans: https://klang.io/help/compare-apps-and-subscriptions/ ; Demo vs Full: https://klang.io/help/difference-demo-full/ | 20-s free demos, no login, paid MIDI/MusicXML | competitor's own statement |
| S8 | Apple Support — Shazam offline: https://support.apple.com/guide/shazam/use-shazam-when-youre-offline-devad6c028a7/web ; Library/sync: https://support.apple.com/guide/shazam/sync-your-identified-songs-to-the-shazam-app-deva59a13320/web | Offline identify then sync, Library history | read |
| S9 | Apple — Overview of Accessibility Nutrition Labels: https://developer.apple.com/help/app-store-connect/manage-app-accessibility/overview-of-accessibility-nutrition-labels/ | Label scope, "all common tasks" rule | read |
| S10 | Apple — Requesting App Store reviews: https://developer.apple.com/documentation/StoreKit/requesting-app-store-reviews ; Ratings & reviews: https://developer.apple.com/app-store/ratings-and-reviews/ | Prompt timing, 3/365 d cap | HIG ratings via mirror appguidelines.com — [UNVERIFIED primary] |
| S11 | HIG mirrors (appguidelines.com) for onboarding/permission requests | "Ask when feature is used; explain why" | secondary mirror — [UNVERIFIED primary] |
| S12 | iTunes Search/Lookup API (US storefront), queried 2026-10-17: `https://itunes.apple.com/search?term=…&entity=software&country=us` and `lookup?bundleId=com.ragnus.pnge` | Rankings, ratings counts, "not on App Store" | public API; counts change daily |
| S13 | Store listings: Reprise https://apps.apple.com/us/app/reprise-transcribe-music/id6779112344 · Anytune https://apps.apple.com/us/app/anytune-transcribe-practice/id415365180 · Piano Transcriptionist https://apps.apple.com/us/app/piano-transcriptionist/id6456886504 | Feature positioning, ratings | listing copy only; pricing not read |

Not researched / not verifiable here: real conversion data for this app (none exists), on-device behaviour (no simulator run this round), competitor paywall screens.
