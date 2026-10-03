# Free → Pro paywall: user flow and interstitial design

Status: **design draft**. Pricing and product IDs are **proposed** and still need owner sign-off (see [`docs/marketing/MARKETING_PLAN.md` §5](../marketing/MARKETING_PLAN.md)). Nothing here is implemented yet, and no in-app purchase products exist in App Store Connect.

Mockups live in [`mockups/`](mockups/): 1320×2868 PNGs (iPhone 6.9", 440×956 pt @3x). The HTML/CSS source is in [`mockups/src/`](mockups/src/), and [`mockups/render.sh`](mockups/render.sh) re-renders them with headless Chrome. The visual language is the app's own: `Ink.paper` background, `Ink.ink` text, `Ink.teal` actions (from `Sources/App/ListeningView.swift`), serif headlines like the onboarding and Sheets mockups in [`docs/ui-mockups/`](../ui-mockups/), and the sheet-detail layout from `SheetDetailView.swift` (title, BPM/meter/key caption, Page/Piano roll picker, play, share).

| # | Mockup | Screen |
|---|---|---|
| 1 | [`01-soft-interstitial.png`](mockups/01-soft-interstitial.png) | Contextual soft interstitial over the sheet detail, showing the user's own score with export locked |
| 2 | [`02-paywall.png`](mockups/02-paywall.png) | Full paywall, top: plan picker (yearly preselected), trial timeline, sticky CTA and legal links |
| 3 | [`03-paywall-benefits.png`](mockups/03-paywall-benefits.png) | Full paywall, scrolled: benefits per audience, Free vs Pro table, on-device privacy, auto-renew disclosure |
| 4 | [`04-trial-started.png`](mockups/04-trial-started.png) | Trial started: what's unlocked, trial end date, opt-in reminder, resume the original action |
| 5 | [`05-dismiss-free-pdf.png`](mockups/05-dismiss-free-pdf.png) | Dismiss path: the share sheet with the free exports working and Pro exports marked |
| 6 | [`06-save-limit.png`](mockups/06-save-limit.png) | 4th save: keep it with Pro, replace an older take, or not now |
| 7 | [`07-import-limit.png`](mockups/07-import-limit.png) | Import over 30 s: write the first 30 s free, or the whole file with Pro |

---

## 1. Offer (proposed, pending sign-off)

| | Free | Pro |
|---|---|---|
| Record and see the score (Page and Piano roll), playback | Unlimited | Unlimited |
| Saved pieces | 3 | Unlimited |
| Imported audio | First 30 s is transcribed | Full length |
| PDF export | First 30 s | Full length |
| MIDI and MusicXML export | – | ✓ |
| MP3 of the take, photo of the page | ✓ (proposed: it's the user's own audio, and a photo is already a free feature) | ✓ |

Prices (proposed): **Pro Monthly $4.99/month**, **Pro Yearly $29.99/year** (≈ $2.50/month, 50% less than 12 × monthly), both with a **7-day free trial** for new subscribers; **Lifetime $49.99** one-time, **$39.99 launch price** for the first 30 days after launch (a real date, set when the launch date is fixed).

The marketing plan also lists key/meter/tempo edits and slow playback for Pro. The paywall must not mention them until they ship.

StoreKit product IDs: **all TBD**, none exist in ASC yet. Placeholders:

| Product | Type | Placeholder ID |
|---|---|---|
| Pro Monthly | Auto-renewable, group "Pro" | `com.ragnus.pnge.pro.monthly` (TBD) |
| Pro Yearly | Auto-renewable, group "Pro" | `com.ragnus.pnge.pro.yearly` (TBD) |
| Lifetime | Non-consumable | `com.ragnus.pnge.pro.lifetime` (TBD) |

Bundle id is `com.ragnus.pnge` (see `docs/asc/APP_IDENTITY.md`). The 7-day trial is an introductory offer configured on the two subscriptions in ASC. Entitlement = active Pro subscription **or** owned Lifetime.

---

## 2. Trigger moments (ranked)

The rule: ask right after the user has *seen* value and is reaching for something Pro does. The paywall never blocks something they already had for free.

| Rank | Trigger | When | Shows | Why |
|---|---|---|---|---|
| **1 (prime)** | **Export tap after a good transcription** | User taps Share on a take, then a locked row (MIDI, MusicXML or full PDF). Also when the first Share of the first finished take happens: the soft interstitial appears before the share sheet. | Soft interstitial (screen 1) → full paywall (2/3) | The value moment: they have their own score on screen and want it in their DAW or notation app. Highest intent. |
| 2 | **Import over 30 s** | After choosing a file in Import audio, before transcription starts, if the file is longer than 30 s | Import sheet (screen 7) | They chose a whole song; the limit is concrete and the free option is still useful. |
| 3 | **4th save** | When a 4th take would be saved (recording stop → "Writing the page…" finishes → "The page is ready.") | Save-limit sheet (screen 6), shown *after* the page is written and viewable, never before | Their library is the thing they're building. They lose nothing: the take stays open. |
| 4 | **Soft ask after the 3rd successful transcription** | After the 3rd take is written and the user returns to the library | A dismissible inline card at the top of the library ("Three pieces written. Pro keeps every one and exports MIDI & MusicXML. Try 7 days free."), not a modal | Habit forming; low pressure. Opens the full paywall only if tapped. |
| – | Settings / library "Go Pro" row | Any time, user-initiated | Full paywall | Always available, never counted against caps. |

### Never show the paywall

- During recording, while the mic is listening, or while "Writing the page…" is in progress. If a trigger fires then, it is queued and dropped if the user starts another take.
- On first launch, during onboarding, or before the first transcription has finished. No value seen = no ask.
- During playback start (tapping play), on Back, or when opening a take from the library.
- Over a system prompt (mic permission, Files picker) or in the same session after a purchase failure.

### Frequency caps

Automatic triggers (ranks 1 to 4, when not caused by a tap on a locked item):

- Max **1 automatic paywall/interstitial per session** and **2 per rolling 7 days**.
- After a dismiss, a **72 h cooldown** on automatic triggers.
- Rank 4 (3rd-transcription card) shows **once**; if dismissed it can return once after 14 days, then never.
- After **5 lifetime dismissals**, stop all automatic prompts. Only user-initiated taps (locked rows, "Go Pro") open the paywall from then on.
- Taps on a locked item always open the soft interstitial or paywall (the user asked) and do not count toward caps. A **"See plans" tap from the interstitial** opens the full paywall without counting a second view.
- Pro or Lifetime users never see any of this; lapsed subscribers see the same flow with "Resubscribe" copy and no trial (StoreKit reports eligibility).

---

## 3. Screens

### (a) Soft interstitial: "Export this as MIDI & MusicXML" ([01](mockups/01-soft-interstitial.png))

A half-height sheet over the sheet detail of *their* take (title "Take 3", "96 BPM · 4/4 · D major · 24 notes", the Page view). Contents:

- Eyebrow "Your score is ready", then a card with the **user's own first system engraved**, the second system faded, and MIDI / MusicXML / Full PDF lock pills. Render it from the take's `QuantizedScore` with `StaffPageView`, not a stock image.
- Headline **Export this as MIDI & MusicXML**. Body: "Open Take 3 in GarageBand, Logic, MuseScore or Sibelius, every note, full length. Pro includes it, and the first 7 days are free."
- Primary **Try Pro free for 7 days** → full paywall (no purchase happens on this sheet, so it carries no price disclosure; it says "Next you choose a plan. Nothing is charged today.").
- Secondary **Share free PDF (first 30 s)** → the share sheet with the free exports (screen 5).
- Close (×) top right, visible immediately, plus swipe-down. Both = dismiss.

### (b) Full paywall ([02](mockups/02-paywall.png), [03](mockups/03-paywall-benefits.png))

One scrolling page with a sticky footer.

- **Close (×) top left, visible and tappable from the first frame.** No delayed or faded-in close button.
- Header "AI Music Radar Pro", **Every note, in every format.**, "Unlimited saves, full-length imports, and MIDI, MusicXML & full PDF export."
- **Plan picker**, yearly preselected:
  - Yearly: **$29.99/year** as the most prominent price, "≈ $2.50/month" smaller, badge "Save 50%" (vs 12 × $4.99), "7 days free, cancel anytime".
  - Monthly: **$4.99/month**, "billed monthly", "7 days free, cancel anytime".
  - Lifetime: **$39.99 once**, "launch price, then $49.99", "One payment, no renewal". After the launch window the row shows $49.99 only; no countdown timers.
  - All prices come from `Product.displayPrice` (localized), never hard-coded.
- **Trial timeline** (only when the selected plan has an eligible trial): **Today** every Pro export and unlimited saves unlock · **Day 5** we remind you the trial is ending · **Day 7** $29.99/year starts unless you cancel before. The Day 7 price follows the selected plan.
- **Benefits tied to jobs**: Students ("Write down the piece you're learning by ear, then open the MusicXML in MuseScore to check it."), Teachers ("Play a phrase once and hand out a full-page PDF. Keep a library of every exercise."), Songwriters ("Hum the idea before it's gone, then drop the MIDI into GarageBand or Logic.").
- **Free vs Pro table** (§1), so it is clear that recording and on-screen scores stay free.
- **Privacy reassurance**: "Your music stays on your iPhone. Transcription runs on the device. No account, no upload, and it works offline."
- **Auto-renew disclosure** (full text, above the footer): "Payment is charged to your Apple ID when you confirm (for trials, when the trial ends). Subscriptions renew automatically at the same price and period unless canceled at least 24 hours before the end of the current period. Manage or cancel in Settings › Apple ID › Subscriptions. Lifetime is a one-time purchase."
- **Sticky footer**: CTA **Start 7-day free trial** (Monthly: same; Lifetime: "Buy Lifetime for $39.99"; not trial-eligible: "Subscribe for $29.99/year"). Under it: "Free for 7 days, then $29.99/year (≈ $2.50/month). Renews automatically. Cancel anytime in Settings." Then **Restore Purchases · Terms · Privacy**.

### (c) Trial started ([04](mockups/04-trial-started.png))

Shown after a verified transaction. "You're in. Pro is on." The trial end date comes from the transaction/renewal info (e.g. trial started Oct 3 → ends Oct 10, reminder Oct 8). A list of what's unlocked. Primary **Export Take 3 now** resumes the exact action that triggered the paywall (share sheet with MIDI/MusicXML unlocked, the 4th save, or full-length import). Secondary **Turn on trial reminder** asks for notification permission *only now* and schedules a local notification for Day 5. Footnote: "Cancel anytime in Settings › Apple ID › Subscriptions." Lifetime purchase shows the same screen without trial lines.

### (d) Dismiss path: never a dead end ([05](mockups/05-dismiss-free-pdf.png), [06](mockups/06-save-limit.png), [07](mockups/07-import-limit.png))

- From the export interstitial/paywall: × or "Share free PDF (first 30 s)" returns to the share sheet. Free rows work: **PDF, first 30 s**, **Photo of the page**, **MP3 of the take**. Pro rows (MIDI, MusicXML, Full-length PDF) carry a "Pro" lock pill and open the paywall on tap.
- 4th save: **Try Pro free for 7 days**, **Replace an older take** (pick one to delete, with confirmation), or **Not now**: the take stays open for this session, can be played and its free PDF shared, and is not saved after they leave (tell them in one line, as the mockup does).
- Import over 30 s: **Write the first 30 s free** transcribes the first 30 s as a normal take, or **Try Pro free for 7 days**.
- After any dismiss the user lands exactly where they were, with the score still on screen.

---

## 4. Apple guideline compliance (3.1.1, 3.1.2, 5.6)

- [x] Price **and** period on every plan, from StoreKit `displayPrice`. The **billed amount ($29.99/year) is the most prominent price**; the per-month equivalent is secondary and smaller (App Review rejects paywalls where "$2.50/mo" outshines the real charge).
- [x] Trial length and what happens after it ("Free for 7 days, then $29.99/year") next to the CTA.
- [x] **Restore Purchases** button on the paywall (calls `AppStore.sync()`), also in Settings.
- [x] **Terms of Use**: https://grepawk.com/music-hear/terms.html · **Privacy Policy**: https://grepawk.com/music-hear/privacy.html (both online; same URLs as `docs/asc/metadata`). Also add the Terms URL to the App Store description or ASC EULA field, which 3.1.2 requires for subscriptions. Note: `docs/asc/APP_IDENTITY.md` lists `grepawk.com/music-radar/...`. Both paths respond today; pick one canonical set before submission.
- [x] Auto-renew disclosure text (§3b).
- [x] Visible close button from the first frame, no fake delays, no "are you sure?" guilt modals, no auto-dismissed timers.
- [x] Free features stay free; the paywall never removes something the user already had (recording and on-screen scores are always free).
- [x] Uses StoreKit in-app purchase only; no external payment links.

## 5. Copy rules

- No "live" or "real-time" claims: the iOS app writes the score **after** recording stops ("Writing the page…"). Use "record, then read", "in seconds", "writes the page". (Note: `LibraryView.swift` still says "writes the score as you play" and `ListeningView.swift` says "notes appear as they are heard"; those strings should be checked against actual behavior before release.)
- No fake reviews, star ratings, user counts, "most popular" claims without data, or fake scarcity/countdowns. The launch price has a real end date.
- No shaming decline buttons ("No, I don't like music"). Decline copy is neutral: "Not now", "Share free PDF".
- "AI" stays in the product name only, consistent with the marketing plan.

## 6. A/B copy variants

Run one variable at a time; split on a stable install ID; minimum 2 weeks or ~300 paywall views per arm, whichever is later.

| Test | A (control) | B | C |
|---|---|---|---|
| Interstitial headline | Export this as MIDI & MusicXML | Open Take 3 in your DAW or MuseScore | Keep every note of Take 3 |
| Paywall headline | Every note, in every format. | Your ear, on paper. Without limits. | From recording to MuseScore in one tap. |
| CTA | Start 7-day free trial | Try Pro free for 7 days | Continue (free for 7 days) |
| Default plan | Yearly preselected | Monthly preselected | – |
| Lifetime placement | Third row | Hidden behind "Other options" | – |
| Benefits block | By audience (students/teachers/songwriters) | By format (MIDI, MusicXML, PDF) | – |
| Interstitial timing | On first Share of the first take | On the first locked-row tap only | – |

## 7. Events and metrics

Events (no audio or score content is ever sent; on-device stays on-device. Use a privacy-preserving analytics SDK or StoreKit/ASC data only, and disclose it in the privacy label):

| Event | Properties |
|---|---|
| `paywall_trigger_suppressed` | `trigger`, `reason` (`recording`, `cap_session`, `cap_week`, `cooldown`, `lifetime_dismissals`, `no_value_yet`) |
| `paywall_view` | `trigger` (`export_soft`, `export_locked_row`, `save_limit`, `import_limit`, `third_transcription`, `settings`), `screen` (`interstitial`, `full`), `variant`, `trial_eligible` |
| `paywall_plan_select` | `product_id`, `trigger` |
| `paywall_cta_tap` | `product_id`, `trigger`, `variant` |
| `trial_start` | `product_id`, `trigger`, `variant` |
| `purchase` | `product_id`, `trigger`, `is_trial`, `is_lifetime` |
| `trial_convert` / `trial_cancel` | `product_id` (from App Store Server Notifications or `Transaction.updates`) |
| `paywall_dismiss` | `trigger`, `screen`, `method` (`close`, `swipe`, `free_pdf`, `not_now`, `replace_take`, `free_30s`), `seconds_on_screen` |
| `restore_tap` / `restore_result` | `result` (`restored`, `nothing_found`, `error`) |
| `free_export` | `kind` (`pdf_30s`, `photo`, `mp3`) |

Funnel metrics: paywall view rate per trigger, view → trial start, trial → paid (Day 7), install → paid (D7, D30), dismiss rate per trigger, lifetime share of revenue, refund rate, and churn at month 1/2 for monthly.

**Target benchmarks: assumptions, not measured data.** They are planning guesses for a niche, paid-utility iOS app and must be replaced with real numbers after launch:

| Metric | Assumed target |
|---|---|
| Install → first paywall view | 40–60% |
| Paywall view → trial start (export trigger) | 8–15% |
| Paywall view → trial start (other triggers) | 3–6% |
| Trial → paid | 35–50% |
| Install → paid by Day 30 | 2–5% |
| Yearly share of new subscriptions | > 60% |

## 8. Implementation notes (SwiftUI + StoreKit 2)

**Recommendation: a custom SwiftUI paywall** built on StoreKit 2 `Product`/`Transaction`, plus Apple's `SubscriptionStoreView` as a fallback for the Settings "Manage plan" screen.

| | `SubscriptionStoreView` (iOS 17+) | Custom view |
|---|---|---|
| Compliance | Apple renders price, period, trial terms, Restore (`.storeButton(.visible, for: .restorePurchases)`) and policies (`.subscriptionStorePolicyDestination`) | We own every disclosure (checklist in §4) |
| Lifetime (non-consumable) | Not in the same view (subscriptions only); needs a separate `ProductView` | Same picker |
| User's own score preview, trial timeline, A/B tests | Limited (`marketingContent` header only) | Full control |
| Effort | Very low | Medium |

Sketch:

- `ProStore` (`@MainActor final class`, `ObservableObject`): `Product.products(for: [monthly, yearly, lifetime])`; `isPro` derived from `Transaction.currentEntitlements` (verified only); a `Transaction.updates` listener started at launch; `purchase(_:)` → `product.purchase()` → verify → `transaction.finish()`; `restore()` → `AppStore.sync()`. Trial eligibility: `await product.subscription?.isEligibleForIntroOffer`.
- `PaywallGate` (pure logic, unit-testable): input = trigger + state (`isRecording`, `isWriting`, `completedTranscriptions`, `sessionViews`, `weekViews`, `lastDismiss`, `lifetimeDismissals`); output = `.show(screen)` or `.suppress(reason)`. Persist counters in `@AppStorage`/UserDefaults. This is where §2's "never" rules and caps live.
- Hook points in today's code:
  - `SheetDetailView.prepareShare()`: when not Pro, show the export sheet with free/locked rows (screen 5) instead of sharing everything; locked rows and the first share go through `PaywallGate` (`export_soft`).
  - `TakeLibrary.addTake(...)`: when not Pro and there are already 3 user takes, return a pending take and show screen 6 instead of saving.
  - `LibraryView.importAudio(url:)`: check the duration first; if > 30 s and not Pro, show screen 7; free path trims to 30 s before transcription.
  - `ListeningView` "The page is ready.": increments `completedTranscriptions` (for the rank 4 card); never presents a paywall itself.
- Present with `.sheet` (interstitial, `presentationDetents([.medium, .large])`) and `.fullScreenCover` (paywall) with a toolbar close button. Re-entrance: after a successful purchase, dismiss and resume the pending action (store it as an enum on the gate).
- Test with a StoreKit configuration file (`.storekit`) in the scheme, including trial, renewal, cancel, refund and Ask to Buy; App Review tests in the sandbox, so the paywall must work with sandbox products before submission.
- Products must be created in ASC (group "Pro", the two subscriptions with the 7-day intro offer, plus the non-consumable), with review screenshots of this paywall, and submitted together with the binary that contains them.

## 9. Open questions for the owner

1. Sign off on prices and the free tier (especially MP3 and photo staying free).
2. Trial on both monthly and yearly, or yearly only (common, pushes yearly)?
3. Launch date, which fixes the end of the $39.99 Lifetime window.
4. Canonical legal URLs: `music-hear/*.html` or `music-radar/*`.
5. Analytics: which SDK (or StoreKit/ASC data only), and the privacy-label update that goes with it.
