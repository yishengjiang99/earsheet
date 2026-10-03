#!/usr/bin/env python3
"""Compare Basic Pitch SavedModels on held-out pair dirs, with decoder tuning.

For each model: run it once per clip (outputs cached in memory: note + onset only),
tune decoder settings (onset x frame x min_note_len) on the union of --val dirs, then
report onset-F1 (mir_eval, 50 ms) on every --test dir at Spotify defaults (0.5/0.3/11)
and at the model's tuned settings.

  tools/finetune-eval/compare_models.py --model stock=PATH --model e6=PATH \\
      --val val real/pairs/guitarset-val real/pairs/maestro-val \\
      --test test-gugs real/pairs/smd-test ... --out compare.json

Run inside the training env (TF 2.15 + basic-pitch 0.4.0). Uses the helpers in
scripts/finetune-basic-pitch so scoring is identical to the trainer's.
"""
import argparse
import importlib.machinery
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
_l = importlib.machinery.SourceFileLoader("ft", str(ROOT / "scripts" / "finetune-basic-pitch"))
_s = importlib.util.spec_from_loader("ft", _l)
ft = importlib.util.module_from_spec(_s)
_l.exec_module(ft)


def outputs_for(model, pairs):
    from basic_pitch import inference
    out = {}
    for stem, wav, _ in pairs:
        o = inference.run_inference(str(wav), model)
        out[stem] = {"note": o["note"].astype("float32"), "onset": o["onset"].astype("float32"),
                     "contour": o["contour"][:, :1]}  # contour unused by the decoder (no bends)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", action="append", required=True, help="name=SavedModel dir")
    ap.add_argument("--val", nargs="+", type=Path, required=True)
    ap.add_argument("--test", nargs="+", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    a = ap.parse_args()
    from basic_pitch import inference

    val_pairs = ft.read_many(a.val)
    tests = {d.name: list(ft.read_pairs(d)) for d in a.test}
    res = json.loads(a.out.read_text()) if a.out.exists() else {}
    for spec in a.model:
        name, path = spec.split("=", 1)
        m = inference.Model(path)
        vo = outputs_for(m, val_pairs)
        o, fr, mnl, vf1 = ft.tune_thresholds(vo, val_pairs)
        r = {"path": path, "tuned": [o, fr, mnl],
             "val_default": ft.score_outputs(vo, val_pairs, 0.5, 0.3, 11)["mean_f1"], "val_tuned": vf1, "tests": {}}
        del vo
        for tn, pairs in tests.items():
            to = outputs_for(m, pairs)
            d = ft.summarize(ft.score_outputs(to, pairs, 0.5, 0.3, 11))
            t = ft.summarize(ft.score_outputs(to, pairs, o, fr, mnl))
            r["tests"][tn] = {"default": d, "tuned": t}
            print(f"{name} {tn}: default {d['mean_f1']:.4f} (P {d['mean_precision']:.3f} R {d['mean_recall']:.3f}) "
                  f"tuned {t['mean_f1']:.4f} (P {t['mean_precision']:.3f} R {t['mean_recall']:.3f})", flush=True)
            del to
        res[name] = r
        a.out.write_text(json.dumps(res, indent=1))
        print(f"{name}: tuned {r['tuned']} val {r['val_default']:.4f} -> {vf1:.4f}", flush=True)


if __name__ == "__main__":
    main()
