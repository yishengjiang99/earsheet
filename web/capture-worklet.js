// SPDX-License-Identifier: AGPL-3.0-or-later
// Mic capture: downmix to mono, then the iOS app's input chain (Packages/HearSheet
// InputConditioner.swift + NoiseGate.swift): 70 Hz Butterworth high-pass -> adaptive noise
// floor (min-statistics over 20 ms RMS blocks, 3 s window, ready after 0.5 s) -> envelope
// noise gate whose threshold is floor + margin (Auto) or the manual threshold.
// Posts {x: Float32Array(1024), floorDB, thresholdDB} blocks to the main thread.

/** 2nd-order Butterworth high-pass (RBJ biquad, transposed direct form II). */
class HighPassFilter {
  constructor(sampleRate, cutoffHz) { this.sr = sampleRate; this.z1 = 0; this.z2 = 0; this.configure(cutoffHz); }
  configure(cutoffHz) {
    this.cutoffHz = cutoffHz;
    const w0 = 2 * Math.PI * Math.min(cutoffHz, this.sr * 0.45) / this.sr;
    const alpha = Math.sin(w0) / (2 * Math.SQRT1_2), cosw = Math.cos(w0), a0 = 1 + alpha;
    this.b0 = (1 + cosw) / 2 / a0; this.b1 = -(1 + cosw) / a0; this.b2 = this.b0;
    this.a1 = -2 * cosw / a0; this.a2 = (1 - alpha) / a0;
  }
  reset() { this.z1 = 0; this.z2 = 0; }
  process(x) {
    let s1 = this.z1, s2 = this.z2;
    const { b0, b1, b2, a1, a2 } = this;
    for (let i = 0; i < x.length; i++) {
      const input = x[i], y = b0 * input + s1;
      s1 = b1 * input - a1 * y + s2;
      s2 = b2 * input - a2 * y;
      x[i] = y;
    }
    this.z1 = Math.abs(s1) < 1e-20 ? 0 : s1; this.z2 = Math.abs(s2) < 1e-20 ? 0 : s2;
  }
}

/** Ambient noise floor: minimum of 20 ms block RMS over a rolling 3 s window, clamped to -90…-30 dBFS. */
class NoiseFloorEstimator {
  constructor(sampleRate) {
    this.blockSize = Math.max(1, Math.floor(sampleRate * 0.02));
    this.ring = new Float64Array(Math.max(1, Math.floor(3.0 / 0.02)));
    this.warmupBlocks = Math.max(1, Math.floor(0.5 / 0.02));
    this.reset();
  }
  reset() { this.acc = 0; this.n = 0; this.idx = 0; this.blocks = 0; this.floorDB = null; this.ring.fill(Infinity); }
  process(x) {
    for (let i = 0; i < x.length; i++) {
      this.acc += x[i] * x[i];
      if (++this.n === this.blockSize) {
        const rms = Math.sqrt(this.acc / this.blockSize);
        this.ring[this.idx] = 20 * Math.log10(Math.max(rms, 1e-9));
        this.idx = (this.idx + 1) % this.ring.length;
        this.blocks++; this.acc = 0; this.n = 0;
        if (this.blocks >= this.warmupBlocks) {
          let m = Infinity; for (const v of this.ring) if (v < m) m = v;
          this.floorDB = Math.min(-30, Math.max(-90, m));
        }
      }
    }
  }
}

/** Envelope-follower gate (grepaudio/NoiseGate port): attack = time to open, hold, release = time to close. */
class NoiseGate {
  constructor(sampleRate, s) { this.sr = sampleRate; this.env = 0; this.hold = 0; this.weight = 1; this.configure(s); }
  configure(s) {
    this.s = { ...s };
    const tc = s.timeConstant ?? 0.0025;
    this.alpha = tc > 0 ? Math.exp(-1 / (this.sr * tc)) : 0;
    this.openStep = s.attack > 0 ? 1 / Math.ceil(this.sr * s.attack) : 1;
    this.closeStep = s.release > 0 ? 1 / Math.ceil(this.sr * s.release) : 1;
    this.holdSamples = Math.max(0, Math.round(this.sr * s.hold));
  }
  reset() { this.env = 0; this.hold = 0; this.weight = 1; }
  process(x) {
    if (!this.s.enabled || !x.length) return;
    const thrPow = 10 ** (this.s.thresholdDB / 10);
    let env = this.env, w = this.weight, hold = this.hold;
    for (let i = 0; i < x.length; i++) {
      const v = x[i];
      env = this.alpha * env + (1 - this.alpha) * v * v;
      if (2 * env >= thrPow) { hold = this.holdSamples; w = Math.min(1, w + this.openStep); }
      else if (hold > 0) hold--;
      else w = Math.max(0, w - this.closeStep);
      x[i] = v * w;
    }
    this.env = env; this.weight = w; this.hold = hold;
  }
}

/** Defaults match InputConditioner.Settings.default / NoiseGate.Settings.default. */
const DEFAULT_SETTINGS = {
  gateEnabled: true, thresholdDB: -50, attackMs: 10, holdMs: 50, releaseMs: 50,
  autoThreshold: true, marginDB: 10, highPass: true, highPassHz: 70, dropQuietNotes: true,
};

class InputConditioner {
  constructor(sampleRate, settings = DEFAULT_SETTINGS) {
    this.sr = sampleRate;
    this.hpf = new HighPassFilter(sampleRate, settings.highPassHz);
    this.floor = new NoiseFloorEstimator(sampleRate);
    this.gate = new NoiseGate(sampleRate, this.gateSettings(settings));
    this.settings = { ...settings };
  }
  gateSettings(s) { return { enabled: s.gateEnabled, thresholdDB: s.thresholdDB, attack: s.attackMs / 1000, hold: s.holdMs / 1000, release: s.releaseMs / 1000 }; }
  configure(s) { this.settings = { ...s }; this.hpf.configure(s.highPassHz); this.gate.configure(this.gateSettings(s)); }
  reset() { this.hpf.reset(); this.floor.reset(); this.gate.reset(); this.gate.configure(this.gateSettings(this.settings)); }
  get noiseFloorDB() { return this.floor.floorDB; }
  get thresholdDB() {
    return this.settings.autoThreshold && this.floor.floorDB != null ? this.floor.floorDB + this.settings.marginDB : this.settings.thresholdDB;
  }
  process(x) {
    if (!x.length) return;
    if (this.settings.highPass) this.hpf.process(x);
    this.floor.process(x); // measured before gating
    if (this.settings.autoThreshold) this.gate.s.thresholdDB = this.thresholdDB;
    this.gate.process(x);
  }
}

globalThis.EarSheetDSP = { HighPassFilter, NoiseFloorEstimator, NoiseGate, InputConditioner, DEFAULT_SETTINGS };

if (typeof registerProcessor === 'function') {
  class EarSheetCapture extends AudioWorkletProcessor {
    constructor(options) {
      super();
      const s = { ...DEFAULT_SETTINGS, ...((options && options.processorOptions && options.processorOptions.settings) || {}) };
      this.cond = new InputConditioner(sampleRate, s);
      this.conditioning = !(options && options.processorOptions && options.processorOptions.raw);
      this.block = 1024; this.buf = new Float32Array(this.block); this.n = 0;
      this.port.onmessage = (e) => { if (e.data && e.data.settings) this.cond.configure({ ...DEFAULT_SETTINGS, ...e.data.settings }); };
    }
    process(inputs) {
      const chans = inputs[0];
      if (chans && chans.length) {
        const len = chans[0].length, nc = chans.length;
        for (let i = 0; i < len; i++) {
          let v = 0;
          for (let c = 0; c < nc; c++) v += chans[c][i];
          this.buf[this.n++] = v / nc;
          if (this.n === this.block) {
            if (this.conditioning) this.cond.process(this.buf);
            this.port.postMessage({ x: this.buf, floorDB: this.cond.noiseFloorDB, thresholdDB: this.cond.thresholdDB }, [this.buf.buffer]);
            this.buf = new Float32Array(this.block); this.n = 0;
          }
        }
      }
      return true;
    }
  }
  registerProcessor('earsheet-capture', EarSheetCapture);
}
