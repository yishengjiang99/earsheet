/**
 * Batched product-analytics ingest. No audio, no PII.
 *   POST /api/telemetry/batch  { events: [{ name, ts, installId, sessionId?, appVersion?, properties? }] }  (or a bare array)
 * Limits: body <= TELEMETRY_MAX_BODY_BYTES, <= TELEMETRY_MAX_BATCH events, properties <= TELEMETRY_MAX_PROPS_BYTES,
 * TELEMETRY_RATE_PER_MINUTE batches per IP and per installId. Invalid events are dropped and counted, not fatal.
 */
import express, { type Router } from 'express'
import type { Config } from './config.ts'
import type { Db } from './db.ts'
import { clientIp, isUuid, RateLimiter, str } from './util.ts'

const NAME_RE = /^[a-z][a-z0-9_]{1,63}$/
const PII_KEY_RE = /(e-?mail|phone|first_?name|last_?name|full_?name|user_?name|address|street|zip|postal|lat(itude)?$|lon(gitude)?$|location|gps|ip_?addr|^ip$|password|secret|token|audio|recording|waveform|samples|transcript_text|device_?token|idfa|advertising)/i
const EMAIL_RE = /[^\s@]+@[^\s@]+\.[^\s@]+/
const PHONE_RE = /\+?\d[\d\s().-]{8,}\d/

/** Keep only flat scalar properties; drop PII-looking keys and values. */
export function scrubProperties(p: unknown, maxBytes: number): Record<string, string | number | boolean | null> | null {
  if (!p || typeof p !== 'object' || Array.isArray(p)) return null
  const out: Record<string, string | number | boolean | null> = {}
  for (const [k, v] of Object.entries(p as Record<string, unknown>).slice(0, 40)) {
    if (!/^[A-Za-z][A-Za-z0-9_]{0,39}$/.test(k) || PII_KEY_RE.test(k)) continue
    if (typeof v === 'string') {
      if (EMAIL_RE.test(v) || PHONE_RE.test(v)) continue
      out[k] = v.slice(0, 200)
    } else if (typeof v === 'number' && Number.isFinite(v)) out[k] = v
    else if (typeof v === 'boolean' || v === null) out[k] = v
  }
  if (!Object.keys(out).length) return null
  return Buffer.byteLength(JSON.stringify(out)) <= maxBytes ? out : null
}

export function parseTs(v: unknown, nowMs: number): Date | null {
  const ms = typeof v === 'number' ? (v < 1e12 ? v * 1000 : v) : typeof v === 'string' ? Date.parse(v) : NaN
  if (!Number.isFinite(ms)) return null
  if (ms > nowMs + 60 * 60_000 || ms < nowMs - 30 * 24 * 60 * 60_000) return null // up to 30 days of offline backlog
  return new Date(ms)
}

export function telemetryRouter(db: Db, cfg: Config): Router {
  const r = express.Router()
  const t = cfg.telemetry
  const byIp = new RateLimiter(t.ratePerMinute)
  const byInstall = new RateLimiter(t.ratePerMinute)
  r.post('/telemetry/batch', express.json({ limit: t.maxBodyBytes }), async (req, res) => {
    if (!byIp.allow(clientIp(req))) return void res.status(429).set('Retry-After', '60').json({ error: 'rate limited' })
    const events: unknown[] = Array.isArray(req.body) ? req.body : Array.isArray(req.body?.events) ? req.body.events : []
    if (!events.length) return void res.status(400).json({ error: 'events[] is required' })
    if (events.length > t.maxBatch) return void res.status(413).json({ error: `at most ${t.maxBatch} events per batch` })
    const installs = new Set(events.map((e: any) => (isUuid(e?.installId) ? e.installId.toLowerCase() : '')).filter(Boolean))
    for (const id of installs) if (!byInstall.allow(id)) return void res.status(429).set('Retry-After', '60').json({ error: 'rate limited' })
    const now = Date.now()
    const rows: unknown[][] = []
    let dropped = 0
    for (const e of events as any[]) {
      const ts = parseTs(e?.ts ?? e?.timestamp, now)
      if (!e || typeof e.name !== 'string' || !NAME_RE.test(e.name) || !isUuid(e.installId) || !ts ||
          (e.sessionId != null && !isUuid(e.sessionId))) { dropped++; continue }
      const props = scrubProperties(e.properties, t.maxPropsBytes)
      rows.push([e.name, ts, e.installId.toLowerCase(), e.sessionId ? e.sessionId.toLowerCase() : null, str(e.appVersion, 32), props ? JSON.stringify(props) : null])
    }
    if (rows.length)
      await db.query('INSERT INTO telemetry_events (name, occurred_at, install_id, session_id, app_version, properties) VALUES ?', [rows])
    res.json({ ok: true, accepted: rows.length, dropped })
  })
  return r
}
