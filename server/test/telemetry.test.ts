import assert from 'node:assert/strict'
import { after, describe, it } from 'node:test'
import { loadConfig } from '../src/config.ts'
import { parseTs, scrubProperties } from '../src/telemetry.ts'
import { freshDb, INSTALL, post, startServer } from './helpers.ts'

const db = await freshDb()
const base = loadConfig()
const srv = await startServer(db, { telemetry: { ...base.telemetry, maxBatch: 5, ratePerMinute: 4, maxBodyBytes: 4096 } })
after(async () => { await srv.close(); await db.end() })
const SESSION = '0b6e2a7c-1d3f-4e5a-9b8c-7d6e5f4a3b2c'
const ev = (name: string, props: object = {}) => ({ name, ts: new Date().toISOString(), installId: INSTALL, sessionId: SESSION, appVersion: '1.0', properties: props })

describe('scrubbing', () => {
  it('drops PII keys/values and non-scalars', () => {
    const p = scrubProperties({ email: 'a@b.co', note: 'x@y.com', userName: 'bob', duration_ms: 1200, notes: 23, nested: { a: 1 }, audio: 'abc', ok: true }, 2048)
    assert.deepEqual(p, { duration_ms: 1200, notes: 23, ok: true })
  })
  it('timestamps: rejects far future/past, accepts seconds and ms', () => {
    const now = Date.now()
    assert.equal(parseTs(now + 2 * 3600_000, now), null)
    assert.equal(parseTs(now - 40 * 86400_000, now), null)
    assert.ok(parseTs(Math.floor(now / 1000), now))
    assert.ok(parseTs(new Date(now).toISOString(), now))
  })
})

describe('batch ingest', () => {
  it('accepts valid events, drops invalid ones, strips PII', async () => {
    const r: any = await (await post(`${srv.url}/api/telemetry/batch`, { events: [ev('app_open'), ev('transcription_stop', { duration_ms: 5000, email: 'x@y.z' }), { name: 'Bad Name', installId: INSTALL, ts: Date.now() }] })).json()
    assert.equal(r.accepted, 2)
    assert.equal(r.dropped, 1)
    const [rows]: any = await db.query("SELECT properties FROM telemetry_events WHERE name='transcription_stop'")
    const props = typeof rows[0].properties === 'string' ? JSON.parse(rows[0].properties) : rows[0].properties
    assert.deepEqual(props, { duration_ms: 5000 })
  })
  it('bare arrays work too', async () => {
    const r: any = await (await post(`${srv.url}/api/telemetry/batch`, [ev('session_start')])).json()
    assert.equal(r.accepted, 1)
  })
  it('enforces batch size and body size', async () => {
    assert.equal((await post(`${srv.url}/api/telemetry/batch`, { events: Array.from({ length: 6 }, () => ev('x_event')) })).status, 413)
    assert.equal((await post(`${srv.url}/api/telemetry/batch`, { events: [ev('big', { s: 'a'.repeat(5000) })] })).status, 413)
    assert.equal((await post(`${srv.url}/api/telemetry/batch`, { events: [] })).status, 400)
  })
  it('rate limits per minute', async () => {
    let last = 200
    for (let i = 0; i < 6; i++) last = (await post(`${srv.url}/api/telemetry/batch`, [ev('spam')])).status
    assert.equal(last, 429)
  })
})
