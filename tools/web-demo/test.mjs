// Headless end-to-end test of web/: serves it under /earsheet/ (like GitHub Pages),
// feeds generated WAVs through the file input on each backend, and checks the notes.
// Usage: node test.mjs [--backends=auto,webgl,wasm] [--chrome=/usr/bin/google-chrome] [--shot=path.png]
import { createServer } from 'node:http';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join, dirname, extname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright-core';

const here = dirname(fileURLToPath(import.meta.url));
const web = join(here, '..', '..', 'web');
const args = Object.fromEntries(process.argv.slice(2).map((a) => a.replace(/^--/, '').split('=')));
const backends = (args.backends || 'auto,webgpu,webgl,wasm').split(',');
const chrome = args.chrome || '/usr/bin/google-chrome';
const fixtures = args.fixtures || join(here, 'fixtures');
const SR = 44100;

// ---- fixtures: simple piano-ish additive synth at 44.1 kHz stereo (exercises resampling + downmix)
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
  const buf = Buffer.alloc(44 + n * 4);
  buf.write('RIFF', 0); buf.writeUInt32LE(36 + n * 4, 4); buf.write('WAVEfmt ', 8);
  buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20); buf.writeUInt16LE(2, 22); buf.writeUInt32LE(SR, 24);
  buf.writeUInt32LE(SR * 4, 28); buf.writeUInt16LE(4, 32); buf.writeUInt16LE(16, 34); buf.write('data', 36); buf.writeUInt32LE(n * 4, 40);
  for (let i = 0; i < n; i++) { const v = Math.round(Math.max(-1, Math.min(1, x[i])) * 32767); buf.writeInt16LE(v, 44 + i * 4); buf.writeInt16LE(v, 46 + i * 4); }
  return buf;
}
const CASES = {
  'c-major-triad': { events: [[60, 0.5, 2.0], [64, 0.5, 2.0], [67, 0.5, 2.0]], seconds: 3 },
  'twinkle-melody': { events: [60, 60, 67, 67, 69, 69, 67].map((m, i) => [m, 0.3 + i * 0.5, i === 6 ? 0.95 : 0.45]), seconds: 4.5 },
  'two-hands': { events: [[48, 0.3, 1.9], [64, 0.3, 0.45], [67, 0.8, 0.45], [72, 1.3, 0.45], [67, 1.8, 0.45], [43, 2.3, 1.9], [62, 2.3, 0.45], [65, 2.8, 0.45], [71, 3.3, 0.9]], seconds: 4.8 },
};

function score(expected, got) {
  // Greedy match: same pitch, onset within 80 ms.
  const used = new Set(); let tp = 0; const missed = [];
  for (const [m, t0] of expected) {
    const j = got.findIndex((g, k) => !used.has(k) && g.midi === m && Math.abs(g.onset - t0) < 0.08);
    if (j >= 0) { used.add(j); tp++; } else missed.push(m);
  }
  const extra = got.filter((_, k) => !used.has(k)).map((g) => `${g.name}@${g.onset}`);
  return { tp, expected: expected.length, detected: got.length, missed, extra };
}

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.wasm': 'application/wasm', '.bin': 'application/octet-stream' };
const server = createServer(async (req, res) => {
  let p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  if (!p.startsWith('/earsheet/')) { res.writeHead(404).end(); return; }
  p = p.slice('/earsheet/'.length) || 'index.html';
  if (p.endsWith('/')) p += 'index.html';
  try { const b = await readFile(join(web, p)); res.writeHead(200, { 'content-type': MIME[extname(p)] || 'application/octet-stream' }).end(b); }
  catch { res.writeHead(404).end(); }
}).listen(0);
const base = `http://127.0.0.1:${server.address().port}/earsheet/`;

await mkdir(fixtures, { recursive: true });
const files = {};
for (const [name, c] of Object.entries(CASES)) {
  files[name] = join(fixtures, `${name}.wav`);
  if (!existsSync(files[name])) await writeFile(files[name], render(c.events, c.seconds));
}

const browser = await chromium.launch({
  executablePath: chrome, headless: true,
  args: ['--enable-unsafe-webgpu', '--enable-features=Vulkan,WebGPU', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'],
});
const report = [];
let failed = 0;
for (const backend of backends) {
  const page = await browser.newPage({ viewport: { width: 1100, height: 1400 } });
  const logs = [];
  page.on('console', (m) => logs.push(`[${m.type()}] ${m.text()}`));
  page.on('pageerror', (e) => logs.push(`[pageerror] ${e.message}`));
  await page.goto(`${base}?backend=${backend}`);
  try {
    await page.waitForFunction(() => window.__earsheet && (window.__earsheet.ready || window.__earsheet.error), null, { timeout: 120000 });
  } catch { }
  const init = await page.evaluate(() => ({ ready: window.__earsheet?.ready, backend: window.__earsheet?.backend, warmupMs: window.__earsheet?.warmupMs, failures: window.__earsheet?.backendFailures, error: window.__earsheet?.error, gpu: 'gpu' in navigator }));
  if (!init.ready) { console.log(`backend ${backend}: NOT READY`, init, logs.slice(-10)); report.push({ requested: backend, init }); failed++; await page.close(); continue; }
  for (const [name, c] of Object.entries(CASES)) {
    await page.evaluate(() => { window.__earsheet.lastResult = null; });
    await page.setInputFiles('#file-input', files[name]);
    await page.waitForFunction(() => window.__earsheet.lastResult, null, { timeout: 300000 });
    const r = await page.evaluate(() => window.__earsheet.lastResult);
    const s = score(c.events.map(([m, t]) => [m, t]), r.notes);
    const ok = s.tp === s.expected && s.extra.length <= Math.floor(args.maxExtra ?? 2);
    if (!ok) failed++;
    const row = { requested: backend, backend: r.backend, case: name, ok, ...s, ms: Math.round(r.inference.ms), windows: r.inference.windows, msPerWindow: Math.round(r.inference.msPerWindow), rtf: +r.inference.rtf.toFixed(1), bpm: Math.round(r.bpm), meter: r.meter, key: r.key, warmupMs: Math.round(init.warmupMs), notes: r.notes.map((n) => `${n.name}@${n.onset}`).join(' ') };
    report.push(row);
    console.log(JSON.stringify(row));
    if (args.shot && name === 'two-hands' && backend === backends[0]) {
      await page.waitForTimeout(300);
      await page.screenshot({ path: args.shot, fullPage: true });
    }
  }
  // Second run on the longest case = steady-state timing (shaders compiled).
  const errs = logs.filter((l) => /error/i.test(l));
  if (errs.length) console.log(`console errors on ${backend}:`, errs.slice(0, 5));
  await page.close();
}
await browser.close();
server.close();
if (args.json) await writeFile(args.json, JSON.stringify(report, null, 2));
console.log(failed ? `FAILED: ${failed}` : 'ALL PASSED');
process.exit(failed ? 1 : 0);
