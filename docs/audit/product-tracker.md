# AI Music Radar — Product tracker (round two)

Companion to `product-review.md` (same folder). Review SHA `0dba134`, date Sat 2026-10-17 (PT). Internal tracking only — **no GitHub issues filed from this file**; the separate auditor files bug issues. Rules honoured: no feature flags; analytics anonymous; ASC and secrets untouched; repo read-only.
Evidence legend as in the review: `[CODE path]`, `[S#]`, `[INFERENCE]`, `[UNVERIFIED]`.

Effort: S ≤ 0.5 d · M ≈ 1–3 d · L > 3 d. Impact: expected effect on review-pass risk, activation or revenue. Status values: `proposed` (default), `ready` (spec complete in the review), `parked`, `owner` (needs Yisheng/ASC).

## 1. Recommendations

| R | Recommendation | Effort | Impact | Touches core? | Type | Stream | Status | Review § |
|---|---|---|---|---|---|---|---|---|
| R1 | Truthful "live" copy everywhere: subtitle → "Audio to Sheet Music, Offline"; promo, description, onboarding, Library caption, a11y hint, paywall table, screenshots | S | High | No | Listing/copy (+ string edits in code) | Fixer (strings) + owner (ASC) | ready | 1.2, 9.3 |
| R2 | Paywall integrity: remove "full-length imports"/"Live transcription" claims, Pro users see Plan screen (status, Manage Subscription, Restore with result) not the purchase paywall, pending/cancelled messaging, trigger-aware headline | S–M | High | No | Code | **Stream D** | ready | 4 |
| R3 | Upgrade-prompt stack: one `PaywallGate`; "n of 3 kept" meter; soft export interstitial with the user's own score; one-time 3rd-take card; contextual "PDF shows first 30 of N s"; weekly soft card; held-take fixes (warn on leave, replace older take); caps + Pro/first-session/in-flight suppression | M | High | No | Code | **Stream D** | ready | 4.2–4.3 |
| R4 | Activation & states: sample-first onboarding with mic primer; Open Settings/Try again on every failure; friendly error strings; live level hint; pre-record tips; import >60 s → "Use first 60 s"; import progress; "Try a sample" in empty Library | M | High | Around (UI only) | Code | Fixer (activation) | ready | 3, 5 |
| R5 | Store presence: subtitle/keywords/promo; screenshots v2 from real UI (add listening screen, Pro markers); review notes (Samples path, no-mic review, truthful Pro); URL/policy drift fixes | S–M | High | No | Listing/assets | Owner/listing | owner | 9 |
| R6 | Remove Session-recording/debug export from shipped UI (Export sheet + Listening toolbar); collapse Advanced microphone settings; Settings order Plan→Privacy→About→Advanced | S | Med | Around (UI only) | Code | Fixer | ready | 5.5–5.6 |
| R7 | Analytics: new funnel events (§10) with allow-listed keys; policy event list updated | M | Med | No | Code + doc | Fixer | ready | 10 |
| R8 | Accessibility: label the score canvases, 44 pt targets, VoiceOver announcements, Dynamic Type fixes, stronger highlight; Nutrition Label claims after verification | M | High | Around | Code + ASC | Fixer | ready | 8 |
| R9 | Paywall trial timeline + opt-in local trial reminder + post-purchase success state | S–M | Med | No | Code | **Stream D** | ready | 4.3, 6 |
| R10 | Privacy minimisation: drop Notifications toggle for 1.0; heartbeat respects analytics toggle; drop locale/time zone; ASC labels Linked-conservative; align the two policy sources | S–M | Med | No | Code + ASC + doc | Fixer + owner | ready | 7 |
| R11 | Review prompt (D12); "first draft" expectation line; take rename/delete/discard; library meter copy | S–M | Med | No | Code | Fixer (meter in D) | ready | 5.3, 6, 7.4 |
| R12 | Free-PDF footer "Made with AI Music Radar" (Pro removes) | S | Low–Med | No | Code | Fixer | owner (O4) | 5.5 |
| R13 | Real-screen App Preview (15–30 s) with captions | S–M | Med | No | Asset | Owner | owner | 9.5 |
| R14 | ASC offers: win-back, creator/teacher offer codes; Custom Product Pages | S | Low–Med | No | ASC | Owner | owner | 4.4, 9.5 |
| R15 | Practice tools (speed, loop, transpose, note names) and note editing — subscription ongoing value | L | High (retention) | Around | Code | — | parked | 4.5, 11 |
| R16 | Imports >60 s; Pro-value roadmap sentence in review notes | L | Med | **Yes** (engine boundary) | Code/doc | — | parked | 11 |
| R17 | Dark Interface | M–L | Low | No | Code | — | parked | 8 |
| R18 | Localization (es, de, fr, ja, pt-BR; en-GB/AU/CA keyword sets) | M | Med | No | Listing + code | — | parked | 9, 11 |

**Code enhancements for later fixer streams:** Stream D → R2, R3, R9 (upgrade-prompt work). Other streams → R4, R6, R7, R8, R10, R11, R12.
**Listing/copy changes:** R1, R5, R13, R14 and the ASC parts of R10 (labels), R8 (nutrition labels).
**Parked:** R15–R18.

## 2. Bug candidates for the auditor (not filed by me)

| # | Candidate | Evidence | Severity guess |
|---|---|---|---|
| B1 | Importing audio/video bypasses the 3-take free cap (saves unconditionally, then only alerts) | [CODE LibraryView.swift:205-216] | Medium (revenue + inconsistency) |
| B2 | Settings → Restore Purchases gives no visible success/failure feedback | [CODE SettingsView.swift:50-56] | Medium (review risk 3.1.1 "restore works") |
| B3 | Held 4th take is discarded when the user leaves the screen; banner does not say so | [CODE ListeningView.swift:455,549; LibraryView.swift:213] | Medium |
| B4 | Pro user can open the purchase paywall from Settings | [CODE SettingsView.swift:33-52] | Medium |
| B5 | Importing a clip >60 s shows generic "Could not read that audio/video" | [CODE AudioCapture.swift:236-240,322-326; LibraryView.swift:275,305] | Medium |
| B6 | Export file names strip non-ASCII, so non-Latin titles can produce an empty base name | [CODE ExportView.swift:110] | Low |
| B7 | Debug "Session recording" export writes mic audio + notes and copies to clipboard in the shipped UI | [CODE ExportView.swift:39-54; ListeningView.swift:408-437] | Low–Medium (trust) |

## 3. Launch risks

| # | Risk | Guideline / area | Likelihood | Impact | Mitigation (R) |
|---|---|---|---|---|---|
| L1 | "Live/real-time" marketing vs piano-roll-then-page behaviour | 2.3.1, 2.3.7 | High | High | R1 |
| L2 | Pro benefit "full-length imports" does not exist in code; free import cap not enforced either | 3.1.2, 2.3.1 | High | High | R2 |
| L3 | Reviewer in a quiet room records and gets "Too quiet" → looks broken | 2.1 | Medium | High | R4, R5 (review notes: use Samples; play music near phone) |
| L4 | Pro user shown purchase UI; Restore with no feedback | 3.1.1, 3.1.2 | Medium | Medium | R2 |
| L5 | Screenshots stale (tab order, Library chrome), no Pro marker on export shot | 2.3.2, 2.3.3 | Medium | Medium | R5 |
| L6 | Notifications toggle requests push permission though no push exists; heartbeat ignores analytics toggle | 5.1.1, 5.1.2 | Low–Med | Medium | R10 |
| L7 | App Privacy labels inconsistent with install UUID + appAccountToken linkage | 5.1.2 | Medium | Medium | R10 (Linked-conservative) |
| L8 | Two privacy-policy sources with different operator/host; support URL mismatch | 5.1.1 | Medium | Medium | R5/R10 (verify live URLs) |
| L9 | Subscription lacks ongoing value beyond capacity/exports on a v1 | 3.1.2(a) | Low–Med | Medium | Lifetime option (D3), R15 roadmap |
| L10 | Data loss of held take → 1★ review | UX | Medium | Medium | R3 |
| L11 | Brand name attracts AI-song-generation intent in search | ASO | High | Medium | R5 (subtitle/screens say transcription); O1 |
| L12 | No on-device runtime verification this round (static review only) | Process | — | — | TestFlight checklist in review §13 step 6 |
| L13 | Personal phone number in public repo docs (review notes) | Privacy | Low | Low | Keep contact in ASC only (R5) |

## 4. Open decisions for Yisheng (each with the default I will assume)

| # | Question | Default (applies unless you say otherwise) | Rationale |
|---|---|---|---|
| O1 | Keep the name "AI Music Radar" or add a descriptor (e.g. "AI Music Radar: Sheet Music")? | **Keep**; subtitle carries the keywords | Identity is locked in `APP_IDENTITY.md`; adding 16 chars helps ASO, but renaming has brand/ASC cost |
| O2 | Keep the 60 s hard import limit for 1.0? | **Keep**; add "Use first 60 s" | Engine boundary; handling is UI only |
| O3 | Lifetime placement | **Visible, last, quiet** | Answers subscription fatigue; avoid cannibalising yearly |
| O4 | Free-PDF footer "Made with AI Music Radar" | **Yes**, one small line; Pro removes | Organic loop; low annoyance |
| O5 | Run price/trial experiments post-launch | **No** until volume | Tiny sample; PPO tests listing only |
| O6 | Dark Interface in 1.0 | **No** (light-only, no Dark label) | Custom canvases hard-code light |
| O7 | Pro ongoing-value roadmap | **Practice tools first** (R15) post-launch | Competitors lead with them [S13] |
| O8 | ASC privacy labels | **Linked-conservative** (Purchases, Identifiers, Usage; not tracking) | Install UUID + appAccountToken reach the same row |
| O9 | Analytics default | **On + Settings toggle + onboarding disclosure**; opt-out sends nothing | Already built; anonymous; reversible |

## 5. Decisions made (2026-10-17, reversible)

| # | Decision | Rationale | How to reverse |
|---|---|---|---|
| D1 | Truth-first: copy says "live piano roll while you play; sheet music when you stop" | Unique vs cloud apps and defensible under 2.3.1; the marketing plan already admits the gap | Edit strings |
| D2 | Keep the 7-day trial on both subscriptions and $29.99/yr, $4.99/mo | 5–9-day trials convert best at median (37.4% vs 25.5%) [S4]; yearly sits far below cloud rivals [S5][S6]; no data to justify changes | Change in ASC |
| D3 | Keep Lifetime $49.99 as quiet third option, no countdowns | Cheap to serve (on-device); answers credit/subscription complaints; avoid dark patterns | Hide row in `PaywallView` |
| D4 | Prompt caps: reuse `PaywallTriggers` (1/session, 2/7 d, 72 h cooldown, stop after 5 dismissals); every prompt is dismissible and never during recording; Pro never sees any | Tasteful, evidence-aligned (contextual near limits) [S1]; avoids multiplying new constants | Constants in one place |
| D5 | Analytics stays default-on with Settings toggle and onboarding disclosure; opt-out sends nothing | Anonymous, allow-listed; rule says toggle, no flags | Make opt-in |
| D6 | Keep light-only Interface for 1.0; don't claim Dark Interface label | Canvases hard-code light colours | R17 later |
| D7 | No price experiments until volume; use sequential before/after if any | Sample size | — |
| D8 | Remove the debug session-export UI from the shipped build | Trust story + review optics; engineering can retain code behind `#if DEBUG` (compile-time, not a feature flag) | Re-add UI |
| D9 | Drop the Notifications toggle for 1.0; use a local, opt-in trial reminder | No push exists; avoids needless permission; trial reminders aid trust | Re-add when pushes exist |
| D10 | No ASC offers/labels/listing changes made by me; all are recommendations for the owner | Instruction: never touch ASC | — |
| D11 | App Privacy labels recommended as Linked-conservative | Playbook rule + install ID/appAccountToken linkage | Change label |
| D12 | Review prompt only after 3rd successful take and ≥20 s on the take screen (or playback ended), once per app version, never in a session with a paywall, never on error | Apple guidance [S10] | Tune thresholds |
| D13 | Import >60 s: offer "Use first 60 s" rather than refuse | Better than a dead end; zero engine change (loader reads fewer samples) | Revert to refusal with explicit copy |
| D14 | Keep Piano-roll as default tab after a take; add coach marks and remember last tab | Existing test and documented decision ("no tempo/key guesses until asked"); coach marks fix discoverability | Flip default |
| D15 | No feature flags: every change ships on; tunable constants live in one place; `#if DEBUG` only for debug tools | Working rule | — |

## 6. Sequencing and verification

1. R1 strings + R2 copy/Plan screen/Restore feedback.
2. Stream D: R3, R9 (on top of R2).
3. R4, R6, R11 in parallel; R7 alongside.
4. Screenshots last (R5) from the final UI; R10 labels; R13 preview.
5. TestFlight checks that this review could not run: VoiceOver across first-run→record→take→export→paywall→Settings; AX3 Dynamic Type; mic denied; airplane mode; 90 s import; 4th-take hold; sandbox trial/restore/Manage Subscriptions.

## 7. Not verified this round

- No device/simulator run; all behaviour from code reading and screenshots.
- No real funnel data (app not on the App Store: iTunes lookup for `com.ragnus.pnge` returned 0 results on 2026-10-17).
- HIG pages not readable by the fetch tool; HIG wording relies on search syntheses/mirrors ([UNVERIFIED primary], S1/S10/S11).
- RevenueCat benchmarks are cross-category medians and partly anecdotal.
