// SPDX-License-Identifier: AGPL-3.0-or-later
// EarSheet web demo: Basic Pitch (Spotify, Apache-2.0) in the browser via TF.js.
// Inference runs in engine-worker.js. Mic mode streams audio through an AudioWorklet
// into the worker and shows notes while you play; upload/sample mode runs the same
// windowing over the whole file.
import { outputToNotesPoly, Midi } from './vendor/lib.js';
import { quantize, toAbc, keyName, midiName, METERS, clampTempo, metronomeMark } from './quantize.js';

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
  // Piano roll first (iOS 73809cf): the sheet analysis (whole-take tempo, meter, key,
  // quantization) runs only for the Page view or an export, cached on notes + tempo.
  view: 'roll', tempoOverride: null, sheetCache: null, estimateCache: null, analysisRuns: 0,
  take: null,                      // {source: 'live'|'file', thresholdDB, floorDB}
  droppedQuiet: 0, exported: false,
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
function resetFrames() {
  state.F = []; state.O = []; state.C = []; state.notes = []; state.score = null;
  // A new take: back to the piano roll, estimated tempo, no cached sheet.
  state.tempoOverride = null; state.sheetCache = null; state.estimateCache = null; state.exported = false;
  setView('roll');
}

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
  let notes = toTimed(decodeRange(0, state.F.length));
  state.droppedQuiet = 0;
  // Mic takes: ignore notes whose onset is quieter than the gate (iOS ListeningView).
  const tk = state.take;
  if (tk && tk.source === 'live' && tk.dropQuiet && tk.gateEnabled && tk.thresholdDB != null) {
    const kept = dropQuietNotes(notes, state.audio, SR, tk.thresholdDB);
    state.droppedQuiet = notes.length - kept.length;
    notes = kept;
  }
  state.notes = notes;
  state.score = null;
  state.lastResult = {
    backend: state.backend, mode: state.lastMode, inference: state.lastInference,
    notes: state.notes.map((n) => ({ midi: n.midi, name: midiName(n.midi), onset: +n.onset.toFixed(3), offset: +n.offset.toFixed(3), velocity: +n.velocity.toFixed(2) })),
    droppedQuiet: state.droppedQuiet, noiseFloorDB: tk ? tk.floorDB : null, gateThresholdDB: tk ? tk.thresholdDB : null,
    analysisRuns: state.analysisRuns, // the sheet analysis does not run here (piano roll first)
    latency: latencyStats(),
  };
  renderFinal();
}

// ---------------------------------------------------------- sheet analysis --
function notesKey(notes) {
  let h = 0x811c9dc5; // FNV-1a over the rounded notes
  const mix = (v) => { h ^= v & 0xffffffff; h = Math.imul(h, 0x01000193) >>> 0; };
  for (const n of notes) { mix(n.midi); mix(Math.round(n.onset * 1000)); mix(Math.round(n.offset * 1000)); mix(Math.round(n.velocity * 100)); }
  return `${notes.length}:${h}`;
}
/** Cached sheet for the current notes + tempo, or null (never runs the analysis). */
function currentSheet() {
  const k = `${notesKey(state.notes)}|${state.tempoOverride ?? 'est'}`;
  return (state.sheetCache && state.sheetCache.get(k)) || null;
}
/** Runs the whole-take analysis if there's no cached one (Page view / export only). */
function sheetScore() {
  const cached = currentSheet();
  if (cached) { state.score = cached; return cached; }
  const k = `${notesKey(state.notes)}|${state.tempoOverride ?? 'est'}`;
  const score = quantize(state.notes, { bpm: state.tempoOverride });
  state.analysisRuns++;
  if (!state.sheetCache) state.sheetCache = new Map();
  state.sheetCache.set(k, score); // a few tempi per take (e.g. back to the estimate is free)
  if (state.sheetCache.size > 8) state.sheetCache.delete(state.sheetCache.keys().next().value);
  state.score = score;
  if (state.lastResult) Object.assign(state.lastResult, { bpm: score.bpm, meter: score.meter, key: keyName(score.key), analysisRuns: state.analysisRuns, tempoOverride: state.tempoOverride });
  return score;
}
function estimatedTempo() {
  const k = notesKey(state.notes);
  if (!state.estimateCache || state.estimateCache.key !== k) state.estimateCache = { key: k, bpm: state.tempoOverride == null ? sheetScore().bpm : quantize(state.notes).bpm };
  return state.estimateCache.bpm;
}
function setTempo(bpm) {
  state.tempoOverride = bpm == null ? null : clampTempo(Math.round(bpm));
  if (state.view === 'page') renderPage();
  drawRoll({});
}

// ------------------------------------------------------------ mic settings --
// Same settings and defaults as the iOS app's Settings > Microphone (InputConditioner.Settings,
// NoiseGate.Settings), stored in localStorage under the same keys.
const MIC_DEFAULTS = { gateEnabled: true, thresholdDB: -50, attackMs: 10, holdMs: 50, releaseMs: 50,
  autoThreshold: true, marginDB: 10, highPass: true, highPassHz: 70, dropQuietNotes: true };
const MIC_KEYS = { gateEnabled: 'noiseGate.enabled', thresholdDB: 'noiseGate.thresholdDB', attackMs: 'noiseGate.attackMs',
  holdMs: 'noiseGate.holdMs', releaseMs: 'noiseGate.releaseMs', autoThreshold: 'noiseGate.auto', marginDB: 'noiseGate.marginDB',
  highPass: 'highPass.enabled', highPassHz: 'highPass.hz', dropQuietNotes: 'noiseGate.dropQuietNotes' };
const FLOOR_KEYS = { db: 'noiseGate.lastFloorDB', at: 'noiseGate.lastFloorAt' };
const store = (() => { try { localStorage.setItem('__t', '1'); localStorage.removeItem('__t'); return localStorage; } catch { const m = new Map(); return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: (k) => m.delete(k) }; } })();
function loadMicSettings() {
  const s = { ...MIC_DEFAULTS };
  for (const [k, key] of Object.entries(MIC_KEYS)) {
    const v = store.getItem(key);
    if (v == null) continue;
    s[k] = typeof MIC_DEFAULTS[k] === 'boolean' ? v === 'true' : +v;
  }
  if (QS.has('gate')) s.gateEnabled = QS.get('gate') !== '0';   // URL overrides (tests / A-B)
  if (QS.has('hpf')) s.highPass = QS.get('hpf') !== '0';
  return s;
}
function saveMicSettings(s) { for (const [k, key] of Object.entries(MIC_KEYS)) store.setItem(key, String(s[k])); }
function saveFloor(db) { store.setItem(FLOOR_KEYS.db, String(db)); store.setItem(FLOOR_KEYS.at, String(Date.now())); renderFloorRow(); }
state.mic = loadMicSettings();

/** InputConditioner.dropQuietNotes: drop notes whose onset peak (-10…+60 ms) in the conditioned
 *  audio is below the gate threshold minus 3 dB, e.g. notes heard in residual room noise. */
function dropQuietNotes(notes, samples, sr, thresholdDB) {
  if (!samples || !samples.length) return notes;
  const limit = 10 ** ((thresholdDB - 3) / 20);
  return notes.filter((n) => {
    const lo = Math.max(0, Math.floor((n.onset - 0.01) * sr)), hi = Math.min(samples.length, Math.floor((n.onset + 0.06) * sr) + 1);
    if (lo >= hi) return true;
    let peak = 0;
    for (let i = lo; i < hi; i++) { const a = Math.abs(samples[i]); if (a > peak) peak = a; }
    return peak >= limit;
  });
}

function relTime(ms) {
  const s = Math.max(0, (Date.now() - ms) / 1000);
  if (s < 45) return 'just now';
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  if (s < 86400) return `${Math.round(s / 3600)} h ago`;
  return `${Math.round(s / 86400)} days ago`;
}
function renderFloorRow() {
  const at = +store.getItem(FLOOR_KEYS.at) || 0, db = +store.getItem(FLOOR_KEYS.db);
  const m = state.mic;
  if (!at) { $('floor-readout').textContent = 'not measured yet'; $('floor-when').textContent = 'Record, or press Measure now and stay quiet for a second.'; return; }
  const gateAt = m.autoThreshold ? db + m.marginDB : m.thresholdDB;
  $('floor-readout').textContent = `${Math.round(db)} dBFS · gate opens at ${Math.round(gateAt)} dBFS`;
  $('floor-when').textContent = `Measured ${relTime(at)}`;
}
function renderMicSettings() {
  const m = state.mic;
  const set = (id, v) => { $(id).value = v; const o = document.querySelector(`output[for=${id}]`); if (o) o.textContent = v; };
  $('set-gate').checked = m.gateEnabled; $('set-auto').checked = m.autoThreshold; $('set-dropquiet').checked = m.dropQuietNotes;
  $('set-hpf').checked = m.highPass;
  set('set-margin', m.marginDB); set('set-thr', m.thresholdDB); set('set-attack', m.attackMs); set('set-hold', m.holdMs);
  set('set-release', m.releaseMs); set('set-hpfhz', m.highPassHz);
  $('gate-opts').hidden = !m.gateEnabled;
  $('row-margin').hidden = !m.autoThreshold; $('row-thr').hidden = m.autoThreshold;
  $('row-hpf').hidden = !m.highPass;
  $('gate-help').textContent = (m.gateEnabled && m.autoThreshold
    ? `The gate measures the room's steady noise (air conditioning, fans) in the first half second and the quiet moments, and opens ${m.marginDB} dB above it.`
    : 'Mutes the mic below the threshold so background noise isn\'t transcribed. Raise the threshold in noisy rooms.') +
    (m.highPass ? ` The rumble filter cuts hum and rumble below ${m.highPassHz} Hz; low piano notes keep their overtones.` : '') +
    ' Applies to the mic (live recording); uploaded files are used as they are.';
  renderFloorRow();
}
function wireMicSettings() {
  const upd = () => { saveMicSettings(state.mic); renderMicSettings(); if (state.live) state.live.node.port.postMessage({ settings: state.mic }); };
  const bool = { 'set-gate': 'gateEnabled', 'set-auto': 'autoThreshold', 'set-dropquiet': 'dropQuietNotes', 'set-hpf': 'highPass' };
  const num = { 'set-margin': 'marginDB', 'set-thr': 'thresholdDB', 'set-attack': 'attackMs', 'set-hold': 'holdMs', 'set-release': 'releaseMs', 'set-hpfhz': 'highPassHz' };
  for (const [id, k] of Object.entries(bool)) $(id).onchange = () => { state.mic[k] = $(id).checked; upd(); };
  for (const [id, k] of Object.entries(num)) $(id).oninput = () => { state.mic[k] = +$(id).value; upd(); };
  $('set-reset').onclick = () => { state.mic = { ...MIC_DEFAULTS }; upd(); };
  $('measure-btn').onclick = measureFloor;
  renderMicSettings();
}

// Mic access with readable errors (iOS: "Microphone access is denied. Enable it in Settings…").
async function openMic() {
  if (!window.isSecureContext || !navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) throw new Error('The microphone needs a secure (https) page and a browser with getUserMedia.');
  try {
    return await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false, channelCount: 1 } });
  } catch (e) {
    const msg = { NotAllowedError: 'Microphone access is denied. Allow it in the browser\'s site settings to listen.',
      SecurityError: 'Microphone access is blocked on this page.',
      NotFoundError: 'No microphone was found. Plug one in and try again.',
      NotReadableError: 'The microphone is busy (another app or tab may be using it). Close it and try again.',
      OverconstrainedError: 'The microphone does not support the requested settings.',
      AbortError: 'The microphone could not be started. Try again.' }[e && e.name];
    throw new Error(msg || `Microphone unavailable: ${e && e.message}`);
  }
}
async function micGraph(stream, settings) {
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
  const node = new AudioWorkletNode(ctx, 'earsheet-capture', { numberOfInputs: 1, numberOfOutputs: 1, channelCount: 1, channelCountMode: 'explicit', processorOptions: { settings } });
  const mute = ctx.createGain(); mute.gain.value = 0;
  src.connect(node); node.connect(mute); mute.connect(ctx.destination);
  if (ctx.state !== 'running') { try { await ctx.resume(); } catch { } }
  return { ctx, src, node, resampler };
}
function micNotice(text) { $('mic-notice').textContent = text || ''; $('mic-notice').hidden = !text; }

/** Settings > Measure now: listens ~1.2 s (stay quiet) and stores the floor; nothing is kept. */
async function measureFloor() {
  if (state.live) return;
  const b = $('measure-btn');
  b.disabled = true; b.textContent = 'Measuring… stay quiet';
  let stream, g;
  try {
    stream = await openMic();
    g = await micGraph(stream, state.mic);
    let floor = null;
    g.node.port.onmessage = (e) => { if (e.data.floorDB != null) floor = e.data.floorDB; };
    await new Promise((r) => setTimeout(r, 1200));
    if (floor != null) saveFloor(floor); else micNotice('No audio arrived from the microphone while measuring.');
  } catch (e) { micNotice(e.message); }
  finally {
    if (g) { g.node.port.onmessage = null; g.ctx.close(); }
    if (stream) stream.getTracks().forEach((t) => t.stop());
    b.disabled = false; b.textContent = 'Measure now';
  }
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
  state.take = { source: 'file' };
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
  if (state.live) return;
  micNotice('');
  let stream, g;
  try {
    stream = await openMic();
    g = await micGraph(stream, state.mic);
  } catch (e) {
    if (stream) stream.getTracks().forEach((t) => t.stop());
    micNotice(e.message); state.micError = e.message;
    return;
  }
  stop();
  resetFrames();
  state.lastMode = 'live';
  state.latencies = []; state.timeline = [];
  const { ctx, node, resampler } = g;
  const settings = { ...state.mic };
  state.take = { source: 'live', gateEnabled: settings.gateEnabled, dropQuiet: settings.dropQuietNotes, thresholdDB: null, floorDB: null };

  const live = state.live = {
    stream, ctx, node, src: g.src, chunks: [], samples: 0, wallStart: 0, inferMs: 0, windows: 0,
    frozen: [], prov: [], frozenUntil: 0, seen: new Map(), decodePending: false,
    behind: 0, stopping: false, rate: ctx.sampleRate, lastBlockAt: 0, floorSaved: false, interruptions: 0,
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
    let x = e.data.x;
    const t = performance.now();
    if (resampler) x = resampler.process(x);
    // (Re)anchor the live clock on the first block and after any gap (interruption, device switch).
    if (!live.samples || t - live.lastBlockAt > 400) live.wallStart = t - ((live.samples + x.length) / SR) * 1000;
    live.lastBlockAt = t;
    live.chunks.push(x); live.samples += x.length;
    state.take.floorDB = e.data.floorDB; state.take.thresholdDB = settings.gateEnabled ? e.data.thresholdDB : null;
    if (e.data.floorDB != null && !live.floorSaved) { live.floorSaved = true; saveFloor(e.data.floorDB); }
    worker.postMessage({ t: 'push', id: live.id, samples: x });
    if (live.samples >= MAX_SECONDS * SR) stopLive();
  };
  watchMic(live);
  setRecordingUi(true);
  $('results').hidden = false;
  $('audio-info').textContent = `Live: mic at ${ctx.sampleRate} Hz${resampler ? ' (resampled in JS)' : ''} → ${SR} Hz mono · windows every ${(LIVE_HOP * 256 / SR).toFixed(2)} s`;
  const tick = () => {
    if (state.live !== live) return;
    const now = liveNow();
    const tk = state.take;
    $('rec-time').textContent = `${now.toFixed(1)} s` + (tk.floorDB != null ? ` · noise floor ${Math.round(tk.floorDB)} dBFS${tk.thresholdDB != null ? ` · gate ${Math.round(tk.thresholdDB)} dBFS` : ''}` : (settings.gateEnabled ? ' · measuring noise floor…' : ''));
    drawRoll({ live: true, now });
    live.raf = requestAnimationFrame(tick);
  };
  live.raf = requestAnimationFrame(tick);
}

/** Mic robustness (iOS AudioRecorder restarts on interruption end / route change): resume a
 *  suspended or interrupted AudioContext, and re-open the mic when its track ends (unplugged,
 *  revoked, device switched). If the mic can't come back, stop and keep what was recorded. */
function watchMic(live) {
  const resume = () => {
    if (state.live !== live || live.stopping) return;
    if (live.ctx.state !== 'running' && live.ctx.state !== 'closed') {
      micNotice('The microphone was interrupted; resuming…');
      live.ctx.resume().then(() => { if (live.ctx.state === 'running') micNotice(''); }).catch(() => {});
    }
  };
  live.ctx.onstatechange = () => { if (live.ctx.state !== 'running') { live.interruptions++; setTimeout(resume, 250); } else micNotice(''); };
  live.onVisibility = () => { if (document.visibilityState === 'visible') resume(); };
  document.addEventListener('visibilitychange', live.onVisibility);
  const reopen = async () => {
    if (state.live !== live || live.stopping || live.reopening) return;
    live.reopening = true; live.interruptions++;
    micNotice('The microphone disconnected; reconnecting…');
    try {
      const stream = await openMic();
      if (state.live !== live || live.stopping) { stream.getTracks().forEach((t) => t.stop()); return; }
      try { live.src.disconnect(); } catch { }
      live.stream.getTracks().forEach((t) => t.stop());
      live.stream = stream;
      live.src = live.ctx.createMediaStreamSource(stream);
      live.src.connect(live.node);
      hookTrack();
      resume();
      micNotice('');
    } catch (e) {
      micNotice(`${e.message} The take was stopped; what was recorded is kept.`);
      stopLive();
    } finally { live.reopening = false; }
  };
  const hookTrack = () => { const tr = live.stream.getAudioTracks()[0]; if (tr) tr.onended = reopen; };
  hookTrack();
  live.onDeviceChange = () => { const tr = live.stream.getAudioTracks()[0]; if (!tr || tr.readyState === 'ended') reopen(); };
  if (navigator.mediaDevices.addEventListener) navigator.mediaDevices.addEventListener('devicechange', live.onDeviceChange);
}

function setRecordingUi(on) {
  $('rec-btn').textContent = on ? '■ Stop' : '● Record (live)';
  $('rec-btn').classList.toggle('recording', on);
  $('rerec-btn').textContent = on ? '■ Stop' : '● Record again';
  $('rerec-btn').classList.toggle('recording', on);
  $('sample-btn').disabled = on; $('run-btn').disabled = on || !state.audio; $('file-label').classList.toggle('disabled', on);
  $('measure-btn').disabled = on;
  for (const b of ['play-btn', 'play-orig-btn', 'midi-btn', 'view-page']) $(b).disabled = on;
  $('live-badge').hidden = !on;
  if (!on) $('rec-time').textContent = '';
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
  live.ctx.onstatechange = null;
  document.removeEventListener('visibilitychange', live.onVisibility);
  if (navigator.mediaDevices.removeEventListener) navigator.mediaDevices.removeEventListener('devicechange', live.onDeviceChange);
  live.stream.getTracks().forEach((t) => { t.onended = null; t.stop(); });
  live.ctx.close();
  if (state.take && state.take.floorDB != null) saveFloor(state.take.floorDB);
  $('rec-btn').disabled = true; $('rec-btn').textContent = 'Finishing…'; $('rerec-btn').disabled = true;
  return new Promise((resolve) => {
    live.onEnd = () => {
      const all = new Float32Array(live.samples);
      let o = 0; for (const c of live.chunks) { all.set(c, o); o += c.length; }
      setAudio(all, new Blob([encodeWav(all, SR)], { type: 'audio/wav' }));
      const audioSec = all.length / SR;
      state.lastInference = { ms: live.inferMs, inferMs: live.inferMs, audioSec, windows: live.windows, backend: state.backend, msPerWindow: live.inferMs / live.windows, rtf: audioSec / (live.inferMs / 1000) };
      state.live = null;
      $('rec-btn').disabled = false; $('rerec-btn').disabled = false;
      setRecordingUi(false);
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
function setView(v) {
  state.view = v;
  $('view-roll').classList.toggle('on', v === 'roll'); $('view-roll').setAttribute('aria-selected', v === 'roll');
  $('view-page').classList.toggle('on', v === 'page'); $('view-page').setAttribute('aria-selected', v === 'page');
  $('roll-view').hidden = v !== 'roll';
  $('page-view').hidden = v !== 'page';
  if (v !== 'page') $('tempo-panel').hidden = true;
  if (v === 'page' && !state.live) renderPage();
  else if (v === 'roll' && !state.live && state.F.length) requestAnimationFrame(() => drawRoll({}));
  updateSummary();
}

/** Header line. Before the analysis: note count and duration only (no tempo/key guesses). */
function updateSummary() {
  const n = state.notes.length;
  const dur = state.audio ? state.audio.length / SR : state.F.length / FPS;
  const noteText = `${n} note${n === 1 ? '' : 's'}`;
  const dropped = state.droppedQuiet ? ` · ${state.droppedQuiet} quiet note${state.droppedQuiet === 1 ? '' : 's'} ignored` : '';
  const sheet = state.live ? null : currentSheet();
  $('summary').textContent = sheet
    ? `${metronomeMark(sheet.bpm)} · ${sheet.meter} · ${keyName(sheet.key)} · ${noteText}${dropped}`
    : `${noteText} · ${dur.toFixed(1)} s${dropped}`;
}

/** Page view: runs the whole-take analysis (cached) and engraves it. */
function renderPage() {
  const s = sheetScore();
  updateSummary();
  $('tempo-mark').textContent = metronomeMark(s.bpm);
  $('tempo-note').textContent = state.tempoOverride == null ? 'Assumed tempo' : 'Assumed tempo (set by you)';
  $('tempo-btn').setAttribute('aria-label', `Assumed tempo, quarter note equals ${Math.round(s.bpm)}`);
  $('tempo-num').value = Math.round(s.bpm); $('tempo-slider').value = Math.round(s.bpm);
  $('tempo-est').textContent = `Use estimated tempo (${Math.round(estimatedTempo())})`;
  $('tempo-est').disabled = state.tempoOverride == null;
  $('quant-info').textContent = s.notes.length ? `${s.meter} · ${keyName(s.key)} · 16th grid` : '';
  const abc = toAbc(s);
  state.abc = abc;
  if (abc && window.ABCJS) {
    const w = Math.max(320, $('staff').clientWidth - 24);
    // Engraving settings matched to the iOS Engraver (build 13): full-width justified systems
    // (wrap + stretchlast), ~4 bars per system, room for accidental columns, one stem per chord.
    window.ABCJS.renderAbc('staff', abc, {
      add_classes: true, paddingtop: 4, paddingbottom: 8, paddingleft: 4, paddingright: 4,
      staffwidth: w, scale: 1, responsive: 'resize',
      wrap: { minSpacing: 1.6, maxSpacing: 2.6, preferredMeasuresPerLine: 4 },
    });
  } else $('staff').innerHTML = '<p style="color:#555;padding:8px">No notes detected.</p>';
}

function renderFinal() {
  $('results').hidden = false;
  updateSummary();
  if (state.view === 'page') renderPage(); else drawRoll({});
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
  // Beat grid once the sheet analysis has run (iOS: roll beat grid after analysis).
  const sheet = live ? null : currentSheet();
  if (sheet && sheet.notes.length) {
    const q = sheet.sixteenth * 4, bar = METERS[sheet.meter].bar16 * sheet.sixteenth;
    for (let k = 0, tb = sheet.barPhase; tb <= t1; k++, tb = sheet.barPhase + k * q) {
      if (tb < t0) continue;
      const isBar = Math.abs(((tb - sheet.barPhase) / bar) - Math.round((tb - sheet.barPhase) / bar)) < 1e-6;
      ctx.fillStyle = isBar ? 'rgba(255,255,255,0.22)' : 'rgba(255,255,255,0.07)';
      ctx.fillRect(x(tb), 0, isBar ? 1.5 * dpr : 1, h);
    }
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
  const sheet = sheetScore(); // export runs the analysis (cached), like the iOS export
  updateSummary();
  state.exported = true;
  const midi = new Midi();
  midi.header.setTempo(sheet.bpm);
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
  // Re-record is always visible on the take; an un-exported take asks first (iOS: held takes
  // record again in place after confirm).
  $('rerec-btn').onclick = () => {
    if (state.live) { stopLive(); return; }
    if (state.notes.length && !state.exported && !QS.has('noConfirm') &&
        !confirm('Record a new take? This take isn\'t saved: recording again replaces it (Download MIDI first to keep it).')) return;
    startLive();
  };
  $('view-roll').onclick = () => setView('roll');
  $('view-page').onclick = () => setView('page');
  $('tempo-btn').onclick = () => { $('tempo-panel').hidden = !$('tempo-panel').hidden; };
  $('tempo-done').onclick = () => { $('tempo-panel').hidden = true; };
  const curBpm = () => Math.round((currentSheet() || sheetScore()).bpm);
  $('tempo-dec').onclick = () => setTempo(curBpm() - 1);
  $('tempo-inc').onclick = () => setTempo(curBpm() + 1);
  $('tempo-num').onchange = () => { const v = +$('tempo-num').value; if (v > 0) setTempo(v); };
  $('tempo-slider').oninput = () => { $('tempo-num').value = $('tempo-slider').value; $('tempo-mark').textContent = metronomeMark(+$('tempo-slider').value); };
  $('tempo-slider').onchange = () => setTempo(+$('tempo-slider').value);
  $('tempo-half').onclick = () => setTempo(curBpm() / 2);
  $('tempo-double').onclick = () => setTempo(curBpm() * 2);
  $('tempo-est').onclick = () => setTempo(null);
  // Tap tempo: average of the last few tap intervals (a pause over 2 s starts over).
  let taps = [];
  $('tempo-tap').onclick = () => {
    const now = performance.now();
    if (taps.length && now - taps[taps.length - 1] > 2000) taps = [];
    taps.push(now); taps = taps.slice(-5);
    if (taps.length >= 2) setTempo(60000 / ((taps[taps.length - 1] - taps[0]) / (taps.length - 1)));
    $('tempo-tap').textContent = taps.length >= 2 ? `Tap tempo (${taps.length})` : 'Tap tempo…';
  };
  wireMicSettings();
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
  window.addEventListener('resize', () => { if (!state.live && state.notes.length) { if (state.view === 'page') renderPage(); else drawRoll({}); } });
  state.api = { setView, setTempo, sheetScore, currentSheet, estimatedTempo, dropQuietNotes, startLive, stopLive };
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
