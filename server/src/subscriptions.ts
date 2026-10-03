/** Transaction + subscription-state persistence shared by /iap/verify, /iap/restore and the ASSN v2 webhook. */
import type mysql from 'mysql2/promise'
import type { JWSRenewalInfoDecodedPayload, JWSTransactionDecodedPayload } from '@apple/app-store-server-library'
import type { Config } from './config.ts'
import type { Db } from './db.ts'
import { toDate } from './db.ts'
import { productById } from './products.ts'

export type SubStatus = 'active' | 'trial' | 'grace' | 'billing_retry' | 'expired' | 'revoked'
const ENTITLED: SubStatus[] = ['active', 'trial', 'grace']

/** ASSN v2 data.status: 1 active, 2 expired, 3 billing retry, 4 grace period, 5 revoked. */
const NOTIFICATION_STATUS: Record<number, SubStatus> = { 1: 'active', 2: 'expired', 3: 'billing_retry', 4: 'grace', 5: 'revoked' }

export function isFreeTrial(tx: JWSTransactionDecodedPayload): boolean {
  return Number(tx.offerType) === 1 && String(tx.offerDiscountType ?? '') === 'FREE_TRIAL'
}

export function computeStatus(
  tx: JWSTransactionDecodedPayload,
  kind: 'subscription' | 'lifetime',
  renewal: JWSRenewalInfoDecodedPayload | null,
  nowMs: number,
  notificationStatus?: number,
): SubStatus {
  if (tx.revocationDate != null) return 'revoked'
  if (kind === 'lifetime') return 'active'
  if (notificationStatus && NOTIFICATION_STATUS[notificationStatus]) {
    const s = NOTIFICATION_STATUS[notificationStatus]!
    return s === 'active' && isFreeTrial(tx) && (tx.expiresDate ?? 0) > nowMs ? 'trial' : s
  }
  if ((tx.expiresDate ?? 0) > nowMs) return isFreeTrial(tx) ? 'trial' : 'active'
  if (renewal?.gracePeriodExpiresDate && renewal.gracePeriodExpiresDate > nowMs) return 'grace'
  if (renewal?.isInBillingRetryPeriod) return 'billing_retry'
  return 'expired'
}

export type RecordResult = {
  ok: true
  productId: string
  originalTransactionId: string
  status: SubStatus
  expiresAt: string | null
  kind: 'subscription' | 'lifetime'
}

export async function recordTransaction(
  db: Db,
  cfg: Config,
  tx: JWSTransactionDecodedPayload,
  opts: { source: 'verify' | 'restore' | 'notification'; renewal?: JWSRenewalInfoDecodedPayload | null; event?: string; notificationStatus?: number; nowMs?: number; appAccountToken?: string | null },
): Promise<RecordResult | { ok: false; error: string }> {
  if (tx.bundleId !== cfg.bundleId) return { ok: false, error: `bundleId mismatch (expected ${cfg.bundleId})` }
  const product = productById(cfg, String(tx.productId ?? ''))
  if (!product) return { ok: false, error: `unknown productId ${tx.productId}` }
  if (!tx.transactionId || !tx.originalTransactionId) return { ok: false, error: 'transaction ids missing' }
  const nowMs = opts.nowMs ?? Date.now()
  const env = String(tx.environment ?? 'Production')
  const token = (tx.appAccountToken || opts.appAccountToken || null)?.toLowerCase() ?? null
  const status = computeStatus(tx, product.kind, opts.renewal ?? null, nowMs, opts.notificationStatus)

  const conn = await db.getConnection()
  try {
    await conn.beginTransaction()
    await conn.query(
      `INSERT INTO iap_transactions (transaction_id, original_transaction_id, product_id, product_type, app_account_token, environment,
         purchase_date, expires_date, offer_type, offer_discount_type, price_milli, currency, storefront, revocation_date, revocation_reason, ownership_type, source)
       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
       ON DUPLICATE KEY UPDATE expires_date=VALUES(expires_date), revocation_date=VALUES(revocation_date), revocation_reason=VALUES(revocation_reason),
         app_account_token=COALESCE(app_account_token, VALUES(app_account_token))`,
      [tx.transactionId, tx.originalTransactionId, product.id, String(tx.type ?? ''), token, env,
       toDate(tx.purchaseDate), toDate(tx.expiresDate), tx.offerType ?? null, tx.offerDiscountType ?? null,
       tx.price ?? null, tx.currency ?? null, tx.storefront ?? null, toDate(tx.revocationDate), tx.revocationReason ?? null,
       tx.inAppOwnershipType ?? null, opts.source],
    )
    const [rows] = await conn.query<mysql.RowDataPacket[]>(
      `SELECT s.last_transaction_id, t.purchase_date AS last_purchase FROM subscriptions s
         LEFT JOIN iap_transactions t ON t.transaction_id = s.last_transaction_id
        WHERE s.original_transaction_id = ? FOR UPDATE`, [tx.originalTransactionId])
    const existing = rows[0]
    const incomingPurchase = tx.purchaseDate ?? 0
    const newer = !existing || existing.last_transaction_id === tx.transactionId ||
      !existing.last_purchase || incomingPurchase >= new Date(existing.last_purchase).getTime()
    if (!existing) {
      await conn.query(
        `INSERT INTO subscriptions (original_transaction_id, product_id, kind, app_account_token, environment, status, expires_at,
           auto_renew, auto_renew_product_id, is_trial, is_intro, revoked_at, last_transaction_id, last_event, first_purchase_at)
         VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
        [tx.originalTransactionId, product.id, product.kind, token, env, status, toDate(tx.expiresDate),
         opts.renewal ? Number(opts.renewal.autoRenewStatus) === 1 : null, opts.renewal?.autoRenewProductId ?? null,
         isFreeTrial(tx), Number(tx.offerType) === 1, toDate(tx.revocationDate), tx.transactionId, opts.event ?? opts.source,
         toDate(tx.originalPurchaseDate ?? tx.purchaseDate)],
      )
    } else if (newer) {
      await conn.query(
        `UPDATE subscriptions SET product_id=?, status=?, expires_at=?, is_trial=?, is_intro=?, revoked_at=?, last_transaction_id=?, last_event=?,
           app_account_token=COALESCE(app_account_token, ?),
           auto_renew=COALESCE(?, auto_renew), auto_renew_product_id=COALESCE(?, auto_renew_product_id)
         WHERE original_transaction_id=?`,
        [product.id, status, toDate(tx.expiresDate), isFreeTrial(tx), Number(tx.offerType) === 1, toDate(tx.revocationDate),
         tx.transactionId, opts.event ?? opts.source, token,
         opts.renewal ? Number(opts.renewal.autoRenewStatus) === 1 : null, opts.renewal?.autoRenewProductId ?? null,
         tx.originalTransactionId],
      )
    } else if (opts.renewal) {
      // Older transaction (e.g. replayed notification): only refresh renewal preferences.
      await conn.query(`UPDATE subscriptions SET auto_renew=?, auto_renew_product_id=?, last_event=? WHERE original_transaction_id=?`,
        [Number(opts.renewal.autoRenewStatus) === 1, opts.renewal.autoRenewProductId ?? null, opts.event ?? opts.source, tx.originalTransactionId])
    }
    await conn.commit()
  } catch (e) {
    await conn.rollback()
    throw e
  } finally {
    conn.release()
  }
  const [cur] = await db.query<mysql.RowDataPacket[]>('SELECT status, expires_at FROM subscriptions WHERE original_transaction_id=?', [tx.originalTransactionId])
  return {
    ok: true,
    productId: product.id,
    originalTransactionId: tx.originalTransactionId,
    status: cur[0]!.status,
    expiresAt: cur[0]!.expires_at ? new Date(cur[0]!.expires_at).toISOString() : null,
    kind: product.kind,
  }
}

/** Pro entitlement for an appAccountToken. Status is re-evaluated against the clock (expired rows stay expired without a webhook). */
export async function entitlementFor(db: Db, token: string, nowMs = Date.now()) {
  const [rows] = await db.query<mysql.RowDataPacket[]>(
    `SELECT original_transaction_id, product_id, kind, environment, status, expires_at, auto_renew, is_trial
       FROM subscriptions WHERE app_account_token = ? ORDER BY updated_at DESC`, [token.toLowerCase()])
  const items = rows.map((r) => {
    let status = r.status as SubStatus
    const exp = r.expires_at ? new Date(r.expires_at).getTime() : null
    if (r.kind === 'subscription' && (status === 'active' || status === 'trial') && exp !== null && exp <= nowMs) status = 'expired'
    return {
      originalTransactionId: r.original_transaction_id as string,
      productId: r.product_id as string,
      kind: r.kind as string,
      environment: r.environment as string,
      status,
      expiresAt: exp ? new Date(exp).toISOString() : null,
      autoRenew: r.auto_renew == null ? null : Boolean(r.auto_renew),
      trial: Boolean(r.is_trial),
    }
  })
  const active = items.filter((i) => ENTITLED.includes(i.status))
  const best = active.find((i) => i.kind === 'lifetime') ?? active.sort((a, b) => (b.expiresAt ?? '').localeCompare(a.expiresAt ?? ''))[0]
  return {
    pro: Boolean(best),
    plan: best ? (best.kind === 'lifetime' ? 'lifetime' : best.productId) : 'free',
    status: best?.status ?? 'none',
    expiresAt: best?.kind === 'lifetime' ? null : best?.expiresAt ?? null,
    items,
  }
}
