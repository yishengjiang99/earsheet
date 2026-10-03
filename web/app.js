// SPDX-License-Identifier: AGPL-3.0-or-later
// EarSheet web demo: Basic Pitch (Spotify, Apache-2.0) in the browser via TF.js.
import { tf, tfwasm, BasicPitch, outputToNotesPoly, addPitchBendsToNoteEvents, noteFramesToTime, Midi } from './vendor/lib.js';
import { quantize, toAbc, keyName, midiName } from './quantize.js';

const SR = 22050;
const FPS = SR / 256;            // model frames per second (~86.13)
const WINDOW = 43844;            // samples per model window
const MAX_SECONDS = 300;
const MODEL_URL = new URL('model/model.json', import.meta.url).href;
const $ = (id) => document.getElementById(id);

const state = {
  backend: null, model: null, bp: null, warmupMs: 0,
  audio: null, audioUrl: null, raw: null, notes: [], score: null,
  lastResult: null, error: null, ready: false,
};
window.__earsheet = state; // for the headless test

// ---------------------------------------------------------------- backend --
function webglRenderer() {
  try {
    const gl = document.createElement('canvas').getContext('webgl2');
    if (!gl) return null;
    const ext = gl.getExtension('WEBGL_debug_renderer_info');
    return ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
  } catch { return null; }
}

// In auto mode, software GPU emulation (SwiftShader / fallback adapters) is skipped:
// it is far slower than WASM SIMD on the same CPU. A forced backend is always tried.
async function tryBackend(name, auto) {
  state.device = '';
  if (name === 'webgpu') {
    if (!('gpu' in navigator)) throw new Error('WebGPU not supported by this browser');
    const adapter = await navigator.gpu.requestAdapter({ powerPreference: 'high-performance' });
    if (!adapter) throw new Error('no WebGPU adapter');
    const info = adapter.info || {};
    state.device = [info.vendor, info.architecture, info.description].filter(Boolean).join(' / ');
    if (auto && (info.isFallbackAdapter || /swiftshader/i.test(state.device))) throw new Error(`software adapter (${state.device})`);
  }
  if (name === 'webgl') {
    const r = webglRenderer();
    if (!r) throw new Error('WebGL2 not available');
    state.device = r;
    if (auto && /swiftshader|llvmpipe|software/i.test(r)) throw new Error(`software renderer (${r})`);
  }
  if (name === 'wasm') tfwasm.setWasmPaths(new URL('vendor/', import.meta.url).href);
  const ok = await tf.setBackend(name);
  if (!ok) throw new Error(`setBackend(${name}) returned false`);
  await tf.ready();
  if (!state.model) state.model = await tf.loadGraphModel(MODEL_URL);
  // Warm-up: compiles shaders / kernels and proves every op runs on this backend.
  const t0 = performance.now();
  const outs = tf.tidy(() => state.model.execute(tf.zeros([1, WINDOW, 1]), ['Identity_1', 'Identity_2', 'Identity']));
  await Promise.all(outs.map((t) => t.data()));
  outs.forEach((t) => t.dispose());
  state.warmupMs = performance.now() - t0;
}

async function initBackend(pref) {
  const order = pref && pref !== 'auto' ? [pref] : ['webgpu', 'webgl', 'wasm', 'cpu'];
  const failures = [];
  $('backend').textContent = 'initialising…';
  for (const name of order) {
    try {
      await tryBackend(name, order.length > 1);
      state.backend = name;
      state.bp = new BasicPitch(Promise.resolve(state.model));
      $('backend').textContent = name;
      $('backend').className = 'ok';
      let note = `${state.device ? state.device + ' · ' : ''}warm-up ${state.warmupMs.toFixed(0)} ms`;
      if (failures.length) note += ` · skipped ${failures.map((f) => f.name).join(', ')}`;
      $('backend-note').textContent = note;
      $('backend-note').title = failures.map((f) => `${f.name}: ${f.err}`).join('\n');
      $('model-status').textContent = 'Basic Pitch ICASSP 2022 (TF.js, 0.9 MB) ready';
      state.ready = true;
      state.backendFailures = failures;
      return;
    } catch (e) {
      console.warn(`backend ${name} failed`, e);
      failures.push({ name, err: String(e && e.message || e) });
    }
  }
  $('backend').textContent = 'none available';
  state.error = 'no backend: ' + JSON.stringify(failures);
  throw new Error(state.error);
}

// ------------------------------------------------------------------ audio --
async function toMono22k(arrayBuffer) {
  const ctx = new (window.AudioContext || window.webkitAudioContext)();
  const decoded = await ctx.decodeAudioData(arrayBuffer);
  ctx.close();
  const seconds = Math.min(decoded.duration, MAX_SECONDS);
  const off = new OfflineAudioContext(1, Math.ceil(seconds * SR), SR);
  const src = off.createBufferSource();
  src.buffer = decoded;
  src.connect(off.destination);
  src.start();
  const rendered = await off.startRendering();
  return { samples: rendered.getChannelData(0), origRate: decoded.sampleRate, origChannels: decoded.numberOfChannels, truncated: decoded.duration > MAX_SECONDS, duration: decoded.duration };
}

async function loadAudio(blob, label) {
  const info = await toMono22k(await blob.arrayBuffer());
  state.audio = info.samples;
  if (state.audioUrl) URL.revokeObjectURL(state.audioUrl);
  state.audioUrl = URL.createObjectURL(blob);
  $('audio-el').src = state.audioUrl;
  $('audio-el').hidden = false;
  $('audio-info').textContent = `${label}: ${info.duration.toFixed(2)} s, ${info.origRate} Hz × ${info.origChannels} ch → ${SR} Hz mono${info.truncated ? ` (first ${MAX_SECONDS} s only)` : ''}`;
  $('run-btn').disabled = !state.ready;
  return info;
}

function synthSample() {
  // C major scale, then a C major triad, as a plain additive-synth WAV.
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

// ------------------------------------------------------------- recording --
let recorder = null, recChunks = [], recStart = 0, recTimer = null;
async function toggleRecord() {
  if (recorder) { recorder.stop(); return; }
  let stream;
  try {
    stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false } });
  } catch (e) { alert('Microphone unavailable: ' + e.message); return; }
  recChunks = [];
  recorder = new MediaRecorder(stream);
  recorder.ondataavailable = (e) => e.data.size && recChunks.push(e.data);
  recorder.onstop = async () => {
    stream.getTracks().forEach((t) => t.stop());
    clearInterval(recTimer);
    $('rec-btn').textContent = '● Record'; $('rec-btn').classList.remove('recording');
    const blob = new Blob(recChunks, { type: recorder.mimeType });
    recorder = null;
    $('rec-time').textContent = '';
    await loadAudio(blob, 'Recording');
    run();
  };
  recorder.start();
  recStart = performance.now();
  $('rec-btn').textContent = '■ Stop recording'; $('rec-btn').classList.add('recording');
  recTimer = setInterval(() => {
    const s = (performance.now() - recStart) / 1000;
    $('rec-time').textContent = `${s.toFixed(1)} s`;
    if (s >= MAX_SECONDS) recorder && recorder.stop();
  }, 100);
}

// --------------------------------------------------------------- inference --
async function run() {
  if (!state.audio || !state.ready) return;
  $('run-btn').disabled = true;
  $('progress').hidden = false; $('progress').value = 0;
  $('timing').textContent = 'running…';
  const frames = [], onsets = [], contours = [];
  let windows = 0;
  tf.engine().startScope();
  const t0 = performance.now();
  try {
    await state.bp.evaluateModel(state.audio, (f, o, c) => {
      frames.push(...f); onsets.push(...o); contours.push(...c);
    }, (p) => { if (p < 1) windows++; $('progress').value = p; });
  } finally {
    tf.engine().endScope();
  }
  const ms = performance.now() - t0;
  const audioSec = state.audio.length / SR;
  state.raw = { frames, onsets, contours };
  state.lastInference = { ms, audioSec, windows, backend: state.backend, msPerWindow: ms / windows, rtf: audioSec / (ms / 1000) };
  $('timing').textContent = `${state.backend}: ${ms.toFixed(0)} ms for ${audioSec.toFixed(1)} s of audio (${windows} windows, ${(ms / windows).toFixed(0)} ms/window, ${state.lastInference.rtf.toFixed(1)}× real time)`;
  $('progress').hidden = true;
  $('run-btn').disabled = false;
  decode();
}

function decode() {
  if (!state.raw) return;
  const { frames, onsets, contours } = state.raw;
  const onsetTh = +$('onset-th').value, frameTh = +$('frame-th').value;
  const minLen = Math.max(1, Math.round((+$('min-note').value / 1000) * FPS));
  const ev = outputToNotesPoly(frames, onsets, onsetTh, frameTh, minLen, true, null, null, true, 11);
  const timed = noteFramesToTime(addPitchBendsToNoteEvents(contours, ev));
  state.notes = timed.map((n) => ({ midi: n.pitchMidi, onset: n.startTimeSeconds, offset: n.startTimeSeconds + n.durationSeconds, velocity: n.amplitude }))
    .sort((a, b) => a.onset - b.onset || a.midi - b.midi);
  state.score = quantize(state.notes);
  state.lastResult = {
    backend: state.backend,
    inference: state.lastInference,
    notes: state.notes.map((n) => ({ midi: n.midi, name: midiName(n.midi), onset: +n.onset.toFixed(3), offset: +n.offset.toFixed(3), velocity: +n.velocity.toFixed(2) })),
    bpm: state.score.bpm, meter: state.score.meter, key: keyName(state.score.key),
  };
  render();
}

// ----------------------------------------------------------------- render --
function render() {
  $('results').hidden = false;
  const s = state.score;
  $('summary').textContent = `${state.notes.length} notes`;
  $('quant-info').textContent = s.notes.length ? `≈${Math.round(s.bpm)} BPM · ${s.meter} · ${keyName(s.key)} · 16th grid${s.notes.length && Math.max(...s.notes.map((n) => n.start16)) / 16 > 24 ? ' · first 24 bars' : ''}` : '';
  drawRoll(-1);
  const abc = toAbc(s);
  state.abc = abc;
  if (abc && window.ABCJS) {
    window.ABCJS.renderAbc('staff', abc, { responsive: 'resize', add_classes: true, paddingtop: 0 });
  } else {
    $('staff').innerHTML = '<p style="color:#555;padding:8px">No notes detected.</p>';
  }
  const tb = $('note-table').querySelector('tbody');
  tb.innerHTML = state.notes.map((n, i) => `<tr><td>${i + 1}</td><td>${midiName(n.midi)}</td><td>${n.midi}</td><td>${n.onset.toFixed(3)}</td><td>${(n.offset - n.onset).toFixed(3)}</td><td>${n.velocity.toFixed(2)}</td></tr>`).join('');
}

function drawRoll(playhead) {
  const c = $('roll'), ctx = c.getContext('2d');
  const dpr = window.devicePixelRatio || 1;
  const W = Math.round(c.clientWidth * dpr), H = Math.round(320 * dpr);
  if (c.width !== W) c.width = W;
  if (c.height !== H) c.height = H;
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.fillStyle = '#0b0d11'; ctx.fillRect(0, 0, c.width, c.height);
  const dur = state.audio ? state.audio.length / SR : 1;
  const notes = state.notes;
  let lo = 48, hi = 84;
  if (notes.length) { lo = Math.min(...notes.map((n) => n.midi)) - 3; hi = Math.max(...notes.map((n) => n.midi)) + 3; }
  if (hi - lo < 24) { const mid = (hi + lo) / 2; lo = Math.floor(mid - 12); hi = Math.ceil(mid + 12); }
  const left = 34 * dpr, w = c.width - left, h = c.height;
  const rowH = h / (hi - lo + 1);
  const x = (t) => left + (t / dur) * w;
  const y = (m) => h - (m - lo + 1) * rowH;
  // Keyboard lanes
  for (let m = lo; m <= hi; m++) {
    const black = [1, 3, 6, 8, 10].includes(m % 12);
    ctx.fillStyle = black ? '#10131a' : '#151922';
    ctx.fillRect(left, y(m), w, rowH);
    if (m % 12 === 0) { ctx.fillStyle = '#8890a0'; ctx.font = `${10 * dpr}px system-ui`; ctx.fillText(midiName(m), 2 * dpr, y(m) + rowH - 1); ctx.fillStyle = '#2a2f3a'; ctx.fillRect(left, y(m) + rowH - 1, w, 1); }
  }
  // Frame posteriors (faint) behind the notes
  if (state.raw) {
    const fr = state.raw.frames;
    const step = Math.max(1, Math.floor(fr.length / w));
    for (let i = 0; i < fr.length; i += step) {
      const t = i / FPS;
      for (let m = lo; m <= hi; m++) {
        const v = fr[i][m - 21];
        if (v > 0.15) { ctx.fillStyle = `rgba(90,169,255,${(v * 0.35).toFixed(2)})`; ctx.fillRect(x(t), y(m), Math.max(1, (step / FPS) / dur * w), rowH); }
      }
    }
  }
  for (const n of notes) {
    const active = playhead >= n.onset && playhead < n.offset;
    ctx.fillStyle = active ? '#ffd166' : `hsl(${210 - n.velocity * 160}, 80%, ${45 + n.velocity * 20}%)`;
    ctx.fillRect(x(n.onset), y(n.midi) + 1, Math.max(2, x(n.offset) - x(n.onset)), Math.max(2, rowH - 2));
  }
  if (playhead >= 0) { ctx.fillStyle = '#fff'; ctx.fillRect(x(playhead), 0, 1.5 * dpr, h); }
}

// --------------------------------------------------------------- playback --
let actx = null, playing = null;
function stop() {
  if (playing) { playing.nodes.forEach((n) => { try { n.stop(); } catch {} }); cancelAnimationFrame(playing.raf); playing = null; }
  $('audio-el').pause();
  drawRoll(-1);
}
function playNotes() {
  stop();
  actx = actx || new AudioContext();
  const t0 = actx.currentTime + 0.1;
  const master = actx.createGain(); master.gain.value = 0.25; master.connect(actx.destination);
  const nodes = [];
  for (const n of state.notes) {
    const f = 440 * 2 ** ((n.midi - 69) / 12);
    const o = actx.createOscillator(), g = actx.createGain();
    o.type = 'triangle'; o.frequency.value = f;
    const a = t0 + n.onset, e = t0 + n.offset, peak = 0.15 + 0.5 * n.velocity;
    g.gain.setValueAtTime(0, a); g.gain.linearRampToValueAtTime(peak, a + 0.01);
    g.gain.exponentialRampToValueAtTime(peak * 0.4, Math.max(a + 0.02, e)); g.gain.linearRampToValueAtTime(0, e + 0.08);
    o.connect(g).connect(master); o.start(a); o.stop(e + 0.1); nodes.push(o);
  }
  const end = Math.max(0, ...state.notes.map((n) => n.offset)) + 0.2;
  playing = { nodes, raf: 0 };
  const tick = () => {
    const t = actx.currentTime - t0;
    drawRoll(t);
    if (t < end && playing) playing.raf = requestAnimationFrame(tick); else stop();
  };
  playing.raf = requestAnimationFrame(tick);
}
function playOriginal() {
  stop();
  const el = $('audio-el');
  el.currentTime = 0; el.play();
  playing = { nodes: [], raf: 0 };
  const tick = () => { drawRoll(el.currentTime); if (!el.paused && playing) playing.raf = requestAnimationFrame(tick); };
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
function wire() {
  $('rec-btn').onclick = toggleRecord;
  $('file-input').onchange = async (e) => {
    const f = e.target.files[0]; if (!f) return;
    try { await loadAudio(f, f.name); await run(); } catch (err) { state.error = String(err); $('audio-info').textContent = 'Could not read audio: ' + err.message; }
  };
  $('sample-btn').onclick = async () => { await loadAudio(synthSample(), 'Sample (C major scale + triad)'); await run(); };
  $('run-btn').onclick = run;
  $('play-btn').onclick = playNotes;
  $('play-orig-btn').onclick = playOriginal;
  $('stop-btn').onclick = stop;
  $('midi-btn').onclick = downloadMidi;
  for (const id of ['onset-th', 'frame-th', 'min-note']) {
    $(id).oninput = () => { document.querySelector(`output[for=${id}]`).textContent = $(id).value; };
    $(id).onchange = decode;
  }
  window.addEventListener('resize', () => state.notes.length && drawRoll(-1));
  const params = new URLSearchParams(location.search);
  const pref = params.get('backend') || 'auto';
  $('backend-select').value = pref;
  $('backend-select').onchange = (e) => {
    const p = new URLSearchParams(location.search); p.set('backend', e.target.value); location.search = p.toString();
  };
  if (!window.MediaRecorder || !navigator.mediaDevices) $('rec-btn').title = 'Recording not supported in this browser';
  initBackend(pref).then(() => {
    $('rec-btn').disabled = !(window.MediaRecorder && navigator.mediaDevices);
    $('sample-btn').disabled = false;
    $('run-btn').disabled = !state.audio;
  }).catch((e) => { $('model-status').textContent = 'failed: ' + e.message; });
}
wire();
