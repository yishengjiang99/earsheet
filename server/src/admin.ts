/**
 * Admin panel at {BASE_PATH}/admin. Login with ADMIN_PASSWORD (env file); session is an HMAC-signed
 * cookie (SESSION_SECRET), httpOnly + SameSite=Strict, scoped to {BASE_PATH}/admin. POSTs also require a same-origin
 * Origin/Referer. Views: overview, devices (+per-device history), push tokens + test push, subscriptions,
 * notification events, telemetry.
 */
import crypto from 'node:crypto'
import express, { type Request, type Response, type Router } from 'express'
import cookieParser from 'cookie-parser'
import type mysql from 'mysql2/promise'
import type { Config } from './config.ts'
import type { Db } from './db.ts'
import { apnsConfigured, deadToken, type ApnsSender } from './apns.ts'
import { clientIp, RateLimiter } from './util.ts'

const COOKIE = 'mr_admin'
const SESSION_MS = 12 * 60 * 60_000

export const esc = (v: unknown): string =>
  String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!)
/** Trusted HTML built by this module (links, bars); everything else is escaped. */
class Raw { constructor(readonly html: string) {} }
const raw = (h: string) => new Raw(h)
const cell = (v: unknown) => (v instanceof Raw ? v.html : v instanceof Date ? fmt(v) : v !== null && typeof v === 'object' ? esc(JSON.stringify(v)) : esc(v))
const fmt = (d: unknown) => (d ? new Date(d as string).toISOString().replace('T', ' ').slice(0, 19) : '')

function hmac(secret: string, v: string) {
  return crypto.createHmac('sha256', secret).update(v).digest('base64url')
}
function safeEq(a: string, b: string) {
  const x = Buffer.from(a), y = Buffer.from(b)
  return x.length === y.length && crypto.timingSafeEqual(x, y)
}

export function adminRouter(db: Db, cfg: Config, sendPush: ApnsSender): Router {
  const r = express.Router()
  const base = `${cfg.basePath}/admin`
  const secret = cfg.sessionSecret || cfg.adminPassword
  const loginLimiter = new RateLimiter(10, 15 * 60_000)
  r.use(cookieParser())
  r.use(express.urlencoded({ extended: false, limit: '16kb' }))
  r.use((_req, res, next) => {
    res.set({ 'Cache-Control': 'no-store', 'X-Frame-Options': 'DENY', 'Referrer-Policy': 'same-origin',
      'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'" })
    next()
  })

  const authed = (req: Request) => {
    const c = req.cookies?.[COOKIE]
    if (!c || !secret) return false
    const [exp, sig] = String(c).split('.')
    return Boolean(exp && sig && Number(exp) > Date.now() && safeEq(sig, hmac(secret, `admin:${exp}`)))
  }
  const sameOrigin = (req: Request) => {
    const o = String(req.headers.origin || req.headers.referer || '')
    if (!o) return false
    try { return new URL(o).host === req.headers.host } catch { return false }
  }

  const page = (title: string, body: string) => `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)} · AI Music Radar admin</title><style>
body{font:14px -apple-system,system-ui,sans-serif;margin:0;color:#111;background:#f6f7f9}header{background:#0b1a2b;color:#fff;padding:10px 16px;display:flex;gap:14px;flex-wrap:wrap;align-items:center}
header a{color:#9fe8c8;text-decoration:none}header b{margin-right:12px}main{padding:16px;max-width:1200px}table{border-collapse:collapse;background:#fff;width:100%;margin:8px 0 20px}
td,th{border:1px solid #e3e5e8;padding:4px 7px;text-align:left;vertical-align:top;font-size:13px}th{background:#eef1f4}.cards{display:flex;gap:10px;flex-wrap:wrap}
.card{background:#fff;border:1px solid #e3e5e8;border-radius:8px;padding:10px 14px;min-width:140px}.card .n{font-size:22px;font-weight:600}code{font-size:12px}
.bar{background:#3fbf8f;height:10px;display:inline-block}form.inline{display:inline}input,select,textarea{font:inherit;padding:4px}</style></head><body>
<header><b>AI Music Radar admin</b><a href="${base}">Overview</a><a href="${base}/devices">Devices</a><a href="${base}/push">Push</a>
<a href="${base}/subscriptions">Subscriptions</a><a href="${base}/notifications">ASSN events</a><a href="${base}/telemetry">Telemetry</a>
<form class="inline" method="post" action="${base}/logout" style="margin-left:auto"><button>Log out</button></form></header><main><h2>${esc(title)}</h2>${body}</main></body></html>`

  const table = (rows: Record<string, unknown>[], cols?: string[]) => {
    if (!rows.length) return '<p><i>none</i></p>'
    const c = cols ?? Object.keys(rows[0]!)
    return `<table><tr>${c.map((k) => `<th>${esc(k)}</th>`).join('')}</tr>${rows
      .map((row) => `<tr>${c.map((k) => `<td>${cell(row[k])}</td>`).join('')}</tr>`)
      .join('')}</table>`
  }
  const q = async (sql: string, args: unknown[] = []) => (await db.query<mysql.RowDataPacket[]>(sql, args))[0] as Record<string, any>[]

  r.get('/login', (req, res) => {
    const err = req.query.e ? '<p style="color:#b00">Wrong password.</p>' : ''
    const off = !cfg.adminPassword ? '<p style="color:#b00">ADMIN_PASSWORD is not set; admin is disabled.</p>' : ''
    res.send(`<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Admin login</title>
<body style="font:15px system-ui;max-width:22rem;margin:4rem auto"><h3>AI Music Radar admin</h3>${off}${err}
<form method="post" action="${base}/login"><input type="password" name="password" autofocus required style="width:100%;padding:8px"><p><button>Log in</button></p></form></body>`)
  })
  r.post('/login', (req, res) => {
    if (!cfg.adminPassword || !secret) return void res.status(503).send('admin disabled')
    if (!sameOrigin(req)) return void res.status(403).send('bad origin')
    if (!loginLimiter.allow(clientIp(req))) return void res.status(429).send('too many attempts; wait 15 minutes')
    const pw = typeof req.body?.password === 'string' ? req.body.password : ''
    const a = crypto.createHash('sha256').update(pw).digest(), b = crypto.createHash('sha256').update(cfg.adminPassword).digest()
    if (!crypto.timingSafeEqual(a, b)) return void res.redirect(303, `${base}/login?e=1`)
    const exp = String(Date.now() + SESSION_MS)
    res.cookie(COOKIE, `${exp}.${hmac(secret, `admin:${exp}`)}`, { httpOnly: true, sameSite: 'strict', secure: cfg.production, path: base, maxAge: SESSION_MS })
    res.redirect(303, base)
  })
  r.post('/logout', (req, res) => {
    res.clearCookie(COOKIE, { path: base })
    res.redirect(303, `${base}/login`)
  })

  r.use((req, res, next) => {
    if (!authed(req)) return void res.redirect(303, `${base}/login`)
    if (req.method === 'POST' && !sameOrigin(req)) return void res.status(403).send('bad origin')
    next()
  })

  const envFilter = (req: Request) => (req.query.env === 'Sandbox' ? 'Sandbox' : 'Production')
  const envToggle = (req: Request, path: string) => {
    const e = envFilter(req)
    return `<p>Environment: <b>${e}</b> · <a href="${base}${path}?env=${e === 'Production' ? 'Sandbox' : 'Production'}">show ${e === 'Production' ? 'Sandbox/TestFlight' : 'Production'}</a></p>`
  }

  r.get('/', async (req, res) => {
    const env = envFilter(req)
    const [[c]] = [await q(`SELECT
      (SELECT COUNT(*) FROM devices) devices,
      (SELECT COUNT(*) FROM devices WHERE last_seen_at > NOW() - INTERVAL 1 DAY) dau,
      (SELECT COUNT(*) FROM devices WHERE last_seen_at > NOW() - INTERVAL 30 DAY) mau,
      (SELECT COUNT(*) FROM push_tokens WHERE enabled=1) push_enabled,
      (SELECT COUNT(*) FROM telemetry_events WHERE occurred_at > NOW() - INTERVAL 1 DAY) events_24h`)]
    const subs = await q(`SELECT product_id, status, COUNT(*) n FROM subscriptions WHERE environment=? GROUP BY product_id, status ORDER BY product_id, status`, [env])
    const revenue = await q(`SELECT currency, COUNT(*) purchases, ROUND(SUM(price_milli)/1000, 2) gross,
        ROUND(SUM(CASE WHEN purchase_date > NOW() - INTERVAL 30 DAY THEN price_milli ELSE 0 END)/1000, 2) gross_30d
      FROM iap_transactions WHERE environment=? AND revocation_date IS NULL AND price_milli > 0 GROUP BY currency`, [env])
    const pro = (await q(`SELECT COUNT(DISTINCT COALESCE(app_account_token, original_transaction_id)) n FROM subscriptions
      WHERE environment=? AND status IN ('active','trial','grace') AND (kind='lifetime' OR expires_at > NOW())`, [env]))[0]!.n
    const card = (label: string, n: unknown) => `<div class="card"><div>${esc(label)}</div><div class="n">${esc(n)}</div></div>`
    res.send(page('Overview', `<div class="cards">${card('Devices', c!.devices)}${card('Active 24h', c!.dau)}${card('Active 30d', c!.mau)}
      ${card('Push tokens on', c!.push_enabled)}${card(`Pro users (${env})`, pro)}${card('Events 24h', c!.events_24h)}</div>
      ${envToggle(req, '')}<h3>Subscriptions by product/status</h3>${table(subs)}
      <h3>Revenue (customer price, before Apple's commission; refunds excluded)</h3>${table(revenue)}`))
  })

  r.get('/devices', async (_req, res) => {
    const rows = await q(`SELECT d.install_id, d.app_account_token, d.app_version, d.build_number, d.os_version, d.device_model, d.locale, d.timezone,
        d.first_seen_at, d.last_seen_at, (SELECT COUNT(*) FROM push_tokens p WHERE p.device_id=d.id AND p.enabled=1) push
      FROM devices d ORDER BY d.last_seen_at DESC LIMIT 300`)
    for (const row of rows) row.install_id = raw(`<a href="${base}/devices/${esc(row.install_id)}">${esc(row.install_id)}</a>`)
    res.send(page('Devices (latest 300)', table(rows)))
  })

  r.get('/devices/:installId', async (req, res) => {
    const id = String(req.params.installId).toLowerCase()
    const dev = await q('SELECT * FROM devices WHERE install_id=?', [id])
    if (!dev.length) return void res.status(404).send(page('Device not found', ''))
    const tokens = await q('SELECT id, LEFT(token, 12) token_prefix, environment, enabled, last_error, created_at, updated_at, last_sent_at FROM push_tokens WHERE device_id=?', [dev[0]!.id])
    const subs = dev[0]!.app_account_token ? await q('SELECT original_transaction_id, product_id, environment, status, expires_at, auto_renew, is_trial, last_event, updated_at FROM subscriptions WHERE app_account_token=?', [dev[0]!.app_account_token]) : []
    const events = await q('SELECT occurred_at, name, session_id, app_version, properties FROM telemetry_events WHERE install_id=? ORDER BY occurred_at DESC LIMIT 500', [id])
    res.send(page(`Device ${id}`, `${table(dev)}<h3>Push tokens</h3>${table(tokens)}<h3>Subscriptions</h3>${table(subs)}<h3>Event history (latest 500)</h3>${table(events)}`))
  })

  r.get('/push', async (req, res) => {
    const tokens = await q(`SELECT p.id, d.install_id, LEFT(p.token, 12) token_prefix, p.environment, p.topic, p.enabled, p.last_error, p.updated_at, p.last_sent_at
      FROM push_tokens p JOIN devices d ON d.id=p.device_id ORDER BY p.updated_at DESC LIMIT 300`)
    const sends = await q('SELECT created_at, push_token_id, environment, title, status, reason, apns_id FROM push_sends ORDER BY id DESC LIMIT 50')
    const msg = req.query.sent ? `<p><b>Result:</b> ${esc(req.query.sent)}</p>` : ''
    const warn = apnsConfigured(cfg) ? '' : '<p style="color:#b00">APNs is not configured (APNS_KEY_ID / APNS_TEAM_ID / APNS_P8_PATH).</p>'
    res.send(page('Push', `${warn}${msg}<h3>Send test push</h3>
      <form method="post" action="${base}/push/test"><p>Push token id <input name="tokenId" size="6" required> (from the table)
      Title <input name="title" value="AI Music Radar" maxlength="80"> Body <input name="body" value="Test notification" maxlength="160" size="30"> <button>Send</button></p></form>
      <h3>Tokens</h3>${table(tokens)}<h3>Recent sends</h3>${table(sends)}`))
  })

  r.post('/push/test', async (req, res) => {
    const id = Number(req.body?.tokenId)
    const rows = await q('SELECT id, token, environment FROM push_tokens WHERE id=?', [id])
    if (!rows.length) return void res.redirect(303, `${base}/push?sent=${encodeURIComponent('no such token')}`)
    const t = rows[0]!
    const title = String(req.body?.title || 'AI Music Radar').slice(0, 80), body = String(req.body?.body || 'Test notification').slice(0, 160)
    let result
    try {
      result = await sendPush(t.token, t.environment, { aps: { alert: { title, body }, sound: 'default' } })
    } catch (e) {
      result = { status: 0, apnsId: null, reason: (e as Error).message.slice(0, 80) }
    }
    await db.query('INSERT INTO push_sends (push_token_id, environment, title, status, apns_id, reason) VALUES (?,?,?,?,?,?)',
      [t.id, t.environment, title, result.status, result.apnsId, result.reason])
    await db.query('UPDATE push_tokens SET last_sent_at=CURRENT_TIMESTAMP(3), last_error=?, enabled=IF(?, 0, enabled) WHERE id=?',
      [result.status === 200 ? null : `${result.status} ${result.reason ?? ''}`.trim(), deadToken(result), t.id])
    res.redirect(303, `${base}/push?sent=${encodeURIComponent(`${result.status} ${result.reason ?? 'OK'}`)}`)
  })

  r.get('/subscriptions', async (req, res) => {
    const env = envFilter(req)
    const rows = await q(`SELECT original_transaction_id, product_id, kind, status, expires_at, auto_renew, auto_renew_product_id, is_trial, revoked_at,
        app_account_token, last_event, first_purchase_at, updated_at FROM subscriptions WHERE environment=? ORDER BY updated_at DESC LIMIT 300`, [env])
    const tx = await q(`SELECT transaction_id, original_transaction_id, product_id, purchase_date, expires_date, offer_discount_type, ROUND(price_milli/1000,2) price,
        currency, storefront, revocation_date, source FROM iap_transactions WHERE environment=? ORDER BY purchase_date DESC LIMIT 200`, [env])
    res.send(page('Subscriptions', `${envToggle(req, '/subscriptions')}${table(rows)}<h3>Transactions (latest 200)</h3>${table(tx)}`))
  })

  r.get('/notifications', async (_req, res) => {
    const rows = await q(`SELECT received_at, notification_type, subtype, environment, verified, original_transaction_id, transaction_id, product_id, signed_date, error
      FROM notification_events ORDER BY id DESC LIMIT 300`)
    res.send(page('App Store Server Notifications (latest 300)', table(rows)))
  })

  r.get('/telemetry', async (req, res) => {
    const days = Math.min(Math.max(Number(req.query.days) || 14, 1), 90)
    const daily = await q(`SELECT DATE(occurred_at) day, COUNT(*) events, COUNT(DISTINCT install_id) devices FROM telemetry_events
      WHERE occurred_at > NOW() - INTERVAL ? DAY GROUP BY DATE(occurred_at) ORDER BY day DESC`, [days])
    const max = Math.max(1, ...daily.map((d) => Number(d.events)))
    for (const d of daily) d.chart = raw(`<span class="bar" style="width:${Math.round((Number(d.events) / max) * 300)}px"></span>`)
    const top = await q(`SELECT name, COUNT(*) events, COUNT(DISTINCT install_id) devices FROM telemetry_events
      WHERE occurred_at > NOW() - INTERVAL ? DAY GROUP BY name ORDER BY events DESC LIMIT 50`, [days])
    const recent = await q('SELECT occurred_at, name, install_id, app_version, properties FROM telemetry_events ORDER BY id DESC LIMIT 100')
    for (const e of recent) {
      e.install_id = raw(`<a href="${base}/devices/${esc(e.install_id)}">${esc(String(e.install_id).slice(0, 8))}…</a>`)
    }
    res.send(page('Telemetry', `<p>Window: ${[1, 7, 14, 30, 90].map((d) => d === days ? `<b>${d}d</b>` : `<a href="${base}/telemetry?days=${d}">${d}d</a>`).join(' · ')}</p>
      <h3>Events per day</h3>${table(daily, ['day', 'events', 'devices', 'chart'])}<h3>Top events</h3>${table(top)}<h3>Latest 100</h3>${table(recent)}`))
  })
  return r
}
