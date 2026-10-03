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


def gen_etude(rng: RNG, seconds: float, extra_patterns: bool = False):
    """Returns (notes, tempo, key_root, minor).
    notes: list of (midi, start16, dur16, vel).
    extra_patterns adds dense two-hand voicings, fast 16th passages and
    melody-over-chords (patterns 4-6); off keeps the original 4 byte-identical."""
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
    pat = rng.int(0, 7) if extra_patterns else rng.int(0, 4)
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
    elif pat == 4:  # dense voicings: 4-6 notes over 2-3 octaves, varied rhythm
        t = 0
        while True:
            len16 = [2, 4, 4, 8, 8][rng.int(0, 5)]
            if t + len16 > total16:
                break
            root = deg_midi(rng.int(0, 7), rng.int(-1, 1))
            chord = TRIADS[rng.int(0, len(TRIADS))]
            tones = {clamp(root - 12)}
            for iv in chord:
                tones.add(clamp(root + iv))
            for _ in range(rng.int(1, 3)):
                tones.add(clamp(root + 12 + chord[rng.int(0, len(chord))]))
            for m in sorted(tones):
                notes.append((m, t, max(1, len16 - rng.int(0, 2)), rng.int(40, 120)))
            t += len16
    elif pat == 5:  # fast 16th-note runs (scale fragments), both hands
        t, d, direction = 0, rng.int(0, 7), 1
        while t + 1 <= total16:
            notes.append((clamp(deg_midi(d, 1)), t, 1, rng.int(50, 115)))
            if t % 4 == 0:
                notes.append((clamp(deg_midi(d - 7, 0)), t, 3, rng.int(45, 100)))
            d += direction
            if d >= 10 or d <= -3 or rng.int(0, 8) == 0:
                direction = -direction
            t += 1
    elif pat == 6:  # sustained chords + independent melody (overlapping notes)
        t = 0
        while t + 16 <= total16:
            root = deg_midi([0, 3, 4, 5][(t // 16) % 4], -1)
            for iv in TRIADS[rng.int(0, len(TRIADS))]:
                notes.append((clamp(root + iv), t, 16, rng.int(40, 90)))
            u = t
            while u < t + 16:
                len16 = [1, 2, 2, 3, 4][rng.int(0, 5)]
                notes.append((clamp(deg_midi(rng.int(0, 10), 1)), u, len16, rng.int(60, 120)))
                u += len16
            t += 16
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


def write_smf0(path: str, notes, tempo: float, tail_sec: float = TAIL_SEC,
               programs: dict | None = None) -> None:
    """notes: (midi, start16, dur16, vel[, channel]). 16th = TPQ/4 ticks.
    programs: {channel: GM program}; default {0: 0} (piano)."""
    tick16 = TPQ // 4
    total16 = max((n[1] + n[2] for n in notes), default=0)
    events = []  # (tick, order, bytes); note-offs sort before note-ons at same tick
    for n in notes:
        midi, s16, d16, vel = n[:4]
        ch = n[4] if len(n) > 4 else 0
        on_tick = s16 * tick16
        off_tick = (s16 + d16) * tick16
        events.append((on_tick, 1, bytes([0x90 | ch, midi, vel])))
        events.append((off_tick, 0, bytes([0x80 | ch, midi, 0])))
    tail_tick = total16 * tick16 + int(tail_sec * tempo / 60.0 * TPQ)

    us_per_quarter = int(round(60_000_000 / tempo))
    track = _vlq(0) + b"\xFF\x51\x03" + us_per_quarter.to_bytes(3, "big")
    track += _vlq(0) + b"\xFF\x58\x04\x04\x02\x18\x08"  # 4/4
    for ch, prog in sorted((programs or {0: 0}).items()):
        track += _vlq(0) + bytes([0xC0 | ch, prog])  # default: channel 0, program 0 (piano)

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
               sample_rate: int = SAMPLE_RATE, gain: float = 1.0,
               reverb: bool | None = None, chorus: bool | None = None) -> int:
    """Render MIDI to mono 16-bit WAV via the fluidsynth binary. Returns sample count."""
    if shutil.which("fluidsynth") is None:
        fail("fluidsynth binary not found on PATH. Install it first:\n"
             "  macOS:  brew install fluid-synth\n"
             "  Debian: sudo apt install fluidsynth")
    tmp = out_wav + ".fluid.wav"
    cmd = ["fluidsynth", "-ni", "-r", str(sample_rate), "-g", str(gain)]
    if reverb is not None:  # None = fluidsynth's default
        cmd += ["-R", "1" if reverb else "0"]
    if chorus is not None:
        cmd += ["-C", "1" if chorus else "0"]
    cmd += ["-F", tmp, sf2_path, midi_path]
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


# MARK: - Instruments (opt-in; default is piano on channel 0)

# GM program -> playable MIDI range, by family (program // 8)
FAMILY_RANGE = {0: (21, 108), 1: (48, 96), 2: (36, 96), 3: (40, 88), 4: (28, 67),
                5: (36, 100), 6: (36, 96), 7: (40, 84), 8: (50, 90), 9: (60, 96),
                10: (36, 96), 11: (36, 96)}


def fit_range(m: int, prog: int) -> int:
    lo, hi = FAMILY_RANGE.get(prog // 8, (21, 108))
    while m < lo:
        m += 12
    while m > hi:
        m -= 12
    return max(lo, min(hi, m))


def assign_instruments(notes, rng: RNG, programs: list, multi: bool):
    """Pick a program per etude (and, with multi, a second one for the low part on
    channel 1). Notes are octave-shifted into each instrument's range; exact duplicates
    created by the shift are dropped. Returns (notes5, {channel: program})."""
    prog = rng.pick(programs)
    chans = {0: prog}
    split = None
    if multi and len(programs) > 1:
        chans[1] = rng.pick(programs)
        split = 55
    out, seen = [], set()
    for m, s16, d16, v in notes:
        ch = 1 if split is not None and m < split else 0
        m2 = fit_range(m, chans[ch])
        key = (m2, s16)
        if key in seen:
            continue
        seen.add(key)
        out.append((m2, s16, d16, v, ch))
    return out, chans


def remap_velocity(notes, lo: int, hi: int):
    return [(n[0], n[1], n[2], max(1, min(127, int(round(lo + (n[3] - 40) / 80.0 * (hi - lo)))))) + tuple(n[4:])
            for n in notes]


def _render_job(job):
    stem, mid_path, sf2, wav_path, rate, gain, reverb, chorus = job
    try:
        return stem, render_wav(mid_path, sf2, wav_path, sample_rate=rate, gain=gain,
                                reverb=reverb, chorus=chorus), None
    except SystemExit as e:
        return stem, 0, f"fluidsynth failed ({e})"
    except Exception as e:  # noqa: BLE001
        return stem, 0, str(e)


# MARK: - Main

def main() -> None:
    ap = argparse.ArgumentParser(description="Render paired WAV+MIDI training data with FluidSynth.")
    ap.add_argument("--soundfont", required=True, nargs="+",
                    help="path(s) to .sf2; with several, each etude picks one (seeded)")
    ap.add_argument("--out", required=True, help="output directory")
    ap.add_argument("--generate", type=int, default=0, help="number of seeded etudes to synthesize")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--seconds", type=float, default=12.0, help="etude length")
    ap.add_argument("--midi", nargs="*", default=[], help="existing MIDI files to render")
    ap.add_argument("--sample-rate", type=int, default=SAMPLE_RATE)
    ap.add_argument("--gain", type=float, default=1.0, help="fluidsynth gain")
    ap.add_argument("--programs", type=lambda v: [int(x) for x in v.split(",")], default=None,
                    help="comma list of GM programs; each etude picks one (default: piano only)")
    ap.add_argument("--multi-instrument", action="store_true",
                    help="with --programs: low part (< MIDI 55) on a second random program")
    ap.add_argument("--extra-patterns", action="store_true",
                    help="add dense voicings, fast runs and melody-over-chords patterns")
    ap.add_argument("--velocity-range", type=int, nargs=2, metavar=("LO", "HI"), default=None,
                    help="remap generated velocities into [LO, HI] (e.g. 20 127)")
    ap.add_argument("--gain-range", type=float, nargs=2, metavar=("LO", "HI"), default=None,
                    help="random fluidsynth gain per etude")
    ap.add_argument("--reverb-prob", type=float, default=None,
                    help="probability of fluidsynth reverb on (default: fluidsynth's default)")
    ap.add_argument("--chorus-prob", type=float, default=None,
                    help="probability of fluidsynth chorus on (default: fluidsynth's default)")
    ap.add_argument("--pitch-range", type=int, nargs=2, metavar=("LO", "HI"), default=None,
                    help="octave-fold generated notes into [LO, HI] (e.g. 40 88 for a guitar SF2)")
    ap.add_argument("--jobs", type=int, default=1, help="parallel fluidsynth renders")
    args = ap.parse_args()

    for sf2 in args.soundfont:
        if not os.path.isfile(sf2):
            fail(f"no SoundFont at {sf2} (run scripts/fetch-models first)")
    os.makedirs(args.out, exist_ok=True)
    # Choices that are not part of the etude (soundfont, program, fx) come from a
    # second RNG so the default note stream stays byte-identical to older versions.
    vrng = RNG(args.seed ^ 0x5F3759DF)
    render_opts = {}

    jobs = []  # (stem, midi_path_or_None, gen_notes_or_None, meta)
    rng = RNG(args.seed)
    for i in range(args.generate):
        notes, tempo, key_root, minor = gen_etude(rng, args.seconds, args.extra_patterns)
        stem = f"etude-{i:05d}"
        mid_path = os.path.join(args.out, stem + ".mid")
        if args.velocity_range:
            notes = remap_velocity(notes, *args.velocity_range)
        if args.pitch_range:
            lo, hi = args.pitch_range
            folded, seen = [], set()
            for n in notes:
                m = n[0]
                while m < lo:
                    m += 12
                while m > hi:
                    m -= 12
                if (m, n[1]) not in seen:
                    seen.add((m, n[1]))
                    folded.append((m,) + tuple(n[1:]))
            notes = folded
        chans = None
        if args.programs:
            notes, chans = assign_instruments(notes, vrng, args.programs, args.multi_instrument)
        write_smf0(mid_path, notes, tempo, programs=chans)
        sf2 = args.soundfont[0] if len(args.soundfont) == 1 else vrng.pick(args.soundfont)
        gain = args.gain if not args.gain_range else vrng.double(*args.gain_range)
        reverb = None if args.reverb_prob is None else vrng.double(0, 1) < args.reverb_prob
        chorus = None if args.chorus_prob is None else vrng.double(0, 1) < args.chorus_prob
        render_opts[stem] = (sf2, gain, reverb, chorus)
        meta = {
            "generator": "poly-render-py", "seed": args.seed, "index": i,
            "tempo": tempo, "key_root": key_root, "minor": minor,
            "notes": [{"midi": n[0], "start16": n[1], "duration16": n[2], "velocity": n[3]}
                      for n in notes],
        }
        if len(args.soundfont) > 1 or chans or args.gain_range or reverb is not None or chorus is not None:
            meta.update({"soundfont": os.path.basename(sf2), "programs": chans, "gain": gain,
                         "reverb": reverb, "chorus": chorus})
        jobs.append((stem, mid_path, notes, meta))
    for m in args.midi:
        if not os.path.isfile(m):
            fail(f"cannot read {m}")
        stem = os.path.splitext(os.path.basename(m))[0]
        jobs.append((stem, m, None, {"generator": "poly-render-py", "source_midi": m}))
    if not jobs:
        fail("nothing to do: pass --generate N or --midi files")

    done = 0
    render_jobs = []
    for stem, mid_path, _notes, _meta in jobs:
        sf2, gain, reverb, chorus = render_opts.get(stem, (args.soundfont[0], args.gain, None, None))
        render_jobs.append((stem, mid_path, sf2, os.path.join(args.out, stem + ".wav"),
                            args.sample_rate, gain, reverb, chorus))
    if args.jobs > 1:
        from concurrent.futures import ProcessPoolExecutor
        with ProcessPoolExecutor(args.jobs) as ex:
            results = {r[0]: r for r in ex.map(_render_job, render_jobs)}
    else:
        results = {}
        for j in render_jobs:
            r = _render_job(j)
            if r[2] and "fluidsynth" in r[2] and shutil.which("fluidsynth") is None:
                fail(r[2])
            results[j[0]] = r
    for stem, mid_path, _notes, meta in jobs:
        wav_path = os.path.join(args.out, stem + ".wav")
        _s, nsamp, err = results[stem]
        if err:
            sys.stderr.write(f"skip {stem}: {err}\n")
            continue
        # keep a copy of generated MIDIs next to the WAV (source MIDIs stay in place)
        if os.path.abspath(mid_path).startswith(os.path.abspath(args.out) + os.sep):
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
