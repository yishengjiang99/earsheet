#!/usr/bin/env python3
"""Calibration baseline: pitch-dependent linear map from RMS energy to velocity.

Fit on train pair dirs (true velocities): for each reference note, RMS energy
over the note's audio span -> per-pitch linear regression
  vel = a[pitch] * log10(rms) + b[pitch].
At test time: decode with the stock model, compute RMS per estimated note,
predict velocity, then score with the matched-notes metric.

Tells us whether a neural velocity head is even needed.

Usage:
  calibration_baseline.py --train real/maestro-train real/smd-train \\
      --test real/maestro-test real/smd-test --out calib.json
  [--onset-threshold 0.7 --frame-threshold 0.4 --min-note-len 5]
"""
import argparse
import importlib.machinery
import importlib.util
import json
import math
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
_l = importlib.machinery.SourceFileLoader("ft", str(ROOT / "scripts" / "finetune-basic-pitch"))
_s = importlib.util.spec_from_loader("ft", _l)
ft = importlib.util.module_from_spec(_s)
_l.exec_module(ft)
from velocity_score import match_notes, pearson  # noqa: E402

SR = 22050
ONSET_TOL = 0.05


def load_audio(wav_path):
    import soundfile as sf

    audio, sr = sf.read(str(wav_path), dtype="float32")
    assert sr == SR
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    return audio


def note_rms(audio, start_s, end_s):
    s = max(0, int(start_s * SR))
    e = min(len(audio), int(end_s * SR))
    if e <= s:
        return 0.0
    seg = audio[s:e]
    return float(np.sqrt(np.mean(seg ** 2)) + 1e-9)


def fit(train_dirs):
    """Returns dict pitch -> (a, b) for vel = a*log10(rms) + b."""
    import collections

    data = collections.defaultdict(list)
    for d in train_dirs:
        for _stem, wav_path, mid_path in ft.read_pairs(d):
            audio = load_audio(wav_path)
            for s, e, p, v in ft.midi_notes(mid_path):
                if not 21 <= p <= 108:
                    continue
                r = note_rms(audio, s, e)
                if r <= 1e-8:
                    continue
                data[p].append((math.log10(r), float(v)))
    coef = {}
    for p, pts in data.items():
        if len(pts) < 10:
            continue
        xs = np.array([x for x, _ in pts])
        ys = np.array([y for _, y in pts])
        A = np.vstack([xs, np.ones_like(xs)]).T
        a, b = np.linalg.lstsq(A, ys, rcond=None)[0]
        coef[p] = (float(a), float(b))
    # fallback: global fit for pitches with too few samples
    all_pts = [(x, y) for pts in data.values() for x, y in pts]
    xs = np.array([x for x, _ in all_pts])
    ys = np.array([y for _, y in all_pts])
    A = np.vstack([xs, np.ones_like(xs)]).T
    ga, gb = np.linalg.lstsq(A, ys, rcond=None)[0]
    print(f"fit on {len(all_pts)} notes, {len(coef)} pitches with >=10 samples", flush=True)
    return coef, (float(ga), float(gb))


def predict_vel(coef, glob, pitch, rms):
    a, b = coef.get(pitch, glob)
    v = a * math.log10(max(rms, 1e-9)) + b
    return min(127.0, max(1.0, v))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--train", nargs="+", type=Path, required=True)
    ap.add_argument("--test", nargs="+", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--onset-threshold", type=float, default=0.7)
    ap.add_argument("--frame-threshold", type=float, default=0.4)
    ap.add_argument("--min-note-len", type=int, default=5)
    a = ap.parse_args()
    from basic_pitch import inference
    from basic_pitch import ICASSP_2022_MODEL_PATH

    coef, glob = fit(a.train)
    model = inference.Model(str(ICASSP_2022_MODEL_PATH))
    res = {"tests": {}}
    for d in a.test:
        pairs = list(ft.read_pairs(d))
        clip_rows = []
        for stem, wav_path, mid_path in pairs:
            audio = load_audio(wav_path)
            out = inference.run_inference(str(wav_path), model)
            events = ft.decode(out, a.onset_threshold, a.frame_threshold, a.min_note_len)
            # estimated velocity from calibration
            est = []
            for s, e, p, *_ in events:
                r = note_rms(audio, s, e)
                est.append((s, e, int(p), predict_vel(coef, glob, int(p), r)))
            ref = ft.midi_notes(mid_path)
            matched = []
            # match on (start, pitch) like velocity_score, but est already has vel
            unmatched = [list(r) for r in ref]
            for s, e, p, v in sorted(est, key=lambda x: x[0]):
                best, best_dt = None, ONSET_TOL + 1e-9
                for r in unmatched:
                    if r[2] != p:
                        continue
                    dt = abs(r[0] - s)
                    if dt <= ONSET_TOL and dt < best_dt:
                        best, best_dt = r, dt
                if best is not None:
                    unmatched.remove(best)
                    matched.append((float(best[3]), float(v)))
            if matched:
                rvs = [m[0] for m in matched]
                evs = [m[1] for m in matched]
                mae = sum(abs(x - y) for x, y in matched) / len(matched)
                r = pearson(rvs, evs)
            else:
                mae, r = float("nan"), float("nan")
            clip_rows.append({"stem": stem, "n_matched": len(matched),
                              "vel_mae": mae, "vel_r": r})
        vs = [c["vel_mae"] for c in clip_rows if c["vel_mae"] == c["vel_mae"]]
        rs = [c["vel_r"] for c in clip_rows if c["vel_r"] == c["vel_r"]]
        wsum = sum(c["n_matched"] for c in clip_rows)
        wmae = (sum(c["vel_mae"] * c["n_matched"] for c in clip_rows
                    if c["vel_mae"] == c["vel_mae"]) / wsum) if wsum else 0.0
        s = {"n_clips": len(clip_rows), "matched_notes": wsum,
             "vel_mae": round(wmae, 2), "vel_r": round(sum(rs) / len(rs), 3) if rs else 0.0}
        res["tests"][d.name] = s
        print(f"{d.name}: matched={wsum} vel_mae={s['vel_mae']:.2f} r={s['vel_r']:.3f}", flush=True)
    a.out.write_text(json.dumps(res, indent=1))
    print(f"wrote {a.out}", flush=True)


if __name__ == "__main__":
    main()
