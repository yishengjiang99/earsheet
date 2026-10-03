import assert from 'node:assert/strict'
import { after, before, describe, it } from 'node:test'
import { loadConfig } from '../src/config.ts'
import { createAppleVerifier } from '../src/apple.ts'
import { computeStatus } from '../src/subscriptions.ts'
import { badJws, DAY, freshDb, jws, post, startServer, TOKEN, tx } from './helpers.ts'

const db = await freshDb()
const srv = await startServer(db, { basePath: '/music-radar' })
after(async () => { await srv.close(); await db.end() })
const ent = async () => (await (await fetch(`${srv.url}/api/iap/entitlement?appAccountToken=${TOKEN}`)).json()) as any

describe('health + migrations', () => {
  it('health is 200 with db ok', async () => {
    const r = await fetch(`${srv.url}/api/health`)
    assert.equal(r.status, 200)
    const j: any = await r.json()
    assert.equal(j.db, true)
    assert.equal(j.bundleId, 'com.ragnus.pnge')
  })
  it('re-running migrations is a no-op', async () => {
    const { migrate } = await import('../src/db.ts')
    assert.deepEqual(await migrate(db), [])
  })
  it('unknown routes 404', async () => assert.equal((await fetch(`${srv.url}/api/nope`)).status, 404))
})

describe('computeStatus', () => {
  const now = Date.now()
  it('trial / active / expired / grace / revoked', () => {
    assert.equal(computeStatus(tx() as any, 'subscription', null, now), 'trial')
    assert.equal(computeStatus(tx({ offerType: null, offerDiscountType: null }) as any, 'subscription', null, now), 'active')
    assert.equal(computeStatus(tx({ expiresDate: now - 1 }) as any, 'subscription', null, now), 'expired')
    assert.equal(computeStatus(tx({ expiresDate: now - 1 }) as any, 'subscription', { gracePeriodExpiresDate: now + DAY } as any, now), 'grace')
    assert.equal(computeStatus(tx({ expiresDate: now - 1 }) as any, 'subscription', { isInBillingRetryPeriod: true } as any, now), 'billing_retry')
    assert.equal(computeStatus(tx({ revocationDate: now }) as any, 'subscription', null, now), 'revoked')
    assert.equal(computeStatus(tx({ expiresDate: undefined }) as any, 'lifetime', null, now), 'active')
    assert.equal(computeStatus(tx() as any, 'subscription', null, now, 5), 'revoked')
  })
})

describe('verify + entitlement', () => {
  it('free user has no entitlement', async () => assert.equal((await ent()).pro, false))
  it('rejects missing / bad-signature / wrong bundle / unknown product / token mismatch', async () => {
    assert.equal((await post(`${srv.url}/api/iap/verify`, {})).status, 400)
    assert.equal((await post(`${srv.url}/api/iap/verify`, { signedTransaction: badJws(tx()) })).status, 400)
    const wrongBundle: any = await (await post(`${srv.url}/api/iap/verify`, { signedTransaction: jws(tx({ bundleId: 'com.other' })) })).json()
    assert.match(wrongBundle.error, /bundleId/)
    const unknown: any = await (await post(`${srv.url}/api/iap/verify`, { signedTransaction: jws(tx({ productId: 'com.ragnus.pnge.nope' })) })).json()
    assert.match(unknown.error, /unknown productId/)
    const mism = await post(`${srv.url}/api/iap/verify`, { signedTransaction: jws(tx()), appAccountToken: '11111111-1111-4111-8111-111111111111' })
    assert.equal(mism.status, 400)
  })
  it('monthly free trial unlocks Pro (trial)', async () => {
    const r = await post(`${srv.url}/api/iap/verify`, { signedTransaction: jws(tx()), appAccountToken: TOKEN })
    assert.equal(r.status, 200)
    const j: any = await r.json()
    assert.equal(j.transaction.status, 'trial')
    assert.equal(j.entitlement.pro, true)
    assert.equal(j.entitlement.status, 'trial')
  })
  it('replaying the same transaction is idempotent', async () => {
    await post(`${srv.url}/api/iap/verify`, { signedTransaction: jws(tx()), appAccountToken: TOKEN })
    const [rows]: any = await db.query('SELECT COUNT(*) n FROM iap_transactions')
    assert.equal(rows[0].n, 1)
  })
  it('restore with lifetime gives lifetime plan', async () => {
    const life = tx({ transactionId: '3000000000000001', originalTransactionId: '3000000000000001', productId: 'com.ragnus.pnge.lifetime',
      type: 'Non-Consumable', expiresDate: undefined, offerType: undefined, offerDiscountType: undefined, price: 49990 })
    const r: any = await (await post(`${srv.url}/api/iap/restore`, { signedTransactions: [jws(life)], appAccountToken: TOKEN })).json()
    assert.equal(r.results[0].ok, true)
    assert.equal(r.entitlement.plan, 'lifetime')
    assert.equal(r.entitlement.expiresAt, null)
  })
  it('restore requires appAccountToken', async () => assert.equal((await post(`${srv.url}/api/iap/restore`, { signedTransactions: [] })).status, 400))
  it('products lists the catalog', async () => {
    const j: any = await (await fetch(`${srv.url}/api/iap/products`)).json()
    assert.deepEqual(j.products.map((p: any) => p.id), ['com.ragnus.pnge.pro.monthly', 'com.ragnus.pnge.pro.yearly', 'com.ragnus.pnge.lifetime'])
  })
})

describe('ASSN v2 webhook', () => {
  const note = (type: string, t: object, extra: object = {}, uuid = crypto.randomUUID()) => ({
    signedPayload: jws({ notificationType: type, notificationUUID: uuid, signedDate: Date.now(),
      data: { environment: 'Sandbox', bundleId: 'com.ragnus.pnge', appAppleId: 6818838017, signedTransactionInfo: jws(t), ...extra } }),
  })
  it('DID_RENEW moves the trial to a paid period with a new expiry', async () => {
    const renew = tx({ transactionId: '2000000000000002', purchaseDate: Date.now(), expiresDate: Date.now() + 30 * DAY, offerType: null, offerDiscountType: null, price: 4990 })
    const r = await post(`${srv.url}/api/iap/notifications`, note('DID_RENEW', renew, { signedRenewalInfo: jws({ autoRenewStatus: 1, autoRenewProductId: 'com.ragnus.pnge.pro.monthly' }), status: 1 }))
    assert.equal(r.status, 200)
    const [s]: any = await db.query("SELECT status, auto_renew, last_transaction_id FROM subscriptions WHERE original_transaction_id='2000000000000001'")
    assert.equal(s[0].status, 'active')
    assert.equal(s[0].auto_renew, 1)
    assert.equal(s[0].last_transaction_id, '2000000000000002')
  })
  it('an older replayed transaction does not roll the state back', async () => {
    await post(`${srv.url}/api/iap/notifications`, note('SUBSCRIBED', tx(), { status: 1 }))
    const [s]: any = await db.query("SELECT last_transaction_id FROM subscriptions WHERE original_transaction_id='2000000000000001'")
    assert.equal(s[0].last_transaction_id, '2000000000000002')
  })
  it('duplicate notificationUUID is acknowledged but not re-applied', async () => {
    const id = crypto.randomUUID()
    const body = note('DID_CHANGE_RENEWAL_STATUS', tx({ transactionId: '2000000000000002', purchaseDate: Date.now(), expiresDate: Date.now() + 30 * DAY }),
      { signedRenewalInfo: jws({ autoRenewStatus: 0 }) }, id)
    assert.equal((await post(`${srv.url}/api/iap/notifications`, body)).status, 200)
    const dup: any = await (await post(`${srv.url}/api/iap/notifications`, body)).json()
    assert.equal(dup.duplicate, true)
    const [s]: any = await db.query("SELECT auto_renew FROM subscriptions WHERE original_transaction_id='2000000000000001'")
    assert.equal(s[0].auto_renew, 0)
  })
  it('REFUND of the lifetime purchase revokes it; monthly still entitles', async () => {
    const life = tx({ transactionId: '3000000000000001', originalTransactionId: '3000000000000001', productId: 'com.ragnus.pnge.lifetime',
      type: 'Non-Consumable', expiresDate: undefined, offerType: undefined, offerDiscountType: undefined, revocationDate: Date.now(), revocationReason: 0 })
    assert.equal((await post(`${srv.url}/api/iap/notifications`, note('REFUND', life))).status, 200)
    const e = await ent()
    assert.equal(e.pro, true)
    assert.equal(e.plan, 'com.ragnus.pnge.pro.monthly')
    assert.equal(e.items.find((i: any) => i.kind === 'lifetime').status, 'revoked')
  })
  it('EXPIRED ends Pro', async () => {
    const exp = tx({ transactionId: '2000000000000003', purchaseDate: Date.now() + 1, expiresDate: Date.now() - 1000, offerType: null, offerDiscountType: null })
    await post(`${srv.url}/api/iap/notifications`, note('EXPIRED', exp, { status: 2 }))
    assert.equal((await ent()).pro, false)
  })
  it('fake-verifier rejects a bad signature with 401 and logs it', async () => {
    const r = await post(`${srv.url}/api/iap/notifications`, { signedPayload: badJws({ notificationType: 'TEST' }) })
    assert.equal(r.status, 401)
    const [rows]: any = await db.query('SELECT COUNT(*) n FROM notification_events WHERE verified=0')
    assert.ok(rows[0].n >= 1)
  })
  it('the real Apple verifier rejects unsigned payloads', async () => {
    const real = await startServer(db, { basePath: '' }, createAppleVerifier(loadConfig()))
    try {
      const r = await post(`${real.url}/api/iap/notifications`, note('TEST', tx()))
      assert.equal(r.status, 401)
      const v = await post(`${real.url}/api/iap/verify`, { signedTransaction: jws(tx()) })
      assert.equal(v.status, 400)
      assert.equal((await post(`${real.url}/api/iap/notifications`, {})).status, 400)
    } finally { await real.close() }
  })
})
