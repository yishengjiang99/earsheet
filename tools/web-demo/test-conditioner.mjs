// Unit tests for the mic input chain in web/capture-worklet.js (JS port of the iOS
// InputConditioner/NoiseGate), mirroring Packages/HearSheet/Tests/HearSheetTests/InputConditionerTests.swift.
// Usage: node test-conditioner.mjs
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const here = dirname(fileURLToPath(import.meta.url));
const ctx = { Math, Float32Array, Float64Array, Infinity, globalThis: null };
ctx.globalThis = ctx;
vm.runInNewContext(readFileSync(join(here, '..', '..', 'web', 'capture-worklet.js'), 'utf8'), ctx);
const { InputConditioner, HighPassFilter, DEFAULT_SETTINGS } = ctx.EarSheetDSP;
const sr = 22050;
let failed = 0;
const check = (ok, msg) => { console.log(`${ok ? 'ok  ' : 'FAIL'} ${msg}`); if (!ok) failed++; };

function rng(seed) { let s = BigInt(seed); return () => { s = (s * 6364136223846793005n + 1442695040888963407n) & 0xffffffffffffffffn; return Number(s >> 11n) / 2 ** 53; }; }
function noise(seconds, rmsDB, seed = 42) { const r = rng(seed), n = Math.floor(seconds * sr), a = 10 ** (rmsDB / 20) * Math.sqrt(3); return Float32Array.from({ length: n }, () => (r() * 2 - 1) * a); }
function sine(f, seconds, peakDB) { const a = 10 ** (peakDB / 20); return Float32Array.from({ length: Math.floor(seconds * sr) }, (_, i) => a * Math.sin(2 * Math.PI * f * i / sr)); }
const add = (a, b) => a.map((v, i) => v + (b[i] || 0));
const cat = (...xs) => { const o = new Float32Array(xs.reduce((n, x) => n + x.length, 0)); let p = 0; for (const x of xs) { o.set(x, p); p += x.length; } return o; };
const rmsDB = (x) => { let s = 0; for (const v of x) s += v * v; return 10 * Math.log10(Math.max(s / x.length, 1e-30)); };
function run(c, x, block = 1024) { for (let i = 0; i < x.length; i += block) c.process(x.subarray(i, Math.min(x.length, i + block))); return x; }

{ // Auto floor gates steady AC noise and passes the tone
  const room = add(noise(3, -55), sine(40, 3, -40));
  const x = add(room, cat(new Float32Array(2 * sr), sine(440, 1, -20)));
  const c = new InputConditioner(sr, DEFAULT_SETTINGS);
  run(c, x);
  const f = c.noiseFloorDB;
  check(f < -49 && f > -56, `floor with high-pass ${f.toFixed(1)} dBFS in (-56, -49)`);
  check(Math.abs(c.thresholdDB - (f + 10)) < 1e-9, 'gate threshold = floor + 10 dB');
  check(rmsDB(x.subarray(Math.floor(1.0 * sr), Math.floor(1.9 * sr))) < -80, 'room noise is gated');
  check(Math.abs(rmsDB(x.subarray(Math.floor(2.2 * sr), Math.floor(2.9 * sr))) - -23) < 1, 'tone passes (-23 dB RMS)');
  const raw = new InputConditioner(sr, { ...DEFAULT_SETTINGS, highPass: false, gateEnabled: false });
  run(raw, add(noise(3, -55), sine(40, 3, -40)));
  check(Math.abs(raw.noiseFloorDB - -43) < 2, `floor without high-pass ${raw.noiseFloorDB.toFixed(1)} ≈ -43`);
}
{ // Fixed -50 lets loud AC noise through, Auto does not
  const a = noise(2, -45);
  run(new InputConditioner(sr, { ...DEFAULT_SETTINGS, autoThreshold: false }), a);
  check(rmsDB(a.subarray(sr)) > -50, 'fixed -50 dB threshold passes -45 dB noise');
  const b = noise(2, -45);
  run(new InputConditioner(sr, DEFAULT_SETTINGS), b);
  check(rmsDB(b.subarray(sr)) < -80, 'auto threshold gates it');
}
{ // Manual threshold until the floor is known; ready after 0.5 s
  const c = new InputConditioner(sr, DEFAULT_SETTINGS);
  check(c.noiseFloorDB == null && c.thresholdDB === -50, 'manual threshold before the floor is known');
  run(c, noise(0.3, -60));
  check(c.noiseFloorDB == null, 'not ready before 0.5 s');
  run(c, noise(0.3, -60, 7));
  check(Math.abs(c.noiseFloorDB - -60) < 2, `floor ready after 0.5 s: ${c.noiseFloorDB.toFixed(1)}`);
}
{ // Follows a louder room within the window; ignores notes between quiet stretches
  const c = new InputConditioner(sr, DEFAULT_SETTINGS);
  run(c, noise(2, -65));
  check(Math.abs(c.noiseFloorDB - -65) < 2, 'quiet room -65');
  run(c, noise(3.5, -48, 9));
  check(Math.abs(c.noiseFloorDB - -48) < 2, `AC turns on: ${c.noiseFloorDB.toFixed(1)} ≈ -48`);
  const d = new InputConditioner(sr, DEFAULT_SETTINGS);
  const x = noise(3, -60);
  for (let k = 0; k < 4; k++) { const t = sine(330, 0.3, -15); const o = Math.floor((0.5 + k * 0.6) * sr); for (let i = 0; i < t.length; i++) x[o + i] += t[i]; }
  run(d, x);
  check(Math.abs(d.noiseFloorDB - -60) < 3, `floor ignores notes: ${d.noiseFloorDB.toFixed(1)}`);
}
{ // High-pass response
  const gainDB = (f) => { const h = new HighPassFilter(sr, 70); const x = sine(f, 2, 0); h.process(x); return rmsDB(x.subarray(sr)) - rmsDB(sine(f, 2, 0).subarray(sr)); };
  check(gainDB(25) < -17, `25 Hz rumble ${gainDB(25).toFixed(1)} dB`);
  check(gainDB(40) < -9, `40 Hz ${gainDB(40).toFixed(1)} dB`);
  check(Math.abs(gainDB(70) - -3) < 0.5, `-3 dB at 70 Hz (${gainDB(70).toFixed(2)})`);
  check(gainDB(110) > -1, 'A2 passes');
  check(gainDB(262) > -0.1, 'middle C untouched');
  check(DEFAULT_SETTINGS.highPassHz === 70 && DEFAULT_SETTINGS.marginDB === 10 && DEFAULT_SETTINGS.thresholdDB === -50, 'defaults: 70 Hz, +10 dB, -50 dB manual');
}
console.log(failed ? `FAILED: ${failed}` : 'ALL PASSED');
process.exit(failed ? 1 : 0);
