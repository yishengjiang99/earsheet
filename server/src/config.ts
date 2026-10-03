/** Environment-driven config. Production values live in /etc/music-radar.env on grepawk.com. */
import fs from 'node:fs'

function env(name: string, fallback = ''): string {
  return process.env[name]?.trim() || fallback
}

export function normalizePem(raw: string): string {
  let k = raw.trim()
  if ((k.startsWith('"') && k.endsWith('"')) || (k.startsWith("'") && k.endsWith("'"))) k = k.slice(1, -1)
  return k.replace(/\\n/g, '\n')
}

function readKey(pathVar: string, inlineVar: string): string {
  const p = env(pathVar)
  if (p) {
    try { return fs.readFileSync(p, 'utf8') } catch { return '' }
  }
  return normalizePem(env(inlineVar))
}

export type Config = ReturnType<typeof loadConfig>

export function loadConfig() {
  return {
    port: Number(env('PORT', '8790')),
    basePath: env('BASE_PATH', '').replace(/\/+$/, ''),
    production: env('NODE_ENV') === 'production',
    bundleId: env('APPLE_BUNDLE_ID', 'com.ragnus.pnge'),
    appAppleId: Number(env('APPLE_APP_APPLE_ID', '6818838017')),
    products: {
      monthly: env('IAP_PRODUCT_MONTHLY', 'com.ragnus.pnge.pro.monthly'),
      yearly: env('IAP_PRODUCT_YEARLY', 'com.ragnus.pnge.pro.yearly'),
      lifetime: env('IAP_PRODUCT_LIFETIME', 'com.ragnus.pnge.lifetime'),
    },
    // App Store Server API (optional: used to refresh status; verification itself is offline JWS)
    asc: {
      issuerId: env('APPLE_IAP_ISSUER_ID'),
      keyId: env('APPLE_IAP_KEY_ID'),
      privateKey: readKey('APPLE_IAP_P8_PATH', 'APPLE_IAP_PRIVATE_KEY'),
    },
    apns: {
      keyId: env('APNS_KEY_ID'),
      teamId: env('APNS_TEAM_ID'),
      privateKey: readKey('APNS_P8_PATH', 'APNS_P8_CONTENTS'),
      topic: env('APNS_TOPIC', env('APPLE_BUNDLE_ID', 'com.ragnus.pnge')),
    },
    certDir: env('APPLE_ROOT_CERT_DIR', new URL('../certs/', import.meta.url).pathname),
    adminPassword: env('ADMIN_PASSWORD'),
    sessionSecret: env('SESSION_SECRET'),
    telemetry: {
      maxBatch: Number(env('TELEMETRY_MAX_BATCH', '100')),
      maxBodyBytes: Number(env('TELEMETRY_MAX_BODY_BYTES', String(128 * 1024))),
      maxPropsBytes: Number(env('TELEMETRY_MAX_PROPS_BYTES', '2048')),
      ratePerMinute: Number(env('TELEMETRY_RATE_PER_MINUTE', '30')),
    },
  }
}
