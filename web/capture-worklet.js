// SPDX-License-Identifier: AGPL-3.0-or-later
// Downmixes the mic input to mono and posts 1024-sample blocks to the main thread.
class EarSheetCapture extends AudioWorkletProcessor {
  constructor() { super(); this.block = 1024; this.buf = new Float32Array(this.block); this.n = 0; }
  process(inputs) {
    const chans = inputs[0];
    if (chans && chans.length) {
      const len = chans[0].length, nc = chans.length;
      for (let i = 0; i < len; i++) {
        let v = 0;
        for (let c = 0; c < nc; c++) v += chans[c][i];
        this.buf[this.n++] = v / nc;
        if (this.n === this.block) {
          this.port.postMessage(this.buf, [this.buf.buffer]);
          this.buf = new Float32Array(this.block); this.n = 0;
        }
      }
    }
    return true;
  }
}
registerProcessor('earsheet-capture', EarSheetCapture);
