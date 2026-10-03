# Follow-up prompt: fine-tune on the MacBook, bundle into EarSheet

Run this only after phase A of prompts/hearsheet-prompt.md is green. Do not change the app identity, the scheme, or the Basic Pitch graph.

Repo: https://github.com/yishengjiang99/earsheet
Machine: the developer MacBook. Training does not run on the phone and does not run in GitHub Actions.

## CLI

From the repo root:

```
python3 -m venv .venv
source .venv/bin/activate
pip install 'basic-pitch[tf]' coremltools
scripts/finetune-basic-pitch --smoke
```

Smoke must print ok for tensorflow, basic_pitch, and coremltools, and must find the ICASSP 2022 weights. If it would train from scratch, stop. Upstream basic_pitch/train.py always builds a fresh model; scripts/finetune-basic-pitch loads those weights into models.model() before any fit.

Data is paired only. Each example is basename.wav + basename.mid from tools/poly-render (SF2OfflineRenderer.render in Packages/SF2Player). No unlabeled audio.

```
scripts/finetune-basic-pitch --pairs ~/earsheet-data/train --val ~/earsheet-data/val --epochs 8 --lr 1e-4
```

Serialize with basic_pitch.data.tf_example_serialization.to_transcription_tfexample before fit. Source tag synthetic_sf2. Audio 22050 Hz stereo inside the TFExample. Loss models.loss(label_smoothing=0.2, weighted=True), onset positive weight 0.95. Adam 1e-4, then 1e-5. Early stop on val note-event F1, patience 8. Cap 40 epochs. Freeze harmonic stacking for 2 epochs, then unfreeze.

Eval with inference.predict and mir_eval, 50 ms onset tolerance, against the frozen ICASSP checkpoint and against the real phone-mic gate (at least 30 clips, never trained on). Ship the fine-tune only if synthetic val note F1 is at least the original and real-mic note F1 is not more than 2 points worse. Write both tables to build/finetune/metrics.json.

## Export contract

The iOS decoder already expects:
- input waveform [1, 43844, 1] at 22050 Hz mono
- note [1, 172, 88], onset [1, 172, 88], contour [1, 172, 264]

Stock Keras Basic Pitch consumes a harmonic-stacked CQT, not raw audio. The export must include that frontend or the app must apply the same frontend before the package. Do not silently change either side. Fail the bundle if decoded notes differ from TensorFlow on 5 clips. fp16 if notes match, else fp32. Name the package BasicPitchPoly.mlpackage.

```
scripts/bundle-coreml build/BasicPitchPoly.mlpackage
scripts/fetch-models
```

bundle-coreml copies the package to models/BasicPitchPoly.mlpackage (gitignored) and writes a `local` line plus sha256 into models.lock. fetch-models is what ios-sim.yml and the app already call. Do not commit the mlpackage.

## App

HearSheet loads whatever fetch-models placed at models/BasicPitchPoly.mlpackage. No new load path. No second player. Playback stays SF2MIDIPlayer.

Done when a device build transcribed with the fine-tuned package still passes the phase A triad test, models.lock pins the sha256, and the PR says whether the ship rule passed or the stock weights stayed.
