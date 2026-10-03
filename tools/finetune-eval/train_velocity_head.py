#!/usr/bin/env python3
"""Train a small velocity regression head on frozen Basic Pitch trunk features.

Head: Conv2D(16, 3, same, relu) -> Conv2D(1, 1, sigmoid) -> [172, 88] in [0,1].
Loss: masked MSE (only frames where a reference note is active).
Trunk stays frozen; only the head trains. Features come from
precompute_velocity_features.py (<stem>.npz per chunk).

Usage:
  train_velocity_head.py --train build/velocity-features/train \\
      --val build/velocity-features/val --out build/velocity-head/v1 \\
      [--batch 32 --epochs 30 --lr 1e-3 --patience 5 --seed 0]
"""
import argparse
import json
import os

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "3")

from pathlib import Path

import numpy as np

N_FRAMES, N_PITCH, N_CHAN = 172, 88, 32


def build_head():
    import tensorflow as tf

    inp = tf.keras.Input((N_FRAMES, N_PITCH, N_CHAN))
    x = tf.keras.layers.Conv2D(16, 3, padding="same", activation="relu")(inp)
    x = tf.keras.layers.Conv2D(1, 1, activation="sigmoid")(x)
    out = tf.keras.layers.Reshape((N_FRAMES, N_PITCH))(x)
    return tf.keras.Model(inp, out)


def masked_mse(y_true, y_pred):
    import tensorflow as tf

    mask = tf.cast(y_true > 0, tf.float32)
    sq = tf.square(y_true - y_pred) * mask
    return tf.reduce_sum(sq) / (tf.reduce_sum(mask) + 1e-6)


def batch_generator(npz_paths, batch_size, rng, shuffle=True):
    """Yield (x, y) batches; mask derived from y>0 in loss."""
    import numpy as np

    while True:
        order = rng.permutation(len(npz_paths)) if shuffle else np.arange(len(npz_paths))
        feats, tgts = [], []
        for i in order:
            d = np.load(npz_paths[i])
            feats.append(d["feat"].astype(np.float32))
            tgts.append(d["target"].astype(np.float32))
            while sum(f.shape[0] for f in feats) >= batch_size:
                f = np.concatenate(feats, axis=0)
                t = np.concatenate(tgts, axis=0)
                bf, bt = f[:batch_size], t[:batch_size]
                rf, rt = f[batch_size:], t[batch_size:]
                feats = [rf] if len(rf) else []
                tgts = [rt] if len(rt) else []
                idx = rng.permutation(batch_size) if shuffle else np.arange(batch_size)
                yield bf[idx], bt[idx]


def masked_mae(model, npz_paths):
    """Mean |pred - target| in 0-127 units over active frames."""
    import tensorflow as tf

    feats, tgts = [], []
    for p in npz_paths:
        d = np.load(p)
        feats.append(d["feat"].astype(np.float32))
        tgts.append(d["target"].astype(np.float32))
    f = np.concatenate(feats, axis=0)
    t = np.concatenate(tgts, axis=0)
    pred = model.predict(f, batch_size=64, verbose=0)
    m = t > 0
    num = np.abs(pred[m] - t[m]).sum() * 127.0
    den = m.sum()
    return num / den if den else float("nan")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--train", type=Path, required=True)
    ap.add_argument("--val", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--batch", type=int, default=32)
    ap.add_argument("--epochs", type=int, default=30)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--patience", type=int, default=5)
    ap.add_argument("--seed", type=int, default=0)
    a = ap.parse_args()

    import tensorflow as tf

    train_paths = sorted(a.train.glob("*.npz"))
    val_paths = sorted(a.val.glob("*.npz"))
    assert train_paths and val_paths, "no .npz files found"
    print(f"train files: {len(train_paths)}, val files: {len(val_paths)}", flush=True)

    # count windows for steps_per_epoch
    w0 = np.load(train_paths[0])["feat"].shape[0]
    steps = max(1, len(train_paths) * w0 // a.batch)
    print(f"~{steps} steps/epoch", flush=True)

    model = build_head()
    model.compile(optimizer=tf.keras.optimizers.Adam(a.lr), loss=masked_mse)
    model.summary(print_fn=lambda s: print(s, flush=True))
    a.out.mkdir(parents=True, exist_ok=True)

    rng = np.random.default_rng(a.seed)
    gen = batch_generator(train_paths, a.batch, rng, shuffle=True)
    best, bad, hist = float("inf"), 0, []
    for epoch in range(a.epochs):
        model.fit(gen, steps_per_epoch=steps, verbose=0)
        vm = masked_mae(model, val_paths)
        hist.append(vm)
        tag = ""
        if vm < best:
            best, bad, tag = vm, 0, " *"
            model.save_weights(str(a.out / "head.weights.h5"))
        else:
            bad += 1
        print(f"epoch {epoch}: val masked MAE {vm:.2f} (best {best:.2f}){tag}", flush=True)
        if bad >= a.patience:
            print(f"early stop at epoch {epoch}", flush=True)
            break
    (a.out / "history.json").write_text(json.dumps(
        {"val_masked_mae_127": hist, "best": best, "args": vars(a)}, indent=1, default=str))
    print(f"best val masked MAE: {best:.2f} (0-127 units)", flush=True)


if __name__ == "__main__":
    main()
