/**
 * StoreKit 2 endpoints + App Store Server Notifications V2 webhook.
 *   POST /api/iap/verify         { signedTransaction, appAccountToken? }       -> entitlement
 *   POST /api/iap/restore        { signedTransactions: [...], appAccountToken } -> entitlement
 *   GET  /api/iap/entitlement?appAccountToken=UUID
 *   GET  /api/iap/products
 *   POST /api/iap/notifications  { signedPayload }  (ASSN v2, production + sandbox URL)
 * Every JWS is verified against Apple's root CA before anything is stored.
 */
import express, { type Router } from 'express'
import type { Config } from './config.ts'
import type { Db } from './db.ts'
import { toDate } from './db.ts'
import type { AppleVerifier, EnvName } from './apple.ts'
import { peekJws } from './apple.ts'
import { catalog } from './products.ts'
import { entitlementFor, recordTransaction } from './subscriptions.ts'
import { clientIp, isUuid, RateLimiter } from './util.ts'

export function iapRouter(db: Db, cfg: Config, verifier: AppleVerifier): Router {
  const r = express.Router()
  const limiter = new RateLimiter(60)
  const json = express.json({ limit: '256kb' })

  async function verifyOne(jws: string, token: string | null, source: 'verify' | 'restore') {
    let tx
    try {
      tx = await verifier.transaction(jws)
    } catch (e) {
      return { ok: false as const, error: `signature verification failed: ${(e as Error).message || 'invalid JWS'}`.slice(0, 200) }
    }
    if (token && tx.appAccountToken && tx.appAccountToken.toLowerCase() !== token.toLowerCase())
      return { ok: false as const, error: 'appAccountToken does not match the transaction' }
    return recordTransaction(db, cfg, tx, { source, appAccountToken: token })
  }

  r.post('/verify', json, async (req, res) => {
    if (!limiter.allow(`v:${clientIp(req)}`)) return void res.status(429).json({ error: 'rate limited' })
    const jws = typeof req.body?.signedTransaction === 'string' ? req.body.signedTransaction.trim() : ''
    const token = isUuid(req.body?.appAccountToken) ? req.body.appAccountToken.toLowerCase() : null
    if (!jws) return void res.status(400).json({ error: 'signedTransaction (StoreKit 2 JWS) is required' })
    const out = await verifyOne(jws, token, 'verify')
    if (!out.ok) return void res.status(400).json(out)
    const ownerToken = token ?? (peekJws(jws)?.appAccountToken as string | undefined)?.toLowerCase()
    res.json({ ok: true, transaction: out, entitlement: ownerToken ? await entitlementFor(db, ownerToken) : null })
  })

  r.post('/restore', json, async (req, res) => {
    if (!limiter.allow(`r:${clientIp(req)}`)) return void res.status(429).json({ error: 'rate limited' })
    const list = Array.isArray(req.body?.signedTransactions) ? req.body.signedTransactions.filter((s: unknown) => typeof s === 'string') : []
    const token = isUuid(req.body?.appAccountToken) ? req.body.appAccountToken.toLowerCase() : null
    if (!token) return void res.status(400).json({ error: 'appAccountToken (UUID) is required' })
    if (list.length > 50) return void res.status(413).json({ error: 'at most 50 transactions' })
    const results = []
    for (const jws of list) results.push(await verifyOne(jws, token, 'restore'))
    res.json({ ok: true, results, entitlement: await entitlementFor(db, token) })
  })

  r.get('/entitlement', async (req, res) => {
    const token = req.query.appAccountToken
    if (!isUuid(token)) return void res.status(400).json({ error: 'appAccountToken (UUID) is required' })
    res.set('Cache-Control', 'no-store').json(await entitlementFor(db, token))
  })

  r.get('/products', (_req, res) => {
    res.json({ bundleId: cfg.bundleId, subscriptionGroup: 'AI Music Radar Pro', products: catalog(cfg) })
  })

  r.post('/notifications', json, async (req, res) => {
    if (!limiter.allow(`n:${clientIp(req)}`)) return void res.status(429).json({ error: 'rate limited' })
    const signed = typeof req.body?.signedPayload === 'string' ? req.body.signedPayload : ''
    const logReject = (error: string) =>
      db.query('INSERT INTO notification_events (verified, error, notification_type) VALUES (0, ?, ?)',
        [error.slice(0, 255), String(peekJws(signed)?.notificationType ?? '').slice(0, 48) || null]).catch(() => {})
    if (!signed) {
      await logReject('missing signedPayload')
      return void res.status(400).json({ error: 'signedPayload is required' })
    }
    let n
    try {
      n = await verifier.notification(signed)
    } catch (e) {
      await logReject(`verification failed: ${(e as Error).message || 'invalid'}`)
      return void res.status(401).json({ error: 'notification signature verification failed' })
    }
    const d = n.data
    const env = String(d?.environment ?? 'Production') as EnvName
    let tx = null, renewal = null
    try {
      if (d?.signedTransactionInfo) tx = await verifier.transaction(d.signedTransactionInfo)
      if (d?.signedRenewalInfo) renewal = await verifier.renewalInfo(d.signedRenewalInfo, env)
    } catch (e) {
      await logReject(`inner JWS verification failed: ${(e as Error).message}`)
      return void res.status(401).json({ error: 'inner JWS verification failed' })
    }
    const [ins]: any = await db.query(
      `INSERT IGNORE INTO notification_events (notification_uuid, notification_type, subtype, environment, original_transaction_id, transaction_id, product_id, signed_date, verified)
       VALUES (?,?,?,?,?,?,?,?,1)`,
      [n.notificationUUID ?? null, n.notificationType ?? null, n.subtype ?? null, env, tx?.originalTransactionId ?? null,
       tx?.transactionId ?? null, tx?.productId ?? null, toDate(n.signedDate)])
    if (ins.affectedRows === 0) return void res.json({ ok: true, duplicate: true })
    let result = null
    if (tx && d?.bundleId === cfg.bundleId) {
      result = await recordTransaction(db, cfg, tx, {
        source: 'notification', renewal, event: [n.notificationType, n.subtype].filter(Boolean).join(':'),
        notificationStatus: typeof d?.status === 'number' ? d.status : undefined,
      })
    }
    res.json({ ok: true, type: n.notificationType, result })
  })

  return r
}
