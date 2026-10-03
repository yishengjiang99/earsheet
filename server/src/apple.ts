/**
 * StoreKit 2 / ASSN v2 signature verification with Apple's root CA (offline x5c chain check,
 * via @apple/app-store-server-library SignedDataVerifier). One verifier per environment.
 * Injectable for tests (AppleVerifier interface).
 */
import fs from 'node:fs'
import path from 'node:path'
import {
  Environment,
  SignedDataVerifier,
  type JWSRenewalInfoDecodedPayload,
  type JWSTransactionDecodedPayload,
  type ResponseBodyV2DecodedPayload,
} from '@apple/app-store-server-library'
import type { Config } from './config.ts'

export type EnvName = 'Production' | 'Sandbox' | 'Xcode' | 'LocalTesting'

export interface AppleVerifier {
  transaction(jws: string): Promise<JWSTransactionDecodedPayload>
  renewalInfo(jws: string, env: EnvName): Promise<JWSRenewalInfoDecodedPayload>
  notification(signedPayload: string): Promise<ResponseBodyV2DecodedPayload>
}

/** Unverified peek at a JWS payload, used only to pick which environment's verifier to use. */
export function peekJws(jws: string): Record<string, any> | null {
  const parts = jws.split('.')
  if (parts.length !== 3) return null
  try {
    return JSON.parse(Buffer.from(parts[1]!, 'base64url').toString('utf8'))
  } catch {
    return null
  }
}

export function loadRootCerts(dir: string): Buffer[] {
  return fs.readdirSync(dir).filter((f) => /\.(cer|der)$/i.test(f)).map((f) => fs.readFileSync(path.join(dir, f)))
}

export function createAppleVerifier(cfg: Config): AppleVerifier {
  const roots = loadRootCerts(cfg.certDir)
  if (!roots.length) throw new Error(`no Apple root certificates in ${cfg.certDir}`)
  const online = cfg.production // OCSP revocation checks in production
  const verifiers: Record<string, SignedDataVerifier> = {
    Production: new SignedDataVerifier(roots, online, Environment.PRODUCTION, cfg.bundleId, cfg.appAppleId),
    Sandbox: new SignedDataVerifier(roots, online, Environment.SANDBOX, cfg.bundleId),
  }
  const pick = (env: unknown) => verifiers[env === 'Production' ? 'Production' : 'Sandbox']!
  return {
    transaction: (jws) => pick(peekJws(jws)?.environment).verifyAndDecodeTransaction(jws),
    renewalInfo: (jws, env) => pick(env).verifyAndDecodeRenewalInfo(jws),
    notification: (p) => pick(peekJws(p)?.data?.environment ?? peekJws(p)?.summary?.environment).verifyAndDecodeNotification(p),
  }
}
