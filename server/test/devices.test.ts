import assert from 'node:assert/strict'
import { after, describe, it } from 'node:test'
import crypto from 'node:crypto'
import { apnsJwt, deadToken } from '../src/apns.ts'
import { loadConfig } from '../src/config.ts'
import { freshDb, INSTALL, post, startServer, TOKEN } from './helpers.ts'

const db = await freshDb()
const srv = await startServer(db)
after(async () => { await srv.close(); await db.end() })
const HEX = 'ab'.repeat(32)

describe('devices', () => {
  it('register then heartbeat keeps one row and updates fields', async () => {
    const a = await post(`${srv.url}/api/devices/register`, { installId: INSTALL, osVersion: '18.0', appVersion: '1.0', locale: 'en_US', timezone: 'America/Los_Angeles' })
    assert.equal(a.status, 200)
    await post(`${srv.url}/api/devices/register`, { installId: INSTALL, appVersion: '1.1', appAccountToken: TOKEN })
    const [rows]: any = await db.query('SELECT * FROM devices')
    assert.equal(rows.length, 1)
    assert.equal(rows[0].app_version, '1.1')
    assert.equal(rows[0].os_version, '18.0')
    assert.equal(rows[0].app_account_token, TOKEN)
  })
  it('rejects a missing/invalid installId', async () => {
    assert.equal((await post(`${srv.url}/api/devices/register`, { installId: 'nope' })).status, 400)
  })
})

describe('push tokens', () => {
  it('register, re-register (idempotent), unregister', async () => {
    assert.equal((await post(`${srv.url}/api/push/register`, { installId: INSTALL, token: HEX, environment: 'sandbox' })).status, 200)
    assert.equal((await post(`${srv.url}/api/push/register`, { installId: INSTALL, token: HEX, environment: 'sandbox' })).status, 200)
    let [rows]: any = await db.query('SELECT enabled, topic, environment FROM push_tokens')
    assert.equal(rows.length, 1)
    assert.equal(rows[0].topic, 'com.ragnus.pnge')
    const u: any = await (await post(`${srv.url}/api/push/unregister`, { installId: INSTALL, token: HEX })).json()
    assert.equal(u.disabled, 1);
    [rows] = await db.query('SELECT enabled FROM push_tokens') as any
    assert.equal(rows[0].enabled, 0)
  })
  it('validates token and environment', async () => {
    assert.equal((await post(`${srv.url}/api/push/register`, { installId: INSTALL, token: 'xyz', environment: 'sandbox' })).status, 400)
    assert.equal((await post(`${srv.url}/api/push/register`, { installId: INSTALL, token: HEX, environment: 'dev' })).status, 400)
  })
})

describe('apns', () => {
  it('builds an ES256 JWT that verifies with the key', () => {
    const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' })
    const cfg = loadConfig()
    cfg.apns = { ...cfg.apns, keyId: 'KEY123', teamId: 'TEAM123', privateKey: privateKey.export({ type: 'pkcs8', format: 'pem' }) as string }
    const [h, p, s] = apnsJwt(cfg, 1700000000).split('.')
    assert.deepEqual(JSON.parse(Buffer.from(h!, 'base64url').toString()), { alg: 'ES256', kid: 'KEY123' })
    assert.deepEqual(JSON.parse(Buffer.from(p!, 'base64url').toString()), { iss: 'TEAM123', iat: 1700000000 })
    assert.ok(crypto.verify('sha256', Buffer.from(`${h}.${p}`), { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(s!, 'base64url')))
  })
  it('dead token detection', () => {
    assert.equal(deadToken({ status: 410, apnsId: null, reason: 'Unregistered' }), true)
    assert.equal(deadToken({ status: 400, apnsId: null, reason: 'BadDeviceToken' }), true)
    assert.equal(deadToken({ status: 429, apnsId: null, reason: 'TooManyRequests' }), false)
  })
})
