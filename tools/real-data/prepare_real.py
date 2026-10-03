#!/usr/bin/env python3
"""Turn real recordings with aligned note annotations into fine-tune pairs.

Writes <out>/<split>/<stem>.wav (22050 Hz mono 16-bit, what scripts/finetune-basic-pitch
needs) + <stem>.mid, cut into --chunk-second pieces with the notes cropped to each piece
(notes whose onset falls before a piece starts are dropped from that piece).

Datasets (download them yourself; see docs/finetune-data.md for licenses):
  guitarset  --src DIR with annotation/*.jams and audio/*_mic.wav (Zenodo 3371780, CC BY 4.0)
             split by player: 00-04 -> train, 05 -> test
  smd        --src DIR of SMD-piano_v2 (wav + midi pairs; Zenodo 13753319, CC BY 3.0)
             split by piece (deterministic hash): ~25% test
  maestro    --src the maestro-v3.0.0 zip URL or path (CC BY-NC-SA 4.0; NON-COMMERCIAL)
             streams only the chosen files with remotezip. Uses MAESTRO's own split:
             --maestro-train N pieces from "train", --maestro-test M pieces from "test".

Usage:
  tools/real-data/prepare_real.py guitarset --src real/guitarset --out real/pairs
  tools/real-data/prepare_real.py smd --src real/SMD --out real/pairs
  tools/real-data/prepare_real.py maestro --src https://storage.googleapis.com/magentadata/datasets/maestro/v3.0.0/maestro-v3.0.0.zip \
      --out real/pairs --maestro-train 40 --maestro-test 12
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import subprocess
import tempfile
from pathlib import Path

import numpy as np
import pretty_midi
import soundfile as sf

SR = 22050


def decode(path: Path) -> np.ndarray:
    """Any audio file -> float32 mono 22050 Hz via ffmpeg."""
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-ac", "1", "-ar", str(SR), "-f", "s16le", "-"],
        check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0


def write_chunks(audio: np.ndarray, notes, out_dir: Path, stem: str, chunk_s: float,
                 min_notes: int = 3, max_chunks: int | None = None) -> int:
    """notes: [(start, end, midi_pitch, velocity)]. Returns chunks written."""
    out_dir.mkdir(parents=True, exist_ok=True)
    total = len(audio) / SR
    n = 0
    t0 = 0.0
    while t0 + 4.0 < total:
        t1 = min(t0 + chunk_s, total)
        sel = [(s - t0, min(e, t1) - t0, p, v) for s, e, p, v in notes if t0 <= s < t1 - 0.05]
        if len(sel) >= min_notes:
            seg = audio[int(t0 * SR): int(t1 * SR)]
            peak = float(np.max(np.abs(seg))) or 1.0
            if peak > 0.99:
                seg = seg * (0.99 / peak)
            name = f"{stem}__{n:03d}"
            sf.write(out_dir / f"{name}.wav", seg, SR, subtype="PCM_16")
            pm = pretty_midi.PrettyMIDI()
            inst = pretty_midi.Instrument(program=0)
            for s, e, p, v in sel:
                if 21 <= p <= 108:
                    inst.notes.append(pretty_midi.Note(velocity=int(v), pitch=int(p),
                                                       start=float(s), end=float(max(e, s + 0.03))))
            pm.instruments.append(inst)
            pm.write(str(out_dir / f"{name}.mid"))
            n += 1
            if max_chunks and n >= max_chunks:
                break
        t0 = t1
    return n


def midi_file_notes(mid) -> list:
    pm = pretty_midi.PrettyMIDI(mid if isinstance(mid, str) else io.BytesIO(mid))
    return [(n.start, n.end, n.pitch, n.velocity) for i in pm.instruments if not i.is_drum
            for n in i.notes]


def do_guitarset(a) -> dict:
    src = Path(a.src)
    counts = {"train": 0, "test": 0}
    for jf in sorted((src / "annotation").glob("*.jams")):
        stem = jf.stem
        wav = src / "audio" / f"{stem}_mic.wav"
        if not wav.exists():
            continue
        j = json.loads(jf.read_text())
        notes = []
        for ann in j["annotations"]:
            if ann["namespace"] != "note_midi":
                continue
            for d in ann["data"]:
                notes.append((d["time"], d["time"] + d["duration"], int(round(d["value"])), 90))
        split = "test" if stem.startswith("05_") else "train"
        counts[split] += write_chunks(decode(wav), notes, Path(a.out) / f"guitarset-{split}",
                                      f"gs_{stem}", a.chunk_seconds)
    return counts


def piece_split(name: str, test_frac: float) -> str:
    h = int(hashlib.sha1(name.encode()).hexdigest()[:8], 16) / 0xFFFFFFFF
    return "test" if h < test_frac else "train"


def do_smd(a) -> dict:
    src = Path(a.src)
    counts = {"train": 0, "test": 0}
    wavs = sorted(src.rglob("*.wav")) + sorted(src.rglob("*.mp3"))
    for w in wavs:
        mids = [w.with_suffix(e) for e in (".mid", ".midi")]
        mids += [Path(str(p)) for p in src.rglob(w.stem + ".mid")]
        mid = next((m for m in mids if m.exists()), None)
        if mid is None:
            continue
        split = piece_split(w.stem, a.test_frac)
        counts[split] += write_chunks(decode(w), midi_file_notes(str(mid)),
                                      Path(a.out) / f"smd-{split}", f"smd_{w.stem}", a.chunk_seconds)
    return counts


def do_maestro(a) -> dict:
    from remotezip import RemoteZip

    z = RemoteZip(a.src) if a.src.startswith("http") else __import__("zipfile").ZipFile(a.src)
    rows = list(csv.DictReader(io.StringIO(z.read("maestro-v3.0.0/maestro-v3.0.0.csv").decode())))
    rng = np.random.default_rng(a.seed)
    counts = {}
    for split, k, cap in (("train", a.maestro_train, a.maestro_train_chunks),
                          ("test", a.maestro_test, a.maestro_test_chunks)):
        pool = [r for r in rows if r["split"] == split]
        # one piece per composer+title, so test pieces are distinct works
        seen, picks = set(), []
        for i in rng.permutation(len(pool)):
            r = pool[i]
            key = (r["canonical_composer"], r["canonical_title"])
            if key in seen or float(r["duration"]) > 900:
                continue
            seen.add(key)
            picks.append(r)
            if len(picks) >= k:
                break
        counts[split] = 0
        for r in picks:
            with tempfile.TemporaryDirectory() as td:
                wav = Path(td) / "a.wav"
                wav.write_bytes(z.read("maestro-v3.0.0/" + r["audio_filename"]))
                notes = midi_file_notes(z.read("maestro-v3.0.0/" + r["midi_filename"]))
                stem = "mae_" + Path(r["audio_filename"]).stem[-40:].replace("-", "_")
                counts[split] += write_chunks(decode(wav), notes, Path(a.out) / f"maestro-{split}",
                                              stem, a.chunk_seconds, max_chunks=cap)
            print(f"  {split} {r['canonical_composer']} - {r['canonical_title']}", flush=True)
    return counts


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("dataset", choices=("guitarset", "smd", "maestro"))
    p.add_argument("--src", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--chunk-seconds", type=float, default=30.0)
    p.add_argument("--test-frac", type=float, default=0.25)
    p.add_argument("--seed", type=int, default=0)
    p.add_argument("--maestro-train", type=int, default=40)
    p.add_argument("--maestro-test", type=int, default=12)
    p.add_argument("--maestro-train-chunks", type=int, default=6, help="max chunks per train piece")
    p.add_argument("--maestro-test-chunks", type=int, default=4, help="max chunks per test piece")
    a = p.parse_args()
    counts = {"guitarset": do_guitarset, "smd": do_smd, "maestro": do_maestro}[a.dataset](a)
    print(json.dumps({a.dataset: counts}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
