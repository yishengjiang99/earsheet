#!/usr/bin/env python3
"""Grid-search decoder params for offset-aware F1.

Tries (onset_threshold, frame_threshold, min_note_len) combos on a subset
of test clips, reports onset F1 and offset F1. Used to find decoder settings
that improve note-off without tanking note-on.

Usage:
  decoder_grid.py --test real/smd-test --out grid.json [--max-clips 20]
"""
import argparse
import importlib.machinery
import importlib.util
import itertools
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
_l = importlib.machinery.SourceFileLoader("ft", str(ROOT / "scripts" / "finetune-basic-pitch"))
_s = importlib.util.spec_from_loader("ft", _l)
ft = importlib.util.module_from_spec(_s)
_l.exec_module(ft)
_lv = importlib.machinery.SourceFileLoader("vs", str(ROOT / "tools" / "finetune-eval" / "velocity_score.py"))
_vs = importlib.util.spec_from_loader("vs", _lv)
vs = importlib.util.module_from_spec(_vs)
_lv.exec_module(vs)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--test", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--max-clips", type=int, default=20)
    a = ap.parse_args()
    from basic_pitch import inference
    from basic_pitch import ICASSP_2022_MODEL_PATH

    model = inference.Model(str(ICASSP_2022_MODEL_PATH))
    pairs = list(ft.read_pairs(a.test))[:a.max_clips]
    # precompute model outputs once
    outs = []
    for stem, wav_path, mid_path in pairs:
        out = inference.run_inference(str(wav_path), model)
        ref = ft.midi_notes(mid_path)
        outs.append((stem, out, ref, mid_path))
    print(f"cached {len(outs)} clips", flush=True)

    grid = list(itertools.product(
        [0.5, 0.6, 0.7, 0.8],      # onset
        [0.2, 0.3, 0.4, 0.5],      # frame
        [3, 5, 7, 11],             # min_note_len
    ))
    results = []
    for ot, fth, mnl in grid:
        f1s, f1os = [], []
        for stem, out, ref, mid_path in outs:
            events = ft.decode(out, ot, fth, mnl)
            sc = ft.note_scores(*ft.reference_notes(mid_path), events)
            f1s.append(sc["f1"])
            f1os.append(sc["f1_offset"])
        mf1 = sum(f1s) / len(f1s)
        mf1o = sum(f1os) / len(f1os)
        results.append({"onset": ot, "frame": fth, "min_note_len": mnl,
                        "f1": round(mf1, 4), "f1_offset": round(mf1o, 4)})
        print(f"onset={ot} frame={fth} mnl={mnl}: F1={mf1:.4f} F1off={mf1o:.4f}", flush=True)
    results.sort(key=lambda r: r["f1_offset"], reverse=True)
    a.out.write_text(json.dumps(results, indent=1))
    print(f"\ntop 5 by offset F1:", flush=True)
    for r in results[:5]:
        print(f"  {r}", flush=True)


if __name__ == "__main__":
    main()
