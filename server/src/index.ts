import { loadConfig } from './config.ts'
import { createPool, migrate } from './db.ts'
import { createAppleVerifier } from './apple.ts'
import { createApnsSender } from './apns.ts'
import { createApp } from './app.ts'

const cfg = loadConfig()
if (cfg.production && (!cfg.adminPassword || !cfg.sessionSecret)) console.warn('[admin] ADMIN_PASSWORD / SESSION_SECRET not set: admin disabled')
const db = createPool()
const applied = await migrate(db)
if (applied.length) console.log('[db] applied migrations:', applied.join(', '))
const app = createApp({ db, cfg, verifier: createAppleVerifier(cfg), sendPush: createApnsSender(cfg) })
app.listen(cfg.port, '127.0.0.1', () => console.log(`[music-radar-api] listening on 127.0.0.1:${cfg.port}${cfg.basePath}`))
