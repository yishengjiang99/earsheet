// SPDX-License-Identifier: AGPL-3.0-or-later
// EarSheet web demo: Basic Pitch (Spotify, Apache-2.0) in the browser via TF.js.
// Inference runs in engine-worker.js. Mic mode streams audio through an AudioWorklet
// into the worker and shows notes while you play; upload/sample mode runs the same
// windowing over the whole file.
import { outputToNotesPoly, Midi } from './vendor/lib.js';
import { quantize, toAbc, keyName, midiName } from './quantize.js';

const SR = 22050;
const FPS = SR / 256;            // model frames per second (~86.13)
const MAX_SECONDS = 300;
const QS = new URLSearchParams(location.search);
const LIVE_HOP = +QS.get('liveHop') || 43;  // frames between live windows (~0.5 s)
const FILE_HOP = +QS.get('fileHop') || 71;  // frames between windows for files (~0.82 s)
const LIVE_VIEW = 12;            // seconds visible in the live piano roll
const LIVE_SPAN = 1300;          // frames re-decoded on each live update (~15 s)
const LIVE_GUARD = 260;          // frames at the start of that span that are frozen (~3 s)
const $ = (id) => document.getElementById(id);

const state = {
  backend: null, device: '', warmupMs: 0, ready: false, error: null,
  audio: null, audioUrl: null,
  F: [], O: [], C: [],             // per-frame rows: notes, onsets (88), contours (264)
  notes: [], score: null, lastResult: null,
  live: null, latencies: [], timeline: [],
};
window.__earsheet = state; // for the headless test

// ------------------------------------------------------------------ worker --
const worker = new Worker(new URL('engine-worker.js', import.meta.url), { type: 'module' });
let sessionSeq = 0;
const handlers = new Map();
worker.onmessage = (e) => {
  const m = e.data;
  if (m.t === 'ready' || m.t === 'initError') { initResolve && initResolve(m); return; }
  const h = handlers.get(m.id);
  if (h) h(m);
};
let initResolve = null;
function initEngine(pref, modelUrl) {
  return new Promise((resolve) => { initResolve = resolve; worker.postMessage({ t: 'init', pref, modelUrl }); });
}

// ------------------------------------------------------------------- models --
// "stock" is the pinned Spotify model. "ft" exists only when the deploy shipped a
// fine-tuned model: model-ft/earsheet-model.json then describes it (release tag,
// sha256 pins, recommended decoder settings). Pick with ?model=stock|ft.
const MODELS = {
  // Decoder tuned on held-out real + synthetic audio (docs/finetune/EXPERIMENTS.md, E0t2):
  // onset 0.7, frame 0.4, min note 5 frames (58 ms). Spotify's defaults are 0.5 / 0.3 / 128 ms.
  stock: { id: 'stock', label: 'Stock: Basic Pitch ICASSP 2022', url: 'model/model.json', onset: 0.7, frame: 0.4, minMs: 58 },
};
async function discoverModels() {
  try {
    const idx = await fetch('model-index.json', { cache: 'no-store' }).then((r) => (r.ok ? r.json() : {})).catch(() => ({}));
    if (!idx.ft) return;
    const r = await fetch('model-ft/earsheet-model.json', { cache: 'no-store' });
    if (!r.ok) return;
    const j = await r.json();
    MODELS.ft = { id: 'ft', label: j.label || 'Fine-tuned', url: 'model-ft/model.json', onset: j.onset ?? 0.5,
      frame: j.frame ?? 0.3, minMs: j.minMs ?? 128, tag: j.tag, info: j };
  } catch { /* no fine-tuned model deployed */ }
}
function applyModelDefaults(m) {
  // Per-model recommended decoder settings, unless the URL overrides them.
  const set = (id, v) => { $(id).value = v; document.querySelector(`output[for=${id}]`).textContent = $(id).value; };
  if (!QS.has('onset')) set('onset-th', m.onset); else set('onset-th', +QS.get('onset'));
  if (!QS.has('frame')) set('frame-th', m.frame); else set('frame-th', +QS.get('frame'));
  if (!QS.has('minMs')) set('min-note', m.minMs); else set('min-note', +QS.get('minMs'));
}

function startSession(hop, onMsg) {
  const id = ++sessionSeq;
  handlers.set(id, (m) => { onMsg(m); if (m.t === 'end' || m.t === 'error') handlers.delete(id); });
  worker.postMessage({ t: 'start', id, hop });
  return id;
}

function appendFrames(m) {
  for (let i = 0; i < m.n; i++) {
    state.F.push(m.f.subarray(i * 88, (i + 1) * 88));
    state.O.push(m.o.subarray(i * 88, (i + 1) * 88));
    state.C.push(m.c.subarray(i * 264, (i + 1) * 264));
  }
}
function resetFrames() { state.F = []; state.O = []; state.C = []; state.notes = []; state.score = null; }

// ----------------------------------------------------------------- decoding --
function decoderParams() {
  return {
    onset: +$('onset-th').value, frame: +$('frame-th').value,
    minLen: Math.max(1, Math.round((+$('min-note').value / 1000) * FPS)),
  };
}
/** Decode frames [a, b) into {midi, startFrame, endFrame, velocity}. */
function decodeRange(a, b) {
  if (b - a < 3) return [];
  const p = decoderParams();
  const fr = [], on = [];
  for (let i = a; i < b; i++) { fr.push(Array.from(state.F[i])); on.push(Array.from(state.O[i])); }
  const ev = outputToNotesPoly(fr, on, p.onset, p.frame, p.minLen, true, null, null, true, 11);
  return ev.map((n) => ({ midi: n.pitchMidi, startFrame: n.startFrame + a, endFrame: n.startFrame + a + n.durationFrames, velocity: n.amplitude }));
}
const toTimed = (ev) => ev.map((n) => ({ midi: n.midi, onset: (n.startFrame * 256) / SR, offset: (n.endFrame * 256) / SR, velocity: n.velocity, startFrame: n.startFrame }))
  .sort((x, y) => x.onset - y.onset || x.midi - y.midi);

function finalizeNotes() {
  state.notes = toTimed(decodeRange(0, state.F.length));
  state.score = quantize(state.notes);
  state.lastResult = {
    backend: state.backend, mode: state.lastMode, inference: state.lastInference,
    notes: state.notes.map((n) => ({ midi: n.midi, name: midiName(n.midi), onset: +n.onset.toFixed(3), offset: +n.offset.toFixed(3), velocity: +n.velocity.toFixed(2) })),
    bpm: state.score.bpm, meter: state.score.meter, key: keyName(state.score.key),
    latency: latencyStats(),
  };
  renderFinal();
}

// ------------------------------------------------------------------ audio --
async function toMono22k(arrayBuffer) {
  const ctx = new (window.AudioContext || window.webkitAudioContext)();
  const decoded = await ctx.decodeAudioData(arrayBuffer);
  ctx.close();
  const seconds = Math.min(decoded.duration, MAX_SECONDS);
  const off = new OfflineAudioContext(1, Math.ceil(seconds * SR), SR);
  const src = off.createBufferSource();
  src.buffer = decoded; src.connect(off.destination); src.start();
  const rendered = await off.startRendering();
  return { samples: rendered.getChannelData(0), origRate: decoded.sampleRate, origChannels: decoded.numberOfChannels, truncated: decoded.duration > MAX_SECONDS, duration: decoded.duration };
}

function setAudio(samples, blob) {
  state.audio = samples;
  if (state.audioUrl) URL.revokeObjectURL(state.audioUrl);
  state.audioUrl = URL.createObjectURL(blob);
  $('audio-el').src = state.audioUrl; $('audio-el').hidden = false;
}

async function loadAudio(blob, label) {
  const info = await toMono22k(await blob.arrayBuffer());
  setAudio(info.samples, blob);
  $('audio-info').textContent = `${label}: ${info.duration.toFixed(2)} s, ${info.origRate} Hz × ${info.origChannels} ch → ${SR} Hz mono${info.truncated ? ` (first ${MAX_SECONDS} s only)` : ''}`;
  $('run-btn').disabled = !state.ready;
}

function synthSample() {
  const dur = 6.5, n = Math.floor(dur * SR), x = new Float32Array(n);
  const tone = (midi, t0, len) => {
    const f = 440 * 2 ** ((midi - 69) / 12);
    for (let i = Math.floor(t0 * SR); i < Math.min(n, Math.floor((t0 + len) * SR)); i++) {
      const t = i / SR - t0;
      const env = Math.min(1, t / 0.01) * Math.exp(-2.5 * t) * Math.min(1, (len - t) / 0.03);
      x[i] += 0.18 * env * (Math.sin(2 * Math.PI * f * t) + 0.4 * Math.sin(4 * Math.PI * f * t) + 0.2 * Math.sin(6 * Math.PI * f * t));
    }
  };
  [60, 62, 64, 65, 67, 69, 71, 72].forEach((m, i) => tone(m, 0.25 + i * 0.45, 0.42));
  [48, 60, 64, 67].forEach((m) => tone(m, 4.0, 2.2));
  return new Blob([encodeWav(x, SR)], { type: 'audio/wav' });
}

function encodeWav(x, sr) {
  const buf = new ArrayBuffer(44 + x.length * 2), v = new DataView(buf);
  const w = (o, s) => [...s].forEach((c, i) => v.setUint8(o + i, c.charCodeAt(0)));
  w(0, 'RIFF'); v.setUint32(4, 36 + x.length * 2, true); w(8, 'WAVEfmt ');
  v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true);
  v.setUint32(24, sr, true); v.setUint32(28, sr * 2, true); v.setUint16(32, 2, true); v.setUint16(34, 16, true);
  w(36, 'data'); v.setUint32(40, x.length * 2, true);
  for (let i = 0; i < x.length; i++) v.setInt16(44 + i * 2, Math.max(-1, Math.min(1, x[i])) * 32767, true);
  return buf;
}

// ------------------------------------------------------- file transcription --
function runFile() {
  if (!state.audio || !state.ready || state.live) return Promise.resolve();
  stop();
  resetFrames();
  state.lastMode = 'file';
  $('run-btn').disabled = true;
  $('progress').hidden = false; $('progress').value = 0;
  $('timing').textContent = 'running…';
  const needed = Math.ceil(state.audio.length / 256);
  const t0 = performance.now();
  let windows = 0, inferMs = 0;
  return new Promise((resolve) => {
    const id = startSession(FILE_HOP, (m) => {
      if (m.t === 'win') { appendFrames(m); windows++; inferMs += m.ms; $('progress').value = state.F.length / needed; }
      else if (m.t === 'end') {
        const ms = performance.now() - t0, audioSec = state.audio.length / SR;
        state.lastInference = { ms, inferMs, audioSec, windows, backend: state.backend, msPerWindow: inferMs / windows, rtf: audioSec / (ms / 1000) };
        $('timing').textContent = `${state.backend}: ${ms.toFixed(0)} ms for ${audioSec.toFixed(1)} s of audio (${windows} windows, ${(inferMs / windows).toFixed(0)} ms/window, ${state.lastInference.rtf.toFixed(1)}× real time)`;
        $('progress').hidden = true; $('run-btn').disabled = false;
        finalizeNotes();
        resolve();
      } else if (m.t === 'error') { $('timing').textContent = 'error: ' + m.error; state.error = m.error; resolve(); }
    });
    // Send in chunks so the worker can start before the whole copy lands.
    const CH = SR * 10;
    for (let i = 0; i < state.audio.length; i += CH) worker.postMessage({ t: 'push', id, samples: state.audio.slice(i, i + CH) });
    worker.postMessage({ t: 'finish', id });
  });
}

// ------------------------------------------------------- live mic streaming --
class Resampler { // fallback when the AudioContext can't run at 22,050 Hz
  constructor(inRate) { this.r = inRate / SR; this.pos = 0; this.prev = 0; }
  process(x) {
    const out = [];
    // Box-filter + linear interpolation: crude anti-aliasing for the fallback path only.
    const w = Math.max(1, Math.round(this.r));
    const sm = new Float32Array(x.length);
    let acc = 0;
    for (let i = 0; i < x.length; i++) { acc += x[i] - (i >= w ? x[i - w] : 0); sm[i] = acc / Math.min(w, i + 1); }
    while (this.pos < x.length - 1) {
      const i = Math.floor(this.pos), f = this.pos - i;
      out.push(sm[i] * (1 - f) + sm[i + 1] * f);
      this.pos += this.r;
    }
    this.pos -= x.length;
    return Float32Array.from(out);
  }
}

async function startLive() {
  let stream;
  try {
    stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false, channelCount: 1 } });
  } catch (e) { alert('Microphone unavailable: ' + e.message); return; }
  stop();
  resetFrames();
  state.lastMode = 'live';
  state.latencies = []; state.timeline = [];
  let ctx, src, resampler = null;
  try {
    ctx = new AudioContext({ sampleRate: SR, latencyHint: 'interactive' });
    src = ctx.createMediaStreamSource(stream);
  } catch {
    if (ctx) ctx.close();
    ctx = new AudioContext({ latencyHint: 'interactive' });
    src = ctx.createMediaStreamSource(stream);
    resampler = new Resampler(ctx.sampleRate);
  }
  await ctx.audioWorklet.addModule(new URL('capture-worklet.js', import.meta.url));
  const node = new AudioWorkletNode(ctx, 'earsheet-capture', { numberOfInputs: 1, numberOfOutputs: 1, channelCount: 1, channelCountMode: 'explicit' });
  const mute = ctx.createGain(); mute.gain.value = 0;
  src.connect(node); node.connect(mute); mute.connect(ctx.destination);

  const live = state.live = {
    stream, ctx, node, chunks: [], samples: 0, wallStart: 0, inferMs: 0, windows: 0,
    frozen: [], prov: [], frozenUntil: 0, seen: new Map(), lastStaff: 0, decodePending: false,
    behind: 0, stopping: false, rate: ctx.sampleRate,
  };
  live.id = startSession(LIVE_HOP, (m) => {
    if (m.t === 'win') {
      appendFrames(m); live.windows++; live.inferMs += m.ms;
      live.behind = (live.samples - m.coveredSamples) / SR;
      scheduleLiveDecode();
    } else if (m.t === 'end') {
      live.onEnd && live.onEnd();
    } else if (m.t === 'error') { state.error = m.error; }
  });
  node.port.onmessage = (e) => {
    let x = e.data;
    if (resampler) x = resampler.process(x);
    if (!live.samples) live.wallStart = performance.now() - (x.length / SR) * 1000;
    live.chunks.push(x); live.samples += x.length;
    worker.postMessage({ t: 'push', id: live.id, samples: x });
    if (live.samples >= MAX_SECONDS * SR) stopLive();
  };
  $('rec-btn').textContent = '■ Stop'; $('rec-btn').classList.add('recording');
  $('sample-btn').disabled = true; $('run-btn').disabled = true; $('file-label').classList.add('disabled');
  for (const b of ['play-btn', 'play-orig-btn', 'midi-btn']) $(b).disabled = true;
  $('results').hidden = false;
  $('live-badge').hidden = false;
  $('audio-info').textContent = `Live: mic at ${ctx.sampleRate} Hz${resampler ? ' (resampled in JS)' : ''} → ${SR} Hz mono · windows every ${(LIVE_HOP * 256 / SR).toFixed(2)} s`;
  const tick = () => {
    if (state.live !== live) return;
    const now = liveNow();
    $('rec-time').textContent = `${now.toFixed(1)} s`;
    drawRoll({ live: true, now });
    live.raf = requestAnimationFrame(tick);
  };
  live.raf = requestAnimationFrame(tick);
}

const liveNow = () => (state.live && state.live.samples ? (performance.now() - state.live.wallStart) / 1000 : 0);

function scheduleLiveDecode() {
  const live = state.live;
  if (!live || live.decodePending) return;
  live.decodePending = true;
  setTimeout(() => { live.decodePending = false; if (state.live === live) liveDecode(); }, 0);
}

function liveDecode() {
  const live = state.live, n = state.F.length;
  const t0 = performance.now();
  // Re-decode only the most recent LIVE_SPAN frames; notes that start before the
  // freeze point keep their last decoded value. Short takes are fully re-decoded.
  const start = Math.max(0, n - LIVE_SPAN);
  const freezeAt = start > 0 ? start + LIVE_GUARD : 0;
  if (freezeAt > live.frozenUntil) {
    live.frozen.push(...live.prov.filter((x) => x.startFrame >= live.frozenUntil && x.startFrame < freezeAt));
    live.frozenUntil = freezeAt;
  }
  live.prov = decodeRange(start, n).filter((x) => x.startFrame >= live.frozenUntil);
  state.notes = toTimed([...live.frozen, ...live.prov]);
  const decodeMs = performance.now() - t0;
  // Latency: wall-clock audio time when a note first appears minus its onset time.
  const now = liveNow();
  for (const nt of state.notes) {
    // A note counts as already shown if one with the same pitch and an onset within
    // 60 ms was on screen before (re-decodes can nudge onsets by a frame or two).
    const list = live.seen.get(nt.midi) || [];
    if (!list.some((t) => Math.abs(t - nt.onset) < 0.06)) {
      list.push(nt.onset); live.seen.set(nt.midi, list);
      state.latencies.push({ midi: nt.midi, onset: nt.onset, shownAt: now, latency: now - nt.onset });
    }
  }
  state.timeline.push({ t: now, frames: n, notes: state.notes.length });
  const ls = latencyStats();
  $('summary').textContent = `${state.notes.length} notes`;
  $('timing').textContent = `live · ${state.backend} · ${(live.inferMs / live.windows).toFixed(0)} ms/window · decode ${decodeMs.toFixed(0)} ms` +
    (ls ? ` · note latency last ${ls.last.toFixed(2)} s, median ${ls.median.toFixed(2)} s` : '') +
    (live.behind > 1.5 ? ` · ⚠ ${live.behind.toFixed(1)} s behind` : '');
  if (performance.now() - live.lastStaff > 800) { live.lastStaff = performance.now(); renderStaff(true); }
}

function latencyStats() {
  const l = state.latencies.map((x) => x.latency).filter((x) => x >= 0).sort((a, b) => a - b);
  if (!l.length) return null;
  return { n: l.length, min: l[0], median: l[Math.floor(l.length / 2)], p90: l[Math.min(l.length - 1, Math.floor(l.length * 0.9))], max: l[l.length - 1], last: state.latencies[state.latencies.length - 1].latency };
}

function stopLive() {
  const live = state.live;
  if (!live || live.stopping) return Promise.resolve();
  live.stopping = true;
  cancelAnimationFrame(live.raf);
  live.node.port.onmessage = null;
  live.stream.getTracks().forEach((t) => t.stop());
  live.ctx.close();
  $('rec-btn').disabled = true; $('rec-btn').textContent = 'Finishing…';
  return new Promise((resolve) => {
    live.onEnd = () => {
      const all = new Float32Array(live.samples);
      let o = 0; for (const c of live.chunks) { all.set(c, o); o += c.length; }
      setAudio(all, new Blob([encodeWav(all, SR)], { type: 'audio/wav' }));
      const audioSec = all.length / SR;
      state.lastInference = { ms: live.inferMs, inferMs: live.inferMs, audioSec, windows: live.windows, backend: state.backend, msPerWindow: live.inferMs / live.windows, rtf: audioSec / (live.inferMs / 1000) };
      state.live = null;
      $('rec-btn').disabled = false; $('rec-btn').textContent = '● Record (live)'; $('rec-btn').classList.remove('recording');
      $('sample-btn').disabled = false; $('run-btn').disabled = false; $('file-label').classList.remove('disabled');
      for (const b of ['play-btn', 'play-orig-btn', 'midi-btn']) $(b).disabled = false;
      $('live-badge').hidden = true; $('rec-time').textContent = '';
      $('audio-info').textContent = `Recording: ${audioSec.toFixed(2)} s at ${SR} Hz mono`;
      finalizeNotes();
      const ls = latencyStats();
      $('timing').textContent = `${state.backend}: ${live.windows} windows, ${(live.inferMs / live.windows).toFixed(0)} ms/window` +
        (ls ? ` · live note latency median ${ls.median.toFixed(2)} s (min ${ls.min.toFixed(2)}, max ${ls.max.toFixed(2)}, n=${ls.n})` : '');
      resolve();
    };
    worker.postMessage({ t: 'finish', id: live.id });
  });
}

// ----------------------------------------------------------------- render --
function renderStaff(live) {
  const s = quantize(state.notes);
  state.score = s;
  $('quant-info').textContent = s.notes.length ? `≈${Math.round(s.bpm)} BPM · ${s.meter} · ${keyName(s.key)} · 16th grid${live ? ' · live, last 8 bars' : ''}` : '';
  const abc = toAbc(s, live ? { lastBars: 8 } : { maxBars: 24 });
  state.abc = abc;
  if (abc && window.ABCJS) window.ABCJS.renderAbc('staff', abc, { responsive: 'resize', add_classes: true, paddingtop: 0 });
  else $('staff').innerHTML = `<p style="color:#555;padding:8px">${live ? 'Listening…' : 'No notes detected.'}</p>`;
}

function renderFinal() {
  $('results').hidden = false;
  $('summary').textContent = `${state.notes.length} notes`;
  drawRoll({});
  renderStaff(false);
  const tb = $('note-table').querySelector('tbody');
  tb.innerHTML = state.notes.map((n, i) => `<tr><td>${i + 1}</td><td>${midiName(n.midi)}</td><td>${n.midi}</td><td>${n.onset.toFixed(3)}</td><td>${(n.offset - n.onset).toFixed(3)}</td><td>${n.velocity.toFixed(2)}</td></tr>`).join('');
}

function drawRoll({ live = false, now = 0, playhead = -1 } = {}) {
  const c = $('roll'), ctx = c.getContext('2d');
  const dpr = window.devicePixelRatio || 1;
  const W = Math.round(c.clientWidth * dpr), H = Math.round(320 * dpr);
  if (c.width !== W) c.width = W;
  if (c.height !== H) c.height = H;
  ctx.fillStyle = '#0b0d11'; ctx.fillRect(0, 0, c.width, c.height);
  const notes = state.notes;
  const transcribed = state.F.length / FPS;
  let t0 = 0, t1;
  if (live) { t1 = Math.max(LIVE_VIEW, now + 0.5); t0 = t1 - LIVE_VIEW; }
  else t1 = Math.max(0.5, state.audio ? state.audio.length / SR : transcribed);
  let lo = 48, hi = 84;
  if (notes.length) { lo = Math.min(lo, ...notes.map((n) => n.midi - 3)); hi = Math.max(hi, ...notes.map((n) => n.midi + 3)); if (!live) { lo = Math.min(...notes.map((n) => n.midi)) - 3; hi = Math.max(...notes.map((n) => n.midi)) + 3; } }
  if (hi - lo < 24) { const mid = (hi + lo) / 2; lo = Math.floor(mid - 12); hi = Math.ceil(mid + 12); }
  const left = 34 * dpr, w = c.width - left, h = c.height;
  const rowH = h / (hi - lo + 1);
  const x = (t) => left + ((t - t0) / (t1 - t0)) * w;
  const y = (m) => h - (m - lo + 1) * rowH;
  for (let m = lo; m <= hi; m++) {
    ctx.fillStyle = [1, 3, 6, 8, 10].includes(m % 12) ? '#10131a' : '#151922';
    ctx.fillRect(left, y(m), w, rowH);
    if (m % 12 === 0) { ctx.fillStyle = '#8890a0'; ctx.font = `${10 * dpr}px system-ui`; ctx.fillText(midiName(m), 2 * dpr, y(m) + rowH - 1); ctx.fillStyle = '#2a2f3a'; ctx.fillRect(left, y(m) + rowH - 1, w, 1); }
  }
  // Frame posteriors (faint) for the visible range
  const fa = Math.max(0, Math.floor(t0 * FPS)), fb = Math.min(state.F.length, Math.ceil(t1 * FPS));
  const step = Math.max(1, Math.floor((fb - fa) / w));
  const fw = Math.max(1, (step / FPS) / (t1 - t0) * w);
  for (let i = fa; i < fb; i += step) {
    const row = state.F[i], xi = x(i / FPS);
    for (let m = lo; m <= hi; m++) {
      const v = row[m - 21];
      if (v > 0.15) { ctx.fillStyle = `rgba(90,169,255,${(v * 0.35).toFixed(2)})`; ctx.fillRect(xi, y(m), fw, rowH); }
    }
  }
  const ph = live ? -1 : playhead;
  for (const n of notes) {
    if (n.offset < t0 || n.onset > t1) continue;
    const active = ph >= n.onset && ph < n.offset;
    ctx.fillStyle = active ? '#ffd166' : `hsl(${210 - n.velocity * 160}, 80%, ${45 + n.velocity * 20}%)`;
    ctx.fillRect(x(n.onset), y(n.midi) + 1, Math.max(2, x(n.offset) - x(n.onset)), Math.max(2, rowH - 2));
  }
  if (live) {
    // Pending region: heard but not yet transcribed.
    ctx.fillStyle = 'rgba(255,255,255,0.06)';
    ctx.fillRect(x(transcribed), 0, Math.max(0, x(now) - x(transcribed)), h);
    ctx.fillStyle = '#ff5d5d'; ctx.fillRect(x(now), 0, 2 * dpr, h);
    ctx.fillStyle = '#8890a0'; ctx.font = `${10 * dpr}px system-ui`;
    for (let s = Math.ceil(t0); s <= t1; s++) ctx.fillText(`${s}s`, x(s) + 2, h - 3);
  } else if (ph >= 0) { ctx.fillStyle = '#fff'; ctx.fillRect(x(ph), 0, 1.5 * dpr, h); }
}

// --------------------------------------------------------------- playback --
let actx = null, playing = null;
function stop() {
  if (playing) { playing.nodes.forEach((n) => { try { n.stop(); } catch {} }); cancelAnimationFrame(playing.raf); playing = null; }
  $('audio-el').pause();
  if (!state.live && state.notes.length) drawRoll({});
}
function playNotes() {
  if (state.live) return;
  stop();
  actx = actx || new AudioContext();
  const t0 = actx.currentTime + 0.1;
  const master = actx.createGain(); master.gain.value = 0.25; master.connect(actx.destination);
  const nodes = [];
  for (const n of state.notes) {
    const o = actx.createOscillator(), g = actx.createGain();
    o.type = 'triangle'; o.frequency.value = 440 * 2 ** ((n.midi - 69) / 12);
    const a = t0 + n.onset, e = t0 + n.offset, peak = 0.15 + 0.5 * n.velocity;
    g.gain.setValueAtTime(0, a); g.gain.linearRampToValueAtTime(peak, a + 0.01);
    g.gain.exponentialRampToValueAtTime(peak * 0.4, Math.max(a + 0.02, e)); g.gain.linearRampToValueAtTime(0, e + 0.08);
    o.connect(g).connect(master); o.start(a); o.stop(e + 0.1); nodes.push(o);
  }
  const end = Math.max(0, ...state.notes.map((n) => n.offset)) + 0.2;
  playing = { nodes, raf: 0 };
  const tick = () => {
    const t = actx.currentTime - t0;
    drawRoll({ playhead: t });
    if (t < end && playing) playing.raf = requestAnimationFrame(tick); else stop();
  };
  playing.raf = requestAnimationFrame(tick);
}
function playOriginal() {
  if (state.live) return;
  stop();
  const el = $('audio-el');
  el.currentTime = 0; el.play();
  playing = { nodes: [], raf: 0 };
  const tick = () => { drawRoll({ playhead: el.currentTime }); if (!el.paused && playing) playing.raf = requestAnimationFrame(tick); };
  playing.raf = requestAnimationFrame(tick);
}

function downloadMidi() {
  const midi = new Midi();
  midi.header.setTempo(state.score ? state.score.bpm : 120);
  midi.header.name = 'EarSheet web transcription';
  const tr = midi.addTrack(); tr.name = 'Basic Pitch';
  for (const n of state.notes) tr.addNote({ midi: n.midi, time: n.onset, duration: n.offset - n.onset, velocity: Math.min(1, Math.max(0.05, n.velocity)) });
  const blob = new Blob([midi.toArray()], { type: 'audio/midi' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob); a.download = 'earsheet-transcription.mid'; a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 5000);
}

// ------------------------------------------------------------------- wire --
async function wire() {
  $('rec-btn').onclick = () => (state.live ? stopLive() : startLive());
  $('file-input').onchange = async (e) => {
    const f = e.target.files[0]; if (!f) return;
    e.target.value = '';
    try { await loadAudio(f, f.name); await runFile(); } catch (err) { state.error = String(err); $('audio-info').textContent = 'Could not read audio: ' + err.message; }
  };
  $('sample-btn').onclick = async () => { await loadAudio(synthSample(), 'Sample (C major scale + triad)'); await runFile(); };
  $('run-btn').onclick = runFile;
  $('play-btn').onclick = playNotes;
  $('play-orig-btn').onclick = playOriginal;
  $('stop-btn').onclick = stop;
  $('midi-btn').onclick = downloadMidi;
  for (const id of ['onset-th', 'frame-th', 'min-note']) {
    $(id).oninput = () => { document.querySelector(`output[for=${id}]`).textContent = $(id).value; };
    $(id).onchange = () => { if (!state.live && state.F.length) finalizeNotes(); };
  }
  window.addEventListener('resize', () => !state.live && state.notes.length && drawRoll({}));
  const params = new URLSearchParams(location.search);
  const pref = params.get('backend') || 'auto';
  $('backend-select').value = pref;
  $('backend-select').onchange = (e) => { const p = new URLSearchParams(location.search); p.set('backend', e.target.value); location.search = p.toString(); };
  const canRecord = !!(window.AudioWorkletNode && navigator.mediaDevices && navigator.mediaDevices.getUserMedia);
  $('backend').textContent = 'initialising…';
  await discoverModels();
  const want = params.get('model') || 'stock';
  const model = MODELS[want] || MODELS.stock;
  state.model = model.id; state.modelTag = model.tag || 'stock';
  const sel = $('model-select');
  sel.innerHTML = Object.values(MODELS).map((m) => `<option value="${m.id}">${m.label}</option>`).join('');
  sel.value = model.id;
  sel.hidden = Object.keys(MODELS).length < 2; // only stock ships (no fine-tune beat it)
  sel.onchange = (e) => { const p = new URLSearchParams(location.search); p.set('model', e.target.value); location.search = p.toString(); };
  applyModelDefaults(model);
  initEngine(pref, model.url).then((m) => {
    if (m.t !== 'ready') {
      $('backend').textContent = 'none available';
      state.error = 'no backend: ' + JSON.stringify(m.failures);
      $('model-status').textContent = 'failed';
      return;
    }
    Object.assign(state, { backend: m.backend, device: m.device, warmupMs: m.warmupMs, backendFailures: m.failures, isolated: m.isolated, ready: true });
    $('backend').textContent = m.backend; $('backend').className = 'ok';
    let note = `${m.device ? m.device + ' · ' : ''}warm-up ${m.warmupMs.toFixed(0)} ms · in a Web Worker`;
    if (m.failures.length) note += ` · skipped ${m.failures.map((f) => f.name).join(', ')}`;
    $('backend-note').textContent = note;
    $('backend-note').title = m.failures.map((f) => `${f.name}: ${f.err}`).join('\n');
    $('model-status').textContent = model.id === 'stock' ? 'Basic Pitch ICASSP 2022 (TF.js, 0.9 MB) ready'
      : `${model.label} (${model.tag || 'fine-tuned'}, same size as stock) ready`;
    $('rec-btn').disabled = !canRecord;
    if (!canRecord) $('rec-btn').title = 'Recording needs AudioWorklet + getUserMedia';
    $('sample-btn').disabled = false;
    $('run-btn').disabled = !state.audio;
  });
}
wire();
