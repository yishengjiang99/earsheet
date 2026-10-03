#!/usr/bin/env python3
"""Precompute frozen Basic Pitch trunk features + velocity targets for head training.

For each (basename.wav + basename.mid) pair dir: extracts random 43844-sample
windows, runs the stock ICASSP 2022 trunk up to re_lu_3 -> [172, 88, 32], and
builds per-frame velocity targets [172, 88] (vel/127 on active note frames).

Writes one <stem>.npz per chunk: feat (float16 [W, 172, 88, 32]),
target (float16 [W, 172, 88]). Reusable across head experiments.

Usage:
  precompute_velocity_features.py --pairs real/maestro-train real/smd-train \\
      --out build/velocity-features/train [--windows-per-track 4 --seed 0]
"""
import argparse
import os

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "3")

from pathlib import Path

import numpy as np

WINDOW = 43844
N_FRAMES = 172
N_PITCH = 88
SR = 22050
HOP = 256 / SR


def load_audio(wav_path):
    import soundfile as sf

    audio, sr = sf.read(str(wav_path), dtype="float32")
    assert sr == SR, f"{wav_path}: sr {sr}"
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    return audio


def velocity_target(notes, t0, n_frames=N_FRAMES):
    """notes: [(start_s, end_s, midi, vel)]. Returns [n_frames, 88] float32 in [0,1]."""
    tgt = np.zeros((n_frames, N_PITCH), dtype=np.float32)
    for start, end, pitch, vel in notes:
        if not 21 <= pitch <= 108:
            continue
        s = int(np.clip(round((start - t0) / HOP), 0, n_frames))
        e = int(np.clip(round((end - t0) / HOP), 0, n_frames))
        if e <= s:
            continue
        v = min(127, max(1, int(vel))) / 127.0
        tgt[s:e, pitch - 21] = np.maximum(tgt[s:e, pitch - 21], v)
    return tgt


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pairs", nargs="+", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--windows-per-track", type=int, default=4)
    ap.add_argument("--seed", type=int, default=0)
    a = ap.parse_args()

    import tensorflow as tf
    from basic_pitch import ICASSP_2022_MODEL_PATH, models

    print("loading stock model...", flush=True)
    m = models.model(no_contours=False)
    loaded = tf.keras.models.load_model(ICASSP_2022_MODEL_PATH, compile=False)
    m.set_weights(loaded.get_weights())
    feat_layer = next(l for l in m.layers if l.name == "re_lu_3")
    extractor = tf.keras.Model(m.input, feat_layer.output)
    print("extractor ready", flush=True)

    # import here so TF doesn't have to be up for --help
    import importlib.machinery
    import importlib.util

    ROOT = Path(__file__).resolve().parents[2]
    _l = importlib.machinery.SourceFileLoader("ft", str(ROOT / "scripts" / "finetune-basic-pitch"))
    _s = importlib.util.spec_from_loader("ft", _l)
    ft = importlib.util.module_from_spec(_s)
    _l.exec_module(ft)

    rng = np.random.default_rng(a.seed)
    a.out.mkdir(parents=True, exist_ok=True)
    n_chunks = n_windows = 0
    for d in a.pairs:
        for stem, wav_path, mid_path in ft.read_pairs(d):
            if (a.out / f"{stem}.npz").exists():
                continue
            audio = load_audio(wav_path)
            if len(audio) < WINDOW:
                continue
            notes = ft.midi_notes(mid_path)
            if not notes:
                continue
            feats, tgts = [], []
            for _ in range(a.windows_per_track):
                s0 = int(rng.integers(0, len(audio) - WINDOW + 1))
                win = audio[s0:s0 + WINDOW].reshape(1, WINDOW, 1)
                f = extractor.predict(win, verbose=0)[0]
                t = velocity_target(notes, s0 / SR)
                feats.append(f.astype(np.float16))
                tgts.append(t.astype(np.float16))
            np.savez_compressed(a.out / f"{stem}.npz",
                                feat=np.stack(feats), target=np.stack(tgts))
            n_chunks += 1
            n_windows += len(feats)
            if n_chunks % 50 == 0:
                print(f"  {n_chunks} chunks, {n_windows} windows", flush=True)
    print(f"done: {n_chunks} chunks, {n_windows} windows -> {a.out}", flush=True)


if __name__ == "__main__":
    main()
