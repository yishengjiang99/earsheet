import express from 'express'
import type { Config } from './config.ts'
import type { Db } from './db.ts'
import type { AppleVerifier } from './apple.ts'
import { apnsConfigured, type ApnsSender } from './apns.ts'
import { iapRouter } from './iap.ts'
import { devicesRouter } from './devices.ts'
import { telemetryRouter } from './telemetry.ts'
import { adminRouter } from './admin.ts'

export const VERSION = '1.0.0'

export function createApp(deps: { db: Db; cfg: Config; verifier: AppleVerifier; sendPush: ApnsSender }) {
  const { db, cfg, verifier, sendPush } = deps
  const app = express()
  app.disable('x-powered-by')
  app.set('trust proxy', 'loopback')
  const root = express.Router()

  root.get('/api/health', async (_req, res) => {
    let dbOk = false
    try { await db.query('SELECT 1'); dbOk = true } catch { /* reported below */ }
    res.status(dbOk ? 200 : 503).set('Cache-Control', 'no-store').json({
      ok: dbOk, service: 'music-radar-api', version: VERSION, db: dbOk, bundleId: cfg.bundleId,
      apns: apnsConfigured(cfg), admin: Boolean(cfg.adminPassword),
    })
  })
  root.use('/api/iap', iapRouter(db, cfg, verifier))
  root.use('/api', devicesRouter(db, cfg))
  root.use('/api', telemetryRouter(db, cfg))
  root.use('/admin', adminRouter(db, cfg, sendPush))

  app.use(cfg.basePath || '/', root)
  app.use((_req, res) => void res.status(404).json({ error: 'not found' }))
  app.use((err: any, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
    const status = err?.type === 'entity.too.large' ? 413 : err?.type === 'entity.parse.failed' ? 400 : 500
    if (status === 500) console.error('[error]', err)
    res.status(status).json({ error: status === 413 ? 'payload too large' : status === 400 ? 'invalid JSON' : 'internal error' })
  })
  return app
}
