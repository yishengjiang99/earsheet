#!/usr/bin/env python3
"""Velocity + note-off scorecard for Basic Pitch models (extends the §6.4 scorecard).

For each --test pair dir (basename.wav + basename.mid, MIDI must carry true
velocities — MAESTRO/SMD; GuitarSet has constant 90 and is excluded from the
velocity numbers), decodes with the given thresholds and reports:

- onset F1 (50 ms) and offset F1 (20% / 50 ms) via the finetune harness
- velocity MAE on matched notes: greedy match by (same pitch, onset within
  50 ms); estimated velocity = 127 * mean note-posterior (basic_pitch's own
  convention, also what the iOS app ships)
- dynamics correlation: Pearson r of matched (est, ref) velocities per clip
- constant-velocity baseline MAE (per-clip median ref velocity) for context

Usage:
  tools/finetune-eval/velocity_score.py --model stock=PATH \\
      --test real/pairs/smd-test real/pairs/maestro-test --out vel.json
  [--onset-threshold 0.7 --frame-threshold 0.4 --min-note-len 5]
"""
import argparse
import importlib.machinery
import importlib.util
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
_l = importlib.machinery.SourceFileLoader("ft", str(ROOT / "scripts" / "finetune-basic-pitch"))
_s = importlib.util.spec_from_loader("ft", _l)
ft = importlib.util.module_from_spec(_s)
_l.exec_module(ft)

ONSET_TOL = 0.05


def match_notes(ref, est):
    """Greedy match: same pitch, |onset diff| <= 50 ms. Returns [(ref_vel, est_vel)]."""
    unmatched = [list(r) for r in ref]  # (start, end, pitch, vel)
    out = []
    for s, e, p, amp, *_ in sorted(est, key=lambda x: x[0]):
        best, best_dt = None, ONSET_TOL + 1e-9
        for r in unmatched:
            if r[2] != int(p):
                continue
            dt = abs(r[0] - s)
            if dt <= ONSET_TOL and dt < best_dt:
                best, best_dt = r, dt
        if best is not None:
            unmatched.remove(best)
            est_vel = min(127.0, max(1.0, 127.0 * float(amp)))
            out.append((float(best[3]), est_vel))
    return out


def pearson(xs, ys):
    n = len(xs)
    if n < 2:
        return float("nan")
    mx, my = sum(xs) / n, sum(ys) / n
    cov = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    vx = sum((x - mx) ** 2 for x in xs)
    vy = sum((y - my) ** 2 for y in ys)
    if vx <= 0 or vy <= 0:
        return float("nan")
    return cov / math.sqrt(vx * vy)


def score_dir(model, pairs, o, fr, mnl):
    import numpy as np

    outputs = {}
    for stem, wav, _ in pairs:
        from basic_pitch import inference
        outputs[stem] = inference.run_inference(str(wav), model)
    clip_rows = []
    for stem, _wav, mid_path in pairs:
        if stem not in outputs:
            continue
        ref = ft.midi_notes(mid_path)  # (start, end, midi, velocity)
        if not ref:
            continue
        events = ft.decode(outputs[stem], o, fr, mnl)  # (start, end, pitch, amplitude)
        sc = ft.note_scores(*ft.reference_notes(mid_path), events)
        matched = match_notes(ref, events)
        if matched:
            rvs = [m[0] for m in matched]
            evs = [m[1] for m in matched]
            mae = sum(abs(a - b) for a, b in matched) / len(matched)
            med = sorted(rvs)[len(rvs) // 2]
            const_mae = sum(abs(v - med) for v in rvs) / len(rvs)
            r = pearson(rvs, evs)
        else:
            mae, const_mae, r = float("nan"), float("nan"), float("nan")
        clip_rows.append({"stem": stem, "n_ref": len(ref), "n_est": len(events),
                          "n_matched": len(matched), "f1": sc["f1"],
                          "f1_offset": sc["f1_offset"], "vel_mae": mae,
                          "const_vel_mae": const_mae, "vel_r": r})
    def mean(k):
        vs = [c[k] for c in clip_rows if c[k] == c[k]]  # drop nan
        return round(sum(vs) / len(vs), 4) if vs else 0.0
    def wmean(k, w="n_matched"):
        num = sum(c[k] * c[w] for c in clip_rows if c[k] == c[k] and c[w] > 0)
        den = sum(c[w] for c in clip_rows if c[k] == c[k] and c[w] > 0)
        return round(num / den, 4) if den else 0.0
    return {"n_clips": len(clip_rows),
            "matched_notes": sum(c["n_matched"] for c in clip_rows),
            "mean_f1": mean("f1"), "mean_f1_offset": mean("f1_offset"),
            "vel_mae": wmean("vel_mae"), "const_vel_mae": wmean("const_vel_mae"),
            "vel_r": mean("vel_r"), "clips": clip_rows}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", action="append", required=True, help="name=SavedModel dir")
    ap.add_argument("--test", nargs="+", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--onset-threshold", type=float, default=0.7)
    ap.add_argument("--frame-threshold", type=float, default=0.4)
    ap.add_argument("--min-note-len", type=int, default=5)
    a = ap.parse_args()
    from basic_pitch import inference

    tests = {d.name: list(ft.read_pairs(d)) for d in a.test}
    res = json.loads(a.out.read_text()) if a.out.exists() else {}
    for spec in a.model:
        name, path = spec.split("=", 1)
        m = inference.Model(path)
        r = {"path": path, "thresholds": [a.onset_threshold, a.frame_threshold, a.min_note_len],
             "tests": {}}
        for tn, pairs in tests.items():
            s = score_dir(m, pairs, a.onset_threshold, a.frame_threshold, a.min_note_len)
            r["tests"][tn] = {k: v for k, v in s.items() if k != "clips"}
            print(f"{name} {tn}: clips={s['n_clips']} matched={s['matched_notes']} "
                  f"f1={s['mean_f1']:.4f} f1_off={s['mean_f1_offset']:.4f} "
                  f"vel_mae={s['vel_mae']:.2f} (const {s['const_vel_mae']:.2f}) r={s['vel_r']:.3f}",
                  flush=True)
            r["tests"][tn]["clips"] = s["clips"]
        res[name] = r
        a.out.write_text(json.dumps(res, indent=1))


if __name__ == "__main__":
    main()
