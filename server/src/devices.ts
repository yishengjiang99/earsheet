/**
 * Device registry + APNs token registration.
 *   POST /api/devices/register  { installId, appAccountToken?, osVersion, appVersion, buildNumber, deviceModel, locale, timezone }
 *   POST /api/push/register     { installId, token, environment: sandbox|production }
 *   POST /api/push/unregister   { installId, token }
 */
import express, { type Router } from 'express'
import type mysql from 'mysql2/promise'
import type { Config } from './config.ts'
import type { Db } from './db.ts'
import { clientIp, isUuid, RateLimiter, str } from './util.ts'

const TOKEN_RE = /^[0-9a-f]{64,200}$/i

export async function upsertDevice(db: Db, b: Record<string, unknown>): Promise<number> {
  const installId = String(b.installId).toLowerCase()
  const token = isUuid(b.appAccountToken) ? b.appAccountToken.toLowerCase() : null
  await db.query(
    `INSERT INTO devices (install_id, app_account_token, platform, os_version, app_version, build_number, device_model, locale, timezone)
     VALUES (?,?,?,?,?,?,?,?,?)
     ON DUPLICATE KEY UPDATE app_account_token=COALESCE(VALUES(app_account_token), app_account_token),
       os_version=COALESCE(VALUES(os_version), os_version), app_version=COALESCE(VALUES(app_version), app_version),
       build_number=COALESCE(VALUES(build_number), build_number), device_model=COALESCE(VALUES(device_model), device_model),
       locale=COALESCE(VALUES(locale), locale), timezone=COALESCE(VALUES(timezone), timezone), last_seen_at=CURRENT_TIMESTAMP(3)`,
    [installId, token, str(b.platform, 16) ?? 'ios', str(b.osVersion, 32), str(b.appVersion, 32), str(b.buildNumber, 16),
     str(b.deviceModel, 64), str(b.locale, 35), str(b.timezone, 64)])
  const [rows] = await db.query<mysql.RowDataPacket[]>('SELECT id FROM devices WHERE install_id=?', [installId])
  return rows[0]!.id as number
}

export function devicesRouter(db: Db, cfg: Config): Router {
  const r = express.Router()
  const limiter = new RateLimiter(30)
  // Per-route (not r.use): this router is mounted on /api next to others with their own limits.
  const mw = [
    express.json({ limit: '16kb' }),
    (req: express.Request, res: express.Response, next: express.NextFunction) =>
      limiter.allow(clientIp(req)) ? next() : void res.status(429).json({ error: 'rate limited' }),
  ]

  r.post('/devices/register', ...mw, async (req, res) => {
    if (!isUuid(req.body?.installId)) return void res.status(400).json({ error: 'installId (UUID) is required' })
    const id = await upsertDevice(db, req.body)
    res.json({ ok: true, deviceId: id, serverTime: new Date().toISOString() })
  })

  r.post('/push/register', ...mw, async (req, res) => {
    const b = req.body ?? {}
    if (!isUuid(b.installId)) return void res.status(400).json({ error: 'installId (UUID) is required' })
    if (typeof b.token !== 'string' || !TOKEN_RE.test(b.token)) return void res.status(400).json({ error: 'token must be the hex APNs device token' })
    if (b.environment !== 'sandbox' && b.environment !== 'production') return void res.status(400).json({ error: "environment must be 'sandbox' or 'production'" })
    const deviceId = await upsertDevice(db, b)
    await db.query(
      `INSERT INTO push_tokens (device_id, token, environment, topic, enabled) VALUES (?,?,?,?,1)
       ON DUPLICATE KEY UPDATE device_id=VALUES(device_id), environment=VALUES(environment), topic=VALUES(topic), enabled=1, last_error=NULL`,
      [deviceId, b.token.toLowerCase(), b.environment, cfg.apns.topic])
    res.json({ ok: true })
  })

  r.post('/push/unregister', ...mw, async (req, res) => {
    const b = req.body ?? {}
    if (!isUuid(b.installId) || typeof b.token !== 'string') return void res.status(400).json({ error: 'installId and token are required' })
    const [out]: any = await db.query(
      `UPDATE push_tokens p JOIN devices d ON d.id = p.device_id SET p.enabled = 0
        WHERE p.token = ? AND d.install_id = ?`, [b.token.toLowerCase(), b.installId.toLowerCase()])
    res.json({ ok: true, disabled: out.affectedRows })
  })
  return r
}
