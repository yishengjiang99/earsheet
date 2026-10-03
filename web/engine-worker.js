// SPDX-License-Identifier: AGPL-3.0-or-later
// Inference worker: owns the TF.js backend and the Basic Pitch graph, and turns a
// (possibly still growing) 22,050 Hz mono stream into note/onset/contour frames.
//
// Windowing: the stream is left-padded with 3840 zeros (15 frames) like Basic Pitch.
// Windows are 43,844 samples and advance by an integer number of frames H (256-sample
// hop), so there is no inter-window drift. Window 0 contributes audio frames [0,142);
// window k>=1 contributes the H frames just before its 15-frame right margin, i.e. its
// output rows [157-H, 157). Every kept frame therefore has >= 114 frames of left context,
// which avoids the spurious re-onsets Basic Pitch's 142-frame stitching produces at joins.
import { tf, tfwasm } from './vendor/lib.js';

const WINDOW = 43844, PAD = 3840, HOP = 256, ROWS = 172, MARGIN = 15, NOTE = 88, CONT = 264;
const FIRST = ROWS - 2 * MARGIN; // 142 frames from window 0
let model = null, backend = null, modelUrl = 'model/model.json';
const sessions = new Map();

function webglRenderer() {
  try {
    const gl = new OffscreenCanvas(1, 1).getContext('webgl2');
    if (!gl) return null;
    const ext = gl.getExtension('WEBGL_debug_renderer_info');
    return ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
  } catch { return null; }
}

async function tryBackend(name, auto) {
  let device = '';
  if (name === 'webgpu') {
    if (!navigator.gpu) throw new Error('WebGPU not supported here');
    const adapter = await navigator.gpu.requestAdapter({ powerPreference: 'high-performance' });
    if (!adapter) throw new Error('no WebGPU adapter');
    const info = adapter.info || {};
    device = [info.vendor, info.architecture, info.description].filter(Boolean).join(' / ');
    if (auto && (info.isFallbackAdapter || /swiftshader/i.test(device))) throw new Error(`software adapter (${device})`);
  }
  if (name === 'webgl') {
    const r = webglRenderer();
    if (!r) throw new Error('WebGL2 not available in worker');
    device = r;
    if (auto && /swiftshader|llvmpipe|software/i.test(r)) throw new Error(`software renderer (${r})`);
  }
  if (name === 'wasm') {
    tfwasm.setWasmPaths(new URL('vendor/', import.meta.url).href);
    device = self.crossOriginIsolated ? 'multi-threaded SIMD' : 'single-threaded SIMD';
  }
  if (!(await tf.setBackend(name))) throw new Error(`setBackend(${name}) failed`);
  await tf.ready();
  if (!model) model = await tf.loadGraphModel(new URL(modelUrl, import.meta.url).href);
  const t0 = performance.now();
  await infer(new Float32Array(WINDOW)); // warm-up: compiles kernels, proves all ops run
  return { device, warmupMs: performance.now() - t0 };
}

async function infer(win) {
  const outs = tf.tidy(() => model.execute(tf.tensor3d(win, [1, WINDOW, 1]), ['Identity_1', 'Identity_2', 'Identity']));
  const data = await Promise.all(outs.map((t) => t.data()));
  outs.forEach((t) => t.dispose());
  return data; // [notes 172x88, onsets 172x88, contours 172x264]
}

class Session {
  constructor(id, hop) {
    this.id = id; this.H = hop; this.buf = new Float32Array(1 << 20); this.len = PAD;
    this.k = 0; this.emitted = 0; this.needed = null; this.busy = false; this.done = false;
  }
  push(x) {
    if (this.len + x.length > this.buf.length) {
      const nb = new Float32Array(Math.max(this.buf.length * 2, this.len + x.length));
      nb.set(this.buf.subarray(0, this.len)); this.buf = nb;
    }
    this.buf.set(x, this.len); this.len += x.length;
  }
  get samples() { return this.len - PAD; }
}

async function pump(s) {
  if (s.busy || s.done) return;
  s.busy = true;
  try {
    for (;;) {
      if (s.needed !== null && s.emitted >= s.needed) break;
      const start = s.k * s.H * HOP;
      const ready = s.len >= start + WINDOW;
      if (!ready && s.needed === null) break;
      const win = new Float32Array(WINDOW);
      win.set(s.buf.subarray(start, Math.min(s.len, start + WINDOW)));
      const t0 = performance.now();
      const [nt, on, ct] = await infer(win);
      const ms = performance.now() - t0;
      const r0 = s.k === 0 ? MARGIN : ROWS - MARGIN - s.H, r1 = ROWS - MARGIN;
      let n = r1 - r0;
      if (s.needed !== null) n = Math.min(n, s.needed - s.emitted);
      const f = nt.slice(r0 * NOTE, (r0 + n) * NOTE), o = on.slice(r0 * NOTE, (r0 + n) * NOTE), c = ct.slice(r0 * CONT, (r0 + n) * CONT);
      const msg = { t: 'win', id: s.id, k: s.k, frame0: s.emitted, n, f, o, c, ms,
        samplesIn: s.samples, coveredSamples: Math.min(s.samples, start + WINDOW - PAD) };
      self.postMessage(msg, [f.buffer, o.buffer, c.buffer]);
      s.emitted += n; s.k++;
    }
    if (s.needed !== null && s.emitted >= s.needed && !s.done) {
      s.done = true; sessions.delete(s.id);
      self.postMessage({ t: 'end', id: s.id, frames: s.emitted, windows: s.k });
    }
  } catch (e) {
    self.postMessage({ t: 'error', id: s.id, error: String(e && e.message || e) });
  } finally { s.busy = false; }
}

self.onmessage = async (e) => {
  const m = e.data;
  if (m.t === 'init') {
    if (m.modelUrl) modelUrl = m.modelUrl;
    const order = m.pref && m.pref !== 'auto' ? [m.pref] : ['webgpu', 'webgl', 'wasm', 'cpu'];
    const failures = [];
    for (const name of order) {
      try {
        const r = await tryBackend(name, order.length > 1);
        backend = name;
        self.postMessage({ t: 'ready', backend, ...r, failures, isolated: self.crossOriginIsolated });
        return;
      } catch (err) { failures.push({ name, err: String(err && err.message || err) }); }
    }
    self.postMessage({ t: 'initError', failures });
  } else if (m.t === 'start') {
    sessions.set(m.id, new Session(m.id, m.hop));
  } else if (m.t === 'push') {
    const s = sessions.get(m.id); if (!s) return;
    s.push(m.samples); pump(s);
  } else if (m.t === 'finish') {
    const s = sessions.get(m.id); if (!s) return;
    s.needed = Math.ceil(s.samples / HOP); pump(s);
  } else if (m.t === 'cancel') {
    const s = sessions.get(m.id); if (s) { s.done = true; sessions.delete(m.id); }
  }
};
