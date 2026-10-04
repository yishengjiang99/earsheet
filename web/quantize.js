// SPDX-License-Identifier: AGPL-3.0-or-later
// JS port of Packages/HearSheet/Sources/HearSheet/Quantize.swift (tempo, meter,
// key, 16th snapping) plus a small ABC writer for the staff view.

const MAJOR = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88];
const MINOR = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17];
export const METERS = {
  '4/4': { beats: 4, unit: 4, bar16: 16 },
  '3/4': { beats: 3, unit: 4, bar16: 12 },
  '6/8': { beats: 6, unit: 8, bar16: 12 },
};

const fmod = (a, b) => { const r = a % b; return r < 0 ? r + b : r; };

function estimateBeat(onsets) {
  if (onsets.length < 2) return [0.5, onsets[0] ?? 0];
  const iois = [];
  for (let i = 1; i < onsets.length; i++) {
    const d = onsets[i] - onsets[i - 1];
    if (d > 0.05 && d < 3.0) iois.push(d);
  }
  if (!iois.length) return [0.5, onsets[0]];
  const hist = new Map();
  for (const ioi of iois) {
    const b = Math.floor((ioi - 0.1) / 0.02);
    if (b >= 0 && b < 95) hist.set(b, (hist.get(b) || 0) + 1);
  }
  const peaks = [...hist.entries()].sort((a, b) => b[1] - a[1]).slice(0, 4).map(([k]) => 0.1 + k * 0.02 + 0.01);
  let cands = [];
  for (const p of peaks) for (const m of [0.5, 1, 2]) { const q = p * m; if (q >= 0.3 && q <= 1.5) cands.push(q); }
  if (!cands.length) cands = [0.5];
  let best = [cands[0], onsets[0]], bestScore = -1;
  for (const q of cands) {
    const [phase, raw] = bestPhase(onsets, q);
    const score = raw * (1 + 0.05 * Math.exp(-(((60 / q - 90) / 60) ** 2))); // mild prior near 90 BPM
    if (score > bestScore) { bestScore = score; best = [q, phase]; }
  }
  return best;
}

/** Best beat-grid phase for a fixed quarter length (Quantize.swift bestPhase), at or before the first onset. */
function bestPhase(onsets, q) {
  let best = [onsets[0], -1];
  for (const anchor of onsets.slice(0, 3)) {
    const phase = anchor % q;
    let score = 0;
    const tol = 0.10 * q;
    for (const o of onsets) {
      let d = fmod(o - phase, q);
      d = Math.min(d, q - d);
      if (d < tol) score += 1 - d / tol;
    }
    if (score > best[1]) best = [phase, score];
  }
  let phase = best[0];
  while (phase > onsets[0]) phase -= q;
  return [phase, best[1]];
}

function estimateMeter(onsets, quarterLen, beatPhase) {
  const meters = [['4/4', 1.6], ['3/4', 1.0], ['6/8', 1.0]];
  let bestMeter = '4/4', bestPhase = beatPhase, bestScore = -1;
  for (const [name, prior] of meters) {
    const m = METERS[name];
    const barLen = m.beats * (4 / m.unit) * quarterLen;
    for (const anchor of onsets.slice(0, 3)) {
      let phase = anchor % barLen;
      while (phase > onsets[0]) phase -= barLen;
      let score = 0;
      const tol = 0.12 * barLen;
      for (const o of onsets) {
        let d = fmod(o - phase, barLen);
        d = Math.min(d, barLen - d);
        if (d < tol) score += 1 - d / tol;
      }
      score *= prior;
      if (score > bestScore) { bestScore = score; bestMeter = name; bestPhase = phase; }
    }
  }
  return [bestMeter, bestPhase];
}

function estimateKey(notes) {
  const hist = new Array(12).fill(0);
  for (const n of notes) hist[((n.midi % 12) + 12) % 12] += Math.max(0.05, n.offset - n.onset);
  const total = hist.reduce((a, b) => a + b, 0);
  if (total <= 0) return { tonic: 0, minor: false };
  const norm = hist.map((h) => h / total);
  let best = { tonic: 0, minor: false }, bestCorr = -2;
  for (let t = 0; t < 12; t++) {
    for (const [minor, prof] of [[false, MAJOR], [true, MINOR]]) {
      let c = 0;
      for (let pc = 0; pc < 12; pc++) c += norm[pc] * prof[(pc - t + 24) % 12];
      if (c > bestCorr) { bestCorr = c; best = { tonic: t, minor }; }
    }
  }
  return best;
}

/** Allowed assumed tempo range (quarter-note BPM), as Quantizer.tempoRange. */
export const TEMPO_RANGE = [20, 300];
export const clampTempo = (b) => Math.min(TEMPO_RANGE[1], Math.max(TEMPO_RANGE[0], b));
export const metronomeMark = (bpm) => `\u2669 = ${Math.round(bpm)}`;

/** notes: [{midi, onset, offset, velocity}] in seconds. bpm: assumed quarter-note tempo
 *  (null estimates it; a value skips tempo estimation but still fits the grid phase, meter and key).
 *  The tempo decides note values: the same audio at 2x the BPM reads as notes twice as long. */
export function quantize(events, { bpm = null } = {}) {
  const notes = events.filter((n) => n.midi >= 21 && n.midi <= 108 && n.offset > n.onset).sort((a, b) => a.onset - b.onset);
  if (!notes.length) return { notes: [], bpm: 120, meter: '4/4', key: { tonic: 0, minor: false }, sixteenth: 0.125 };
  const onsets = notes.map((n) => n.onset);
  let [quarter, beatPhase] = estimateBeat(onsets);
  if (bpm) { quarter = 60 / clampTempo(bpm); beatPhase = bestPhase(onsets, quarter)[0]; }
  const [meter, barPhase] = estimateMeter(onsets, quarter, beatPhase);
  const key = estimateKey(notes);
  const s16 = quarter / 4;
  const q = notes.map((n) => {
    const start16 = Math.max(0, Math.round((n.onset - barPhase) / s16));
    const end16 = Math.max(start16 + 1, Math.round((n.offset - barPhase) / s16));
    return { midi: n.midi, velocity: n.velocity, start16, dur16: end16 - start16 };
  });
  q.sort((a, b) => a.start16 - b.start16 || a.midi - b.midi);
  return { notes: q, bpm: 60 / quarter, meter, key, sixteenth: s16, barPhase };
}

// ---- Key signature + ABC --------------------------------------------------

// Fifths for a major tonic pitch class (the circle-of-fifths value indexed by pitch class).
const MAJOR_FIFTHS = [0, -5, 2, -3, 4, -1, 6, 1, -4, 3, -2, 5];
const MAJOR_NAMES = { '-6': 'Gb', '-5': 'Db', '-4': 'Ab', '-3': 'Eb', '-2': 'Bb', '-1': 'F', 0: 'C', 1: 'G', 2: 'D', 3: 'A', 4: 'E', 5: 'B', 6: 'F#' };
const MINOR_NAMES = { '-6': 'Ebm', '-5': 'Bbm', '-4': 'Fm', '-3': 'Cm', '-2': 'Gm', '-1': 'Dm', 0: 'Am', 1: 'Em', 2: 'Bm', 3: 'F#m', 4: 'C#m', 5: 'G#m', 6: 'D#m' };
const wrapFifths = (f) => { while (f > 6) f -= 12; while (f < -6) f += 12; return f; };
export function keyFifths(key) {
  return key.minor ? wrapFifths(MAJOR_FIFTHS[(key.tonic + 3) % 12]) : MAJOR_FIFTHS[key.tonic];
}
export function keyName(key) {
  const f = keyFifths(key);
  return (key.minor ? MINOR_NAMES : MAJOR_NAMES)[f];
}

const LETTERS = ['C', 'D', 'E', 'F', 'G', 'A', 'B'];
const SHARP_SPELL = [[0, 0], [0, 1], [1, 0], [1, 1], [2, 0], [3, 0], [3, 1], [4, 0], [4, 1], [5, 0], [5, 1], [6, 0]];
const FLAT_SPELL = [[0, 0], [1, -1], [1, 0], [2, -1], [2, 0], [3, 0], [4, -1], [4, 0], [5, -1], [5, 0], [6, -1], [6, 0]];
const SHARP_ORDER = [3, 0, 4, 1, 5, 2, 6]; // F C G D A E B (letter indexes)
const FLAT_ORDER = [6, 2, 5, 1, 4, 0, 3];  // B E A D G C F

function keyAccidentals(fifths) {
  const acc = new Array(7).fill(0);
  if (fifths > 0) for (let i = 0; i < fifths; i++) acc[SHARP_ORDER[i]] = 1;
  if (fifths < 0) for (let i = 0; i < -fifths; i++) acc[FLAT_ORDER[i]] = -1;
  return acc;
}

function spell(midi, fifths) {
  const pc = midi % 12;
  const [letter, alter] = (fifths < 0 ? FLAT_SPELL : SHARP_SPELL)[pc];
  const octave = Math.floor((midi - alter) / 12) - 1;
  return { letter, alter, octave };
}

function abcPitch({ letter, octave }) {
  let s = LETTERS[letter];
  if (octave >= 5) { s = s.toLowerCase() + "'".repeat(octave - 5); } else { s += ','.repeat(Math.max(0, 4 - octave)); }
  return s;
}

const PIECES = [16, 12, 8, 6, 4, 3, 2, 1]; // writable lengths in 16ths (whole … 16th, with dots)

/** Splits `len` 16ths starting at bar position `pos` into writable values (Engraver.swift build 13):
 *  an off-beat start first fills its beat, and in 4/4 a note never hides beat 3 (the middle of the
 *  bar) unless it starts the bar. The pieces are tied. */
function writable(pos, len, bar16, beat16) {
  const out = [];
  while (len > 0) {
    const inBar = pos % bar16, off = inBar % beat16;
    let max = len;
    if (off) max = Math.min(max, beat16 - off);
    else if (bar16 === 16 && inBar !== 0 && inBar < 8 && inBar + len > 8) max = Math.min(max, 8 - inBar);
    const p = PIECES.find((v) => v <= max) || 1;
    out.push(p); pos += p; len -= p;
  }
  return out;
}

/** One voice of chords/rests -> ABC body, with bar lines, ties (also across bars/system breaks)
 *  and beams: notes shorter than a beat are written without spaces inside a beat so abcjs beams
 *  them (8ths in pairs, 16ths in fours); a space at every beat breaks the beam. Chords share one
 *  stem ([CEG]); accidentals follow the key signature, reset per bar, per staff position. */
function voiceToAbc(notes, bar16, total16, fifths, beat16) {
  const keyAcc = keyAccidentals(fifths);
  // Group notes by start; chord length = min(own durations, next onset - start).
  const byStart = new Map();
  for (const n of notes) { if (!byStart.has(n.start16)) byStart.set(n.start16, []); byStart.get(n.start16).push(n); }
  const starts = [...byStart.keys()].sort((a, b) => a - b);
  const events = []; // {start, dur, midis|null}
  let t = 0;
  starts.forEach((s, i) => {
    if (s > t) events.push({ start: t, dur: s - t, midis: null });
    const group = byStart.get(s);
    const next = i + 1 < starts.length ? starts[i + 1] : total16;
    const dur = Math.max(1, Math.min(next - s, Math.min(...group.map((g) => g.dur16))));
    const midis = [...new Set(group.map((g) => g.midi))].sort((a, b) => a - b);
    events.push({ start: s, dur, midis });
    t = s + dur;
  });
  if (t < total16) events.push({ start: t, dur: total16 - t, midis: null });

  let out = '';
  let barAcc = new Map(); // "letter,octave" -> alter in effect in this bar
  let pos = 0;
  const tokenFor = (midis, len) => {
    const parts = midis.map((m) => {
      const sp = spell(m, fifths);
      const k = `${sp.letter},${sp.octave}`;
      const cur = barAcc.has(k) ? barAcc.get(k) : keyAcc[sp.letter];
      let a = '';
      if (cur !== sp.alter) { a = sp.alter === 1 ? '^' : sp.alter === -1 ? '_' : '='; barAcc.set(k, sp.alter); }
      return a + abcPitch(sp);
    });
    const body = parts.length === 1 ? parts[0] : `[${parts.join('')}]`;
    return body + (len === 1 ? '' : String(len));
  };
  for (const ev of events) {
    let remaining = ev.dur;
    while (remaining > 0) {
      const chunk = Math.min(remaining, bar16 - (pos % bar16));
      const pieces = writable(pos, chunk, bar16, beat16);
      pieces.forEach((p, i) => {
        const tied = !(i === pieces.length - 1 && remaining - chunk === 0);
        out += ev.midis ? tokenFor(ev.midis, p) + (tied ? '-' : '') : `z${p === 1 ? '' : p}`;
        pos += p;
        // Break the beam at beat boundaries, around beat-or-longer values and around rests.
        if (pos % beat16 === 0 || p >= beat16 || !ev.midis) out += ' ';
      });
      remaining -= chunk;
      if (pos % bar16 === 0) {
        barAcc = new Map();
        out = out.replace(/ ?$/, ' ') + ((pos / bar16) % 4 === 0 ? '|\n' : '| ');
      }
    }
  }
  return out.trim();
}

/** Grand staff split at C4 (middle C and up on the treble staff). `tempo`: put the ♩ = N mark on
 *  the page (Q:); the app shows its own adjustable mark above the staff instead. */
export function toAbc(score, { maxBars = 400, lastBars = 0, tempo = false } = {}) {
  const m = METERS[score.meter];
  const fifths = keyFifths(score.key);
  if (!score.notes.length) return null;
  const end = Math.max(...score.notes.map((n) => n.start16 + n.dur16));
  const allBars = Math.max(1, Math.ceil(end / m.bar16));
  const firstBar = lastBars ? Math.max(0, allBars - lastBars) : 0;
  const bars = lastBars ? allBars - firstBar : Math.min(maxBars, allBars);
  const off16 = firstBar * m.bar16;
  const total16 = bars * m.bar16;
  const visible = score.notes.filter((n) => n.start16 >= off16 && n.start16 - off16 < total16)
    .map((n) => ({ ...n, start16: n.start16 - off16, dur16: Math.min(n.dur16, total16 - (n.start16 - off16)) }));
  const treble = visible.filter((n) => n.midi >= 60);
  const bass = visible.filter((n) => n.midi < 60);
  const beat16 = m.unit === 8 ? 6 : 4; // 6/8 beams in dotted quarters
  return [
    'X:1', `M:${score.meter}`, 'L:1/16', ...(tempo ? [`Q:1/4=${Math.round(score.bpm)}`] : []),
    '%%stretchlast 1', '%%score {RH LH}', 'V:RH clef=treble', 'V:LH clef=bass', `K:${keyName(score.key)}`,
    '[V:RH] ' + voiceToAbc(treble, m.bar16, total16, fifths, beat16),
    '[V:LH] ' + voiceToAbc(bass, m.bar16, total16, fifths, beat16),
  ].join('\n');
}

export const NOTE_NAMES = ['C', 'C♯', 'D', 'E♭', 'E', 'F', 'F♯', 'G', 'A♭', 'A', 'B♭', 'B'];
export const midiName = (m) => `${NOTE_NAMES[m % 12]}${Math.floor(m / 12) - 1}`;
