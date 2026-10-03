import type { AddressInfo } from 'node:net'
import type { Server } from 'node:http'
import { loadConfig, type Config } from '../src/config.ts'
import { createPool, migrate, type Db } from '../src/db.ts'
import { peekJws, type AppleVerifier } from '../src/apple.ts'
import type { ApnsSender } from '../src/apns.ts'
import { createApp } from '../src/app.ts'

export const TEST_DB_URL = process.env.MYSQL_TEST_URL || 'mysql://mr:mrtest@127.0.0.1:3306/mr_test'

export async function freshDb(): Promise<Db> {
  process.env.MYSQL_URL = TEST_DB_URL
  const db = createPool()
  await db.query('SET FOREIGN_KEY_CHECKS=0')
  for (const t of ['push_sends', 'telemetry_events', 'notification_events', 'subscriptions', 'iap_transactions', 'push_tokens', 'devices', 'schema_migrations'])
    await db.query(`DROP TABLE IF EXISTS ${t}`)
  await db.query('SET FOREIGN_KEY_CHECKS=1')
  await migrate(db)
  return db
}

/** Unsigned fixture JWS; FakeVerifier accepts it unless the signature segment is "bad". */
export const jws = (payload: object) =>
  `${Buffer.from('{"alg":"ES256"}').toString('base64url')}.${Buffer.from(JSON.stringify(payload)).toString('base64url')}.sig`
export const badJws = (payload: object) => jws(payload).replace(/\.sig$/, '.bad')

export const fakeVerifier: AppleVerifier = {
  async transaction(s) { if (s.endsWith('.bad')) throw new Error('bad signature'); return peekJws(s) as any },
  async renewalInfo(s) { if (s.endsWith('.bad')) throw new Error('bad signature'); return peekJws(s) as any },
  async notification(s) { if (!s.endsWith('.sig')) throw new Error('bad signature'); return peekJws(s) as any },
}

export const sent: { token: string; env: string; payload: any }[] = []
export const fakePush: ApnsSender = async (token, env, payload) => {
  sent.push({ token, env, payload })
  return token.startsWith('dead') ? { status: 410, apnsId: 'x', reason: 'Unregistered' } : { status: 200, apnsId: 'apns-1', reason: null }
}

export async function startServer(db: Db, over: Partial<Config> = {}, verifier: AppleVerifier = fakeVerifier) {
  process.env.ADMIN_PASSWORD = 'test-admin-pw'
  process.env.SESSION_SECRET = 'test-session-secret'
  const cfg = { ...loadConfig(), ...over }
  const app = createApp({ db, cfg, verifier, sendPush: fakePush })
  const server: Server = await new Promise((r) => { const s = app.listen(0, '127.0.0.1', () => r(s)) })
  const url = `http://127.0.0.1:${(server.address() as AddressInfo).port}${cfg.basePath}`
  return { url, cfg, close: () => new Promise<void>((r) => server.close(() => r())) }
}

export const post = (url: string, body: unknown, headers: Record<string, string> = {}) =>
  fetch(url, { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: JSON.stringify(body) })

export const DAY = 24 * 60 * 60_000
export const TOKEN = '2f6b6f0e-8c1a-4c1e-9a52-5d3f0a7b9e11'
export const INSTALL = '7d2c1a90-4b5e-4f6a-8b9c-0d1e2f3a4b5c'
export function tx(over: Record<string, unknown> = {}) {
  const now = Date.now()
  return {
    transactionId: '2000000000000001', originalTransactionId: '2000000000000001', bundleId: 'com.ragnus.pnge',
    productId: 'com.ragnus.pnge.pro.monthly', purchaseDate: now - 1000, originalPurchaseDate: now - 1000, expiresDate: now + 7 * DAY,
    type: 'Auto-Renewable Subscription', inAppOwnershipType: 'PURCHASED', environment: 'Sandbox', appAccountToken: TOKEN,
    offerType: 1, offerDiscountType: 'FREE_TRIAL', price: 0, currency: 'USD', storefront: 'USA', ...over,
  }
}
