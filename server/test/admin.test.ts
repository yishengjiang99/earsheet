import assert from 'node:assert/strict'
import { after, describe, it } from 'node:test'
import { freshDb, INSTALL, post, sent, startServer } from './helpers.ts'

const db = await freshDb()
const srv = await startServer(db, { basePath: '/music-radar' })
after(async () => { await srv.close(); await db.end() })
const origin = new URL(srv.url).origin
const form = (path: string, body: Record<string, string>, cookie = '', o = origin) =>
  fetch(`${srv.url}/admin${path}`, { method: 'POST', redirect: 'manual', headers: { 'content-type': 'application/x-www-form-urlencoded', origin: o, cookie }, body: new URLSearchParams(body) })
let cookie = ''

describe('admin auth', () => {
  it('redirects to login when signed out', async () => {
    const r = await fetch(`${srv.url}/admin`, { redirect: 'manual' })
    assert.equal(r.status, 303)
    assert.equal(r.headers.get('location'), '/music-radar/admin/login')
  })
  it('rejects a wrong password and a cross-origin login', async () => {
    const r = await form('/login', { password: 'nope' })
    assert.match(r.headers.get('location')!, /e=1/)
    assert.equal((await form('/login', { password: 'test-admin-pw' }, '', 'https://evil.example')).status, 403)
  })
  it('logs in with the right password', async () => {
    const r = await form('/login', { password: 'test-admin-pw' })
    assert.equal(r.status, 303)
    const set = r.headers.get('set-cookie')!
    assert.match(set, /HttpOnly/i)
    assert.match(set, /SameSite=Strict/i)
    assert.match(set, /Path=\/music-radar\/admin/)
    cookie = set.split(';')[0]!
  })
  it('a forged cookie is rejected', async () => {
    const r = await fetch(`${srv.url}/admin`, { redirect: 'manual', headers: { cookie: `mr_admin=${Date.now() + 1e9}.forged` } })
    assert.equal(r.status, 303)
  })
})

describe('admin views', () => {
  it('all pages render; device fields are HTML-escaped', async () => {
    await post(`${srv.url}/api/devices/register`, { installId: INSTALL, deviceModel: '<a href=x>pwn</a><script>alert(1)</script>' })
    await post(`${srv.url}/api/telemetry/batch`, [{ name: 'app_open', ts: Date.now(), installId: INSTALL, properties: { screen: '<img src=x onerror=alert(1)>' } }])
    for (const p of ['', '/devices', `/devices/${INSTALL}`, '/push', '/subscriptions', '/subscriptions?env=Sandbox', '/notifications', '/telemetry?days=7']) {
      const r = await fetch(`${srv.url}/admin${p}`, { headers: { cookie } })
      assert.equal(r.status, 200, p)
      const html = await r.text()
      assert.ok(!html.includes('<script>alert(1)'), p)
      assert.ok(!html.includes('<img src=x'), p)
      assert.ok(!html.includes('<a href=x>'), p)
    }
  })
  it('test push sends via APNs and disables dead tokens', async () => {
    await post(`${srv.url}/api/push/register`, { installId: INSTALL, token: 'ab'.repeat(32), environment: 'sandbox' })
    const [[t]]: any = await db.query('SELECT id FROM push_tokens LIMIT 1')
    const r = await form('/push/test', { tokenId: String(t.id), title: 'Hi', body: 'There' }, cookie)
    assert.equal(r.status, 303)
    assert.match(decodeURIComponent(r.headers.get('location')!), /200 OK/)
    assert.equal(sent.at(-1)!.payload.aps.alert.title, 'Hi')
    await db.query("UPDATE push_tokens SET token=? WHERE id=?", ['dead' + 'ab'.repeat(30), t.id])
    await form('/push/test', { tokenId: String(t.id) }, cookie)
    const [[row]]: any = await db.query('SELECT enabled, last_error FROM push_tokens WHERE id=?', [t.id])
    assert.equal(row.enabled, 0)
    assert.match(row.last_error, /410/)
  })
  it('POST without same-origin is refused even when logged in', async () => {
    assert.equal((await form('/push/test', { tokenId: '1' }, cookie, 'https://evil.example')).status, 403)
  })
})
