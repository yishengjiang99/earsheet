# Telemetry (product analytics)

Endpoint: `POST https://grepawk.com/music-radar/api/telemetry/batch` (code: `server/src/telemetry.ts`). Admin view: the Telemetry tab in the admin panel.
Status: the server is live. The iOS client is `Sources/App/Telemetry.swift` (branch `agent/ios-server`): it sends `app_open`, `session_start`, `transcription_start`, `transcription_stop`, `paywall_view`, `purchase_start`, `purchase_success`, `purchase_fail` (`reason` cancelled/pending/error, `code`) and `restore` (`result`, `restored`). Properties are allow-listed (`cold`, `source`, `duration_s`, `notes`, `product`, `reason`, `code`, `result`, `restored`). Flushed on each heartbeat (foreground + every 5 min) and on background.

## Rules (server-enforced)
- **No audio and no PII.** Property keys that look like PII are dropped (email, phone, name, address, location/lat/lon, ip, token, password, audio, recording, waveform, samples, transcript_text, idfa…), as are string values that look like emails or phone numbers. Never send note content, file names, or titles.
- `name`: `^[a-z][a-z0-9_]{1,63}$` (snake_case).
- `installId` (required) and `sessionId` (optional) must be UUIDs. Use the Keychain install ID, not the IDFV.
- `ts`: epoch seconds or ms, or ISO 8601. It must be at most 30 days in the past and at most 1 h in the future.
- `properties`: a flat object of string (≤200 chars), number, bool, or null; ≤40 keys, ≤2 KB once serialized. Nested values are dropped.
- ≤100 events per batch, ≤128 KB per body, ≤30 batches/min per IP and per installId (429 with `Retry-After: 60`).
- Invalid events are dropped and counted, which isn't an error: `{"ok":true,"accepted":N,"dropped":M}`. An empty batch returns 400, and more than 100 events returns 413.

```json
POST /api/telemetry/batch
{"events":[{"name":"transcription_stop","ts":1791313200,"installId":"8f0c…","sessionId":"1b2e…","appVersion":"1.0",
            "properties":{"source":"mic","duration_s":42.5,"notes":118,"model":"ft-exp0"}}]}
→ {"ok":true,"accepted":1,"dropped":0}
```

## Client batching (recommended)
- Append events to an on-disk queue (a JSON-lines file in Application Support) so they survive kills and offline periods.
- Flush every ~30 s while in the foreground, when 50 events are queued, and on `scenePhase == .background` (inside a `beginBackgroundTask`).
- Remove a batch only after a 2xx. On 429, honor `Retry-After`. On 5xx or network errors, use exponential backoff (5 s → 10 min). On 400 or 413, drop or split the batch.
- Cap the queue at about 5,000 events (drop the oldest). Events older than 30 days get rejected anyway.
- `sessionId`: a new UUID on each foreground session (after more than 30 min in the background).
- Respect an opt-out toggle in Settings, which clears the queue.

## Event list (suggested)

| Event | Properties |
|---|---|
| `app_open` | `cold` (bool) |
| `session_start` / `session_end` | `duration_s` (end) |
| `onboarding_complete` | `pages_seen` |
| `mic_permission_prompt` / `mic_permission_granted` / `mic_permission_denied` | – |
| `transcription_start` | `source` (mic\|import) |
| `transcription_stop` | `source`, `duration_s`, `notes`, `model`, `latency_ms` |
| `file_import` | `duration_s`, `format` (m4a\|mp3\|wav…), `truncated` (bool, free 30 s cap) |
| `take_saved` / `take_deleted` | `count` (library size) |
| `export_midi` / `export_musicxml` / `export_pdf` / `export_mp3` / `export_photo` | `locked` (bool, Pro gate hit) |
| `playback_start` | `view` (page\|roll) |
| `paywall_view` | `trigger` (export\|import_limit\|save_limit\|soft_card\|settings), `variant` |
| `paywall_dismiss` | `trigger` |
| `purchase_start` / `purchase_success` / `purchase_fail` / `purchase_cancel` | `product` (product ID), `error` (fail: StoreKit error code, no message text) |
| `trial_start` | `product` |
| `restore_start` / `restore_success` / `restore_fail` | `restored` (count) |
| `push_permission_prompt` / `push_permission_granted` / `push_permission_denied` | – |
| `error` | `domain`, `code` (no messages that could contain user data) |
