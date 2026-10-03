#!/usr/bin/env python3
"""Evaluate a trained velocity head on test pair dirs.

Builds trunk (frozen stock) + head into one Keras model, windows audio like
basic_pitch inference (30-frame overlap), stitches per-window [172, 88]
velocity maps, then for each decoded note takes the median head output over
its frames as the velocity. Scores with the matched-notes metric.

Usage:
  eval_velocity_head.py --head build/velocity-head/v1/head.weights.h5 \\
      --test real/maestro-test real/smd-test --out velhead.json
  [--onset-threshold 0.7 --frame-threshold 0.4 --min-note-len 5]
"""
import argparse
import importlib.machinery
import importlib.util
import json
import os

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "3")

from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
_l = importlib.machinery.SourceFileLoader("ft", str(ROOT / "scripts" / "finetune-basic-pitch"))
_s = importlib.util.spec_from_loader("ft", _l)
ft = importlib.util.module_from_spec(_s)
_l.exec_module(ft)
_lv = importlib.machinery.SourceFileLoader("vs", str(ROOT / "tools" / "finetune-eval" / "velocity_score.py"))
_vs = importlib.util.spec_from_loader("vs", _lv)
vs = importlib.util.module_from_spec(_vs)
_lv.exec_module(vs)

AUDIO_N_SAMPLES = 43844
N_OVERLAP_FRAMES = 30
FFT_HOP = 256
SR = 22050
ANNOTATIONS_FPS = SR / FFT_HOP


def build_trunk_head(head_weights):
    import sys

    import tensorflow as tf
    from basic_pitch import ICASSP_2022_MODEL_PATH, models

    sys.path.insert(0, str(Path(__file__).resolve().parent))

    m = models.model(no_contours=False)
    loaded = tf.keras.models.load_model(ICASSP_2022_MODEL_PATH, compile=False)
    m.set_weights(loaded.get_weights())
    feat = next(l for l in m.layers if l.name == "re_lu_3").output
    # rebuild the head architecture (must match train_velocity_head.py)
    x = tf.keras.layers.Conv2D(16, 3, padding="same", activation="relu")(feat)
    x = tf.keras.layers.Conv2D(1, 1, activation="sigmoid")(x)
    vout = tf.keras.layers.Reshape((172, 88))(x)
    full = tf.keras.Model(m.input, vout)
    # load head weights into the last layers: easiest is to build the head
    # standalone, load, then copy.
    from train_velocity_head import build_head  # noqa

    head = build_head()
    head.load_weights(str(head_weights))
    # copy weights by layer order (head layers are the last 3 of full)
    for src, dst in zip(head.layers[1:], full.layers[-3:]):
        dst.set_weights(src.get_weights())
    full.trainable = False
    return full


def stitch_velocity(model, audio):
    """audio: float32 mono 22050. Returns [n_frames, 88] velocity in [0,1]."""
    import tensorflow as tf

    overlap_len = N_OVERLAP_FRAMES * FFT_HOP
    hop_size = AUDIO_N_SAMPLES - overlap_len
    # pad like basic_pitch (overlap/2 zeros at start)
    padded = np.concatenate([np.zeros(overlap_len // 2, dtype=np.float32), audio])
    outs = []
    for i in range(0, len(padded), hop_size):
        win = padded[i:i + AUDIO_N_SAMPLES]
        if len(win) < AUDIO_N_SAMPLES:
            win = np.pad(win, (0, AUDIO_N_SAMPLES - len(win)))
        outs.append(win.reshape(1, AUDIO_N_SAMPLES, 1))
    batch = np.concatenate(outs, axis=0)
    preds = model.predict(batch, verbose=0)  # [n_win, 172, 88]
    n_olap = N_OVERLAP_FRAMES // 2
    if n_olap > 0:
        preds = preds[:, n_olap:-n_olap, :]
    flat = preds.reshape(-1, 88)
    n_frames = int(len(audio) * ANNOTATIONS_FPS / SR)
    return flat[:n_frames]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--head", type=Path, required=True)
    ap.add_argument("--test", nargs="+", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--onset-threshold", type=float, default=0.7)
    ap.add_argument("--frame-threshold", type=float, default=0.4)
    ap.add_argument("--min-note-len", type=int, default=5)
    a = ap.parse_args()
    from basic_pitch import inference
    from basic_pitch import ICASSP_2022_MODEL_PATH

    print("building trunk+head...", flush=True)
    vmodel = build_trunk_head(a.head)
    smodel = inference.Model(str(ICASSP_2022_MODEL_PATH))
    res = {"head": str(a.head), "tests": {}}
    for d in a.test:
        pairs = list(ft.read_pairs(d))
        clip_rows = []
        for stem, wav_path, mid_path in pairs:
            import soundfile as sf

            audio, sr = sf.read(str(wav_path), dtype="float32")
            assert sr == SR
            vmap = stitch_velocity(vmodel, audio)
            out = inference.run_inference(str(wav_path), smodel)
            events = ft.decode(out, a.onset_threshold, a.frame_threshold, a.min_note_len)
            est = []
            for s, e, p, *_ in events:
                fs = int(round(s * ANNOTATIONS_FPS))
                fe = int(round(e * ANNOTATIONS_FPS))
                fs, fe = max(0, fs), min(len(vmap), fe)
                if fe <= fs or not 21 <= int(p) <= 108:
                    continue
                v = float(np.median(vmap[fs:fe, int(p) - 21])) * 127.0
                est.append((s, e, int(p), min(127.0, max(1.0, v))))
            ref = ft.midi_notes(mid_path)
            matched = vs.match_notes(ref, [(s, e, p, v / 127.0) for s, e, p, v in est])
            # match_notes returns (ref_vel, est_vel) with est_vel in 0-127
            if matched:
                rvs = [m[0] for m in matched]
                evs = [m[1] for m in matched]
                mae = sum(abs(x - y) for x, y in matched) / len(matched)
                r = vs.pearson(rvs, evs)
            else:
                mae, r = float("nan"), float("nan")
            clip_rows.append({"stem": stem, "n_matched": len(matched),
                              "vel_mae": mae, "vel_r": r})
            if len(clip_rows) % 20 == 0:
                print(f"  {d.name}: {len(clip_rows)}/{len(pairs)}", flush=True)
        wsum = sum(c["n_matched"] for c in clip_rows)
        wmae = (sum(c["vel_mae"] * c["n_matched"] for c in clip_rows
                    if c["vel_mae"] == c["vel_mae"]) / wsum) if wsum else 0.0
        rs = [c["vel_r"] for c in clip_rows if c["vel_r"] == c["vel_r"]]
        s = {"n_clips": len(clip_rows), "matched_notes": wsum,
             "vel_mae": round(wmae, 2), "vel_r": round(sum(rs) / len(rs), 3) if rs else 0.0}
        res["tests"][d.name] = s
        print(f"{d.name}: matched={wsum} vel_mae={s['vel_mae']:.2f} r={s['vel_r']:.3f}", flush=True)
    a.out.write_text(json.dumps(res, indent=1))


if __name__ == "__main__":
    main()
