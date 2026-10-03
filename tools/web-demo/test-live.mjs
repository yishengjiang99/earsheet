// Live (microphone) streaming test: Chrome's fake capture device plays a WAV as the
// mic; we press Record, sample how many notes are on screen while it plays, press
// Stop, then compare the final notes with the expected ones.
// Usage: node test-live.mjs [--url=https://grepawk.com/music-hear/] [--backend=wasm]
//        [--cases=c-major-triad,twinkle-melody,two-hands,ode-to-joy] [--shot=mid.png] [--json=out.json]
import { createServer } from 'node:http';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join, dirname, extname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright-core';

const here = dirname(fileURLToPath(import.meta.url));
const web = join(here, '..', '..', 'web');
const args = Object.fromEntries(process.argv.slice(2).map((a) => a.replace(/^--/, '').split(/=(.*)/s).slice(0, 2)));
const chrome = args.chrome || '/usr/bin/google-chrome';
const backend = args.backend || 'wasm';
const fixtures = join(here, 'fixtures');
const SR = 44100;

function render(events, seconds) {
  const n = Math.floor(seconds * SR), x = new Float32Array(n);
  for (const [midi, t0, len] of events) {
    const f = 440 * 2 ** ((midi - 69) / 12);
    for (let i = Math.floor(t0 * SR); i < Math.min(n, Math.floor((t0 + len) * SR)); i++) {
      const t = i / SR - t0;
      const env = Math.min(1, t / 0.005) * Math.exp(-0.8 * t) * Math.min(1, (len - t) / 0.02);
      let s = 0;
      for (let h = 1; h <= 6; h++) s += Math.sin(2 * Math.PI * f * h * t) * Math.exp(-1.1 * (h - 1)) * Math.exp(-0.5 * h * t);
      x[i] += 0.12 * env * s;
    }
  }
  const buf = Buffer.alloc(44 + n * 2);
  buf.write('RIFF', 0); buf.writeUInt32LE(36 + n * 2, 4); buf.write('WAVEfmt ', 8);
  buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20); buf.writeUInt16LE(1, 22); buf.writeUInt32LE(SR, 24);
  buf.writeUInt32LE(SR * 2, 28); buf.writeUInt16LE(2, 32); buf.writeUInt16LE(16, 34); buf.write('data', 36); buf.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) buf.writeInt16LE(Math.round(Math.max(-1, Math.min(1, x[i])) * 32767), 44 + i * 2);
  return buf;
}

// Leading 1 s of silence in each file so capture start-up never clips the first note.
const L = 1.0;
const ODE = [64, 64, 65, 67, 67, 65, 64, 62, 60, 60, 62, 64, 64, 62, 62];
const CASES = {
  'c-major-triad': { events: [[60, L + 0.5, 2.0], [64, L + 0.5, 2.0], [67, L + 0.5, 2.0]], seconds: L + 3.5 },
  'twinkle-melody': { events: [60, 60, 67, 67, 69, 69, 67].map((m, i) => [m, L + 0.3 + i * 0.5, i === 6 ? 0.95 : 0.45]), seconds: L + 5 },
  'two-hands': { events: [[48, 0.3, 1.9], [64, 0.3, 0.45], [67, 0.8, 0.45], [72, 1.3, 0.45], [67, 1.8, 0.45], [43, 2.3, 1.9], [62, 2.3, 0.45], [65, 2.8, 0.45], [71, 3.3, 0.9]].map(([m, t, d]) => [m, L + t, d]), seconds: L + 5 },
  'ode-to-joy': {
    events: [
      ...ODE.map((m, i) => [m, L + 0.3 + i * 0.5, i === 14 ? 0.95 : 0.45]),
      ...[48, 43, 48, 43, 48, 43, 48, 43].map((m, i) => [m, L + 0.3 + i * 1.0, 0.9]),
    ].sort((a, b) => a[1] - b[1]),
    seconds: L + 8.5,
  },
};
const cases = (args.cases || Object.keys(CASES).join(',')).split(',');

function score(expected, got) {
  // The fake mic starts a little before the worklet runs, so find the constant offset
  // (detected - expected) that matches the most notes, then match within 80 ms.
  const cands = [];
  for (const [m, t] of expected) for (const g of got) if (g.midi === m) cands.push(g.onset - t);
  let best = { tp: -1 };
  for (const d of cands.length ? cands : [0]) {
    const used = new Set(); let tp = 0; const missed = [];
    for (const [m, t0] of expected) {
      const j = got.findIndex((g, k) => !used.has(k) && g.midi === m && Math.abs(g.onset - d - t0) < 0.08);
      if (j >= 0) { used.add(j); tp++; } else missed.push(m);
    }
    if (tp > best.tp) best = { tp, d, missed, extra: got.filter((_, k) => !used.has(k)).map((g) => `${g.name}@${(g.onset - d).toFixed(2)}`) };
  }
  return { tp: best.tp, expected: expected.length, detected: got.length, offset: +best.d.toFixed(3), missed: best.missed, extra: best.extra };
}

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.wasm': 'application/wasm', '.bin': 'application/octet-stream' };
const server = createServer(async (req, res) => {
  let p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  if (!p.startsWith('/earsheet/')) { res.writeHead(404).end(); return; }
  p = p.slice('/earsheet/'.length) || 'index.html';
  try { res.writeHead(200, { 'content-type': MIME[extname(p)] || 'application/octet-stream' }).end(await readFile(join(web, p))); }
  catch { res.writeHead(404).end(); }
}).listen(0);
const base = args.url || `http://127.0.0.1:${server.address().port}/earsheet/`;
await mkdir(fixtures, { recursive: true });

const report = [];
let failed = 0;
for (const name of cases) {
  const c = CASES[name];
  const wav = join(fixtures, `live-${name}.wav`);
  if (!existsSync(wav)) await writeFile(wav, render(c.events, c.seconds));
  const browser = await chromium.launch({
    executablePath: chrome, headless: true,
    args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', `--use-file-for-fake-audio-capture=${wav}%noloop`,
      '--autoplay-policy=no-user-gesture-required', '--enable-unsafe-webgpu', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'],
  });
  const page = await browser.newPage({ viewport: { width: 1100, height: 1300 } });
  const logs = [];
  page.on('console', (m) => logs.push(`[${m.type()}] ${m.text()}`));
  page.on('pageerror', (e) => logs.push(`[pageerror] ${e.message}`));
  await page.goto(`${base}?backend=${backend}`);
  await page.waitForFunction(() => window.__earsheet && (window.__earsheet.ready || window.__earsheet.error), null, { timeout: 120000 });
  await page.click('#rec-btn');
  const samples = [];
  const t0 = Date.now();
  let shot = false;
  while ((Date.now() - t0) / 1000 < c.seconds + 0.8) {
    await page.waitForTimeout(100);
    const s = await page.evaluate(() => ({ live: !!window.__earsheet.live, n: window.__earsheet.notes.length, frames: window.__earsheet.F.length }));
    samples.push({ t: +((Date.now() - t0) / 1000).toFixed(1), ...s });
    if (args.shot && !shot && name === (args.shotCase || 'ode-to-joy') && (Date.now() - t0) / 1000 > c.seconds * 0.6) {
      shot = true; await page.screenshot({ path: args.shot, fullPage: true });
    }
  }
  const duringNotes = samples.filter((s) => s.live).map((s) => s.n);
  const distinctCounts = [...new Set(duringNotes)];
  await page.click('#rec-btn');
  await page.waitForFunction(() => window.__earsheet.lastResult && window.__earsheet.lastResult.mode === 'live', null, { timeout: 120000 });
  const r = await page.evaluate(() => ({ ...window.__earsheet.lastResult, latencies: window.__earsheet.latencies }));
  const sc = score(c.events.map(([m, t]) => [m, t]), r.notes);
  // Latency per expected note: first time it was shown minus its true onset (in capture time).
  const lat = [];
  for (const l of r.latencies) {
    if (c.events.some(([m, t]) => m === l.midi && Math.abs(l.onset - sc.offset - t) < 0.08)) lat.push(l.latency);
  }
  lat.sort((a, b) => a - b);
  // Notes must be on screen before Stop; with several onsets the count must grow in steps.
  const onsetsDistinct = new Set(c.events.map(([, t]) => t.toFixed(2))).size;
  const incremental = duringNotes[duringNotes.length - 1] > 0 && (onsetsDistinct < 3 || distinctCounts.length >= 3);
  // Pass: every expected note found; extras (overtone ghosts of this synthetic timbre) capped.
  const ok = sc.tp === sc.expected && sc.extra.length <= Math.max(2, Math.ceil(0.4 * sc.expected)) && incremental;
  if (!ok) failed++;
  const row = {
    case: name, backend: r.backend, ok, incremental, liveCounts: distinctCounts.join('→'), ...sc,
    windows: r.inference.windows, msPerWindow: Math.round(r.inference.msPerWindow),
    latency: lat.length ? { n: lat.length, min: +lat[0].toFixed(2), median: +lat[Math.floor(lat.length / 2)].toFixed(2), max: +lat[lat.length - 1].toFixed(2) } : null,
    notes: r.notes.map((n) => `${n.name}@${(n.onset - sc.offset).toFixed(2)}`).join(' '),
  };
  report.push(row);
  console.log(JSON.stringify(row));
  const errs = logs.filter((l) => /error/i.test(l));
  if (errs.length) console.log('console errors:', errs.slice(0, 5));
  if (args.finalShot && name === (args.shotCase || 'ode-to-joy')) await page.screenshot({ path: args.finalShot, fullPage: true });
  await browser.close();
}
server.close();
if (args.json) await writeFile(args.json, JSON.stringify(report, null, 2));
console.log(failed ? `FAILED: ${failed}` : 'ALL PASSED');
process.exit(failed ? 1 : 0);
