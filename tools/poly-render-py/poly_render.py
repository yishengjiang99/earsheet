#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""poly_render.py: Phase-B paired-data generator (Python/FluidSynth edition).

Renders MIDI through FluidSynth (GeneralUser-GS SoundFont) and writes, per stem:
  <stem>.wav   22050 Hz mono 16-bit PCM (what basic-pitch 0.4.0 requires)
  <stem>.mid   the MIDI that was rendered
  <stem>.json  sidecar: tempo, key, notes, generator seed

Two modes:
  poly_render.py --soundfont <sf2> --out <dir> --generate 200 --seed 7
  poly_render.py --soundfont <sf2> --out <dir> --midi a.mid b.mid

Stdlib only. Requires the `fluidsynth` binary on PATH
(macOS: brew install fluid-synth | Debian: apt install fluidsynth).

This is the Python counterpart of ../poly-render (Swift, which renders via the
vendored SF2Player's SF2OfflineRenderer). Output format is identical; timbre
differs slightly (FluidSynth vs Sf2SynthEngine) but the labels are what the
fine-tune pipeline trains on.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import struct
import subprocess
import sys
import typing
import wave

SAMPLE_RATE = 22050
TPQ = 480
TAIL_SEC = 2.0

MASK64 = (1 << 64) - 1


# MARK: - Deterministic RNG (splitmix64, same as the Swift tool)

class RNG:
    def __init__(self, seed: int):
        self.s = seed & MASK64

    def next(self) -> int:
        self.s = (self.s + 0x9E3779B97F4A7C15) & MASK64
        z = self.s
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK64
        return z ^ (z >> 31)

    def int(self, lo: int, hi: int) -> int:  # [lo, hi)
        return lo + self.next() % max(1, hi - lo)

    def double(self, lo: float, hi: float) -> float:
        return lo + (self.next() % 1000000) / 1000000.0 * (hi - lo)

    def pick(self, xs: list):
        return xs[self.int(0, len(xs))]


# MARK: - Etude generation (16th-note grid, 4/4; mirrors the Swift tool)

MAJOR_SCALE = [0, 2, 4, 5, 7, 9, 11]
MINOR_SCALE = [0, 2, 3, 5, 7, 8, 10]
TRIADS = [[0, 4, 7], [0, 3, 7], [0, 4, 7, 11], [0, 3, 7, 10], [0, 4, 7, 10]]


def gen_etude(rng: RNG, seconds: float):
    """Returns (notes, tempo, key_root, minor).
    notes: list of (midi, start16, dur16, vel)."""
    tempo = rng.double(80, 141)
    total16 = max(16, int(seconds * tempo / 60.0 * 4.0))
    minor = rng.int(0, 2) == 1
    key_root = rng.int(0, 12)
    tonic = 48 + key_root
    scale = MINOR_SCALE if minor else MAJOR_SCALE

    def deg_midi(degree: int, octave: int = 0) -> int:
        s = degree % 7
        o = degree // 7  # floor division, matches Swift's correction
        return tonic + scale[s] + 12 * (octave + o)

    def clamp(m: int) -> int:
        return max(21, min(108, m))

    notes = []
    pat = rng.int(0, 4)
    if pat == 0:  # chord loop + bass root
        roots = [0, 5, 2, 6] if minor else [0, 5, 3, 4]
        t = 0
        while t + 16 <= total16:
            chord = TRIADS[rng.int(0, len(TRIADS))]
            root = deg_midi(roots[(t // 16) % len(roots)])
            for iv in chord:
                notes.append((clamp(root + iv), t, 14, rng.int(72, 100)))
            notes.append((clamp(root - 12), t, 14, rng.int(80, 105)))
            t += 16
    elif pat == 1:  # scales up/down, quarter notes
        t, d, direction = 0, 0, 1
        while t + 4 <= total16:
            notes.append((clamp(deg_midi(d)), t, 4, rng.int(75, 100)))
            d += direction
            if d >= 14:
                direction = -1
            if d <= 0:
                direction = 1
            t += 4
    elif pat == 2:  # arpeggios, eighth notes with octave jumps
        t = 0
        roots = [0, 3, 4, 5]
        while t + 2 <= total16:
            chord = TRIADS[rng.int(0, len(TRIADS))]
            step = t // 2
            root = deg_midi(roots[(t // 8) % len(roots)])
            tone = root + chord[step % len(chord)] + 12 * ((step // len(chord)) % 2)
            notes.append((clamp(tone), t, 2, rng.int(70, 100)))
            t += 2
    else:  # random-walk melody + sparse bass
        t, d = 0, rng.int(0, 7)
        while True:
            len16 = [2, 2, 4, 4, 8][rng.int(0, 5)]
            if t + len16 > total16:
                break
            notes.append((clamp(deg_midi(d, 1)), t, len16 - 1, rng.int(70, 105)))
            d = max(-7, min(14, d + rng.int(-2, 3)))
            if t % 16 == 0:
                b = deg_midi([0, 4, 5][rng.int(0, 3)], -1)
                notes.append((clamp(b), t, 12, rng.int(78, 100)))
            t += len16
    return notes, tempo, key_root, minor


# MARK: - Minimal SMF format-0 writer (480 TPQ)

def _vlq(value: int) -> bytes:
    out = bytearray([value & 0x7F])
    value >>= 7
    while value:
        out.append(0x80 | (value & 0x7F))
        value >>= 7
    return bytes(reversed(out))


def write_smf0(path: str, notes, tempo: float, tail_sec: float = TAIL_SEC) -> None:
    """notes: (midi, start16, dur16, vel). 16th = TPQ/4 ticks."""
    tick16 = TPQ // 4
    total16 = max((s + d for _, s, d, _ in notes), default=0)
    events = []  # (tick, order, bytes); note-offs sort before note-ons at same tick
    for midi, s16, d16, vel in notes:
        on_tick = s16 * tick16
        off_tick = (s16 + d16) * tick16
        events.append((on_tick, 1, bytes([0x90, midi, vel])))
        events.append((off_tick, 0, bytes([0x80, midi, 0])))
    tail_tick = total16 * tick16 + int(tail_sec * tempo / 60.0 * TPQ)

    us_per_quarter = int(round(60_000_000 / tempo))
    track = _vlq(0) + b"\xFF\x51\x03" + us_per_quarter.to_bytes(3, "big")
    track += _vlq(0) + b"\xFF\x58\x04\x04\x02\x18\x08"  # 4/4
    track += _vlq(0) + bytes([0xC0, 0x00])  # program 0 (piano)

    last = 0
    for tick, _, data in sorted(events, key=lambda e: (e[0], e[1])):
        track += _vlq(tick - last) + data
        last = tick
    track += _vlq(tail_tick - last) + b"\xFF\x2F\x00"

    with open(path, "wb") as f:
        f.write(b"MThd" + struct.pack(">IHHH", 6, 0, 1, TPQ))
        f.write(b"MTrk" + struct.pack(">I", len(track)) + track)


# MARK: - FluidSynth render + mono mixdown

def fail(msg: str) -> "typing.NoReturn":
    sys.stderr.write(msg + "\n")
    sys.exit(1)


def render_wav(midi_path: str, sf2_path: str, out_wav: str,
               sample_rate: int = SAMPLE_RATE, gain: float = 1.0) -> int:
    """Render MIDI to mono 16-bit WAV via the fluidsynth binary. Returns sample count."""
    if shutil.which("fluidsynth") is None:
        fail("fluidsynth binary not found on PATH. Install it first:\n"
             "  macOS:  brew install fluid-synth\n"
             "  Debian: sudo apt install fluidsynth")
    tmp = out_wav + ".fluid.wav"
    cmd = ["fluidsynth", "-ni", "-r", str(sample_rate), "-g", str(gain),
           "-F", tmp, sf2_path, midi_path]
    try:
        subprocess.run(cmd, check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as e:
        fail(f"fluidsynth failed: {(e.stderr or e.stdout or '').strip()[-500:]}")
    try:
        mono = _read_mono(tmp, sample_rate)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
    _write_wav16(out_wav, mono, sample_rate)
    return len(mono)


def _read_mono(path: str, expect_rate: int) -> list:
    with wave.open(path, "rb") as w:
        nch, sw, rate, nframes = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        raw = w.readframes(nframes)
    if rate != expect_rate:
        fail(f"fluidsynth rendered at {rate} Hz, expected {expect_rate}; refusing to resample silently")
    if sw == 2:
        vals = struct.unpack("<%dh" % (len(raw) // 2), raw)
        scale = 1.0 / 32768.0
    elif sw == 4:
        # could be int32 or float32; fluidsynth -F writes 16-bit, treat 4-byte as float32
        vals = struct.unpack("<%df" % (len(raw) // 4), raw)
        scale = 1.0
    else:
        fail(f"unexpected fluidsynth sample width: {sw} bytes")
    mono = [0.0] * nframes
    if nch == 1:
        for i, v in enumerate(vals):
            mono[i] = v * scale
    else:
        for i in range(nframes):
            acc = 0.0
            for c in range(nch):
                acc += vals[i * nch + c]
            mono[i] = acc / nch * scale
    # clamp, fluidsynth can hot-clip slightly
    return [max(-1.0, min(1.0, x)) for x in mono]


def _write_wav16(path: str, samples: list, sample_rate: int) -> None:
    n = len(samples)
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + n * 2) + b"WAVEfmt ")
        f.write(struct.pack("<IHHIIHH", 16, 1, 1, sample_rate, sample_rate * 2, 2, 16))
        f.write(b"data" + struct.pack("<I", n * 2))
        f.write(struct.pack("<%dh" % n, *(max(-32768, min(32767, int(s * 32767))) for s in samples)))


# MARK: - Main

def main() -> None:
    ap = argparse.ArgumentParser(description="Render paired WAV+MIDI training data with FluidSynth.")
    ap.add_argument("--soundfont", required=True, help="path to .sf2 (from scripts/fetch-models)")
    ap.add_argument("--out", required=True, help="output directory")
    ap.add_argument("--generate", type=int, default=0, help="number of seeded etudes to synthesize")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--seconds", type=float, default=12.0, help="etude length")
    ap.add_argument("--midi", nargs="*", default=[], help="existing MIDI files to render")
    ap.add_argument("--sample-rate", type=int, default=SAMPLE_RATE)
    ap.add_argument("--gain", type=float, default=1.0, help="fluidsynth gain")
    args = ap.parse_args()

    if not os.path.isfile(args.soundfont):
        fail(f"no SoundFont at {args.soundfont} (run scripts/fetch-models first)")
    os.makedirs(args.out, exist_ok=True)

    jobs = []  # (stem, midi_path_or_None, gen_notes_or_None, meta)
    rng = RNG(args.seed)
    for i in range(args.generate):
        notes, tempo, key_root, minor = gen_etude(rng, args.seconds)
        stem = f"etude-{i:05d}"
        mid_path = os.path.join(args.out, stem + ".mid")
        write_smf0(mid_path, notes, tempo)
        jobs.append((stem, mid_path, notes, {
            "generator": "poly-render-py", "seed": args.seed, "index": i,
            "tempo": tempo, "key_root": key_root, "minor": minor,
            "notes": [{"midi": m, "start16": s, "duration16": d, "velocity": v}
                      for m, s, d, v in notes],
        }))
    for m in args.midi:
        if not os.path.isfile(m):
            fail(f"cannot read {m}")
        stem = os.path.splitext(os.path.basename(m))[0]
        jobs.append((stem, m, None, {"generator": "poly-render-py", "source_midi": m}))
    if not jobs:
        fail("nothing to do: pass --generate N or --midi files")

    done = 0
    for stem, mid_path, _notes, meta in jobs:
        wav_path = os.path.join(args.out, stem + ".wav")
        try:
            nsamp = render_wav(mid_path, args.soundfont, wav_path,
                               sample_rate=args.sample_rate, gain=args.gain)
        except SystemExit:
            raise
        except Exception as e:  # noqa: BLE001 - keep going over a large batch
            sys.stderr.write(f"skip {stem}: {e}\n")
            continue
        # keep a copy of generated MIDIs next to the WAV (source MIDIs stay in place)
        if mid_path.startswith(os.path.abspath(args.out) + os.sep):
            mid_out = mid_path
        else:
            mid_out = os.path.join(args.out, stem + ".mid")
            shutil.copyfile(mid_path, mid_out)
        meta_out = dict(meta)
        meta_out.update({"wav": os.path.basename(wav_path),
                         "mid": os.path.basename(mid_out),
                         "samples": nsamp,
                         "sample_rate": args.sample_rate, "channels": 1})
        with open(os.path.join(args.out, stem + ".json"), "w") as f:
            json.dump(meta_out, f, indent=2, sort_keys=True)
        print(f"wrote {stem} ({nsamp} samples)")
        done += 1
    print(f"done: {done}/{len(jobs)} job(s) -> {args.out}")


if __name__ == "__main__":
    main()
