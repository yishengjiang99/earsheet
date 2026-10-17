# App Privacy answers (App Store Connect → App Privacy)

Source of truth for the owner. This repo never edits App Store Connect (publish by hand in the web UI). Keep these four places in agreement: `Sources/App/PrivacyInfo.xcprivacy`, this file, `docs/legal/music-radar/privacy.html`, the ASC nutrition label.

Decision (2026-10-17): data is declared **Linked** (conservative). The random per-install ID is stored with purchase verification, so the server can tie usage events, the device record and purchases to the same install, although never to a name, email or Apple ID. **Tracking = No** (no ads, no third-party SDKs, no data broker sharing, no cross-app/site linking).

## Data collection

| ASC data type | Collected | Linked to user | Used to track | Purposes | What the app sends |
|---|---|---|---|---|---|
| Purchases → Purchase History | Yes | Yes | No | App Functionality | Apple's signed transaction, keyed by an anonymous account token, to confirm Pro (`ServerSync`/`VerifyQueue`) |
| Identifiers → Device ID | Yes | Yes | No | App Functionality, Analytics | Random install UUID (Keychain, not IDFV/IDFA); device record (OS/app version, device model, language/region, time zone); push token if notifications are allowed |
| Usage Data → Product Interaction | Yes | Yes | No | Analytics | Anonymous feature events (`Telemetry`: app open, session, transcription start/stop with source, length and note count, paywall view, purchase/restore result). Turned off with Settings → Share anonymous usage data |

Not collected: contact info, health, financial info, location, sensitive info, contacts, user content (audio, notes, titles, file names and photos never leave the device), search history, browsing history, advertising data, crash data (Apple's own aggregated stats only), other data types.

## Tracking
"Do you or your third-party partners use data for tracking?" → **No**. `NSPrivacyTracking` is `false`, `NSPrivacyTrackingDomains` is empty, no `NSUserTrackingUsageDescription`, no ATT prompt.

## Privacy manifest (`Sources/App/PrivacyInfo.xcprivacy`)
- Required-reason API: UserDefaults, reason `CA92.1` (app's own settings: onboarding flag, Pro cache, paywall caps, telemetry opt-out, push token, input conditioner settings).
- Collected data types: the three above, each `Linked=true`, `Tracking=false`.
- The anonymous-usage opt-out removes Product Interaction events but the label still lists the type (data is collected by default).

## When to update
Change this file, the manifest and the privacy page together whenever `Telemetry.allowedPropertyKeys`, the device record fields, push or purchase verification change.
