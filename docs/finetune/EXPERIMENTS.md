# Basic Pitch fine-tune experiments

<!-- status -->
**Status (2026-10-03 11:05 PT):** running E4b, training, epoch 2/8, 2 min elapsed, ETA ≤ ~17 min (early stop may end sooner). Last: [val-f1] epoch 1: note F1 0.3841 P 0.297 R 0.613 (best 0.8039)
<!-- /status -->

Goal: the best polyphonic transcription model for the web demo and the iOS app that is
"not too big". That means the same architecture and I/O as stock Basic Pitch (ICASSP 2022,
about 0.74 MB of TF.js weights), real time on WASM, and wins on **real** audio, not only
on synthetic renders.

Metric: mir_eval note onset F1 with 50 ms tolerance (offsets ignored), averaged over
clips. Decoder thresholds are onset 0.5 and frame 0.3 unless a row says otherwise.
Hardware: 8-core x86 CPU, no GPU, 15 GB RAM.

## Eval sets (all held out from training)

| id | what | clips |
|---|---|---|
| val | poly-render-py, GeneralUser GS piano, seed 1007 | 60 x 12 s |
| test-gugs | same generator, seed 2007 | 60 |
| test-fluidr3 | same generator, FluidR3_GM (unseen SoundFont) | 60 |
| test-multi-fluidr3 | poly-render-py multi-instrument (19 GM programs), dense patterns, velocity 25-127, reverb/chorus, unseen SoundFont FluidR3 | 80 x 12 s |
| guitarset-test | GuitarSet player 05 (real, mono mic), 30 s chunks; players 00-03 train, part of 04 val | 80 |
| maestro-test | MAESTRO v3 "test" split, 12 distinct works, up to 4 x 30 s chunks each | 48 |
| smd-test | Saarland Music Data piano, piece-level split (real Disklavier) | pending (downloading) |

The validation set for early stopping and threshold tuning is the same for every
experiment from E2 on: synthetic val (60) + GuitarSet val (20 chunks from player 04)
+ MAESTRO val (28 chunks from 5 "train" split pieces that are kept out of training).
Stock scores 0.804 on that mixed val.

Caveat: stock Basic Pitch was trained on GuitarSet and MAESTRO, among other data. Its
scores on those sets may be optimistic, and they are not fully independent tests for
stock. SMD was not in its training data, so SMD is the primary real-audio check.

## Results

Columns are onset-F1 on held-out sets. "mixed val" = synth val + GuitarSet val + MAESTRO val (108 clips).

| exp | change | mixed val | test-gugs | test-fluidr3 | test-multi-fluidr3 | GuitarSet p05 (real) | MAESTRO test (real) | SMD test (real) | size | notes |
|---|---|---|---|---|---|---|---|---|---|---|
| E0 | stock ICASSP 2022, thresholds 0.5/0.3 | 0.804 | 0.861 | 0.901 | 0.646 | 0.802 | 0.695 | (E4 run) | 742 KB tfjs bin | baseline |
| E0t | stock, onset threshold 0.7 / frame 0.3 (tuned on mixed val) | - | **0.892** | **0.922** | **0.715** | **0.822** | **0.701** | (E4 run) | same | free win: higher onset threshold cuts false onsets everywhere (P 0.79 to 0.84 on gugs, 0.77 to 0.82 on GuitarSet) |
| E2 | fixed trainer (plain BCE, BN frozen, warmup+cosine 1e-4, gain/EQ/reverb/noise aug), 400 GUGS piano etudes | 0.673 (ep1) / 0.673 / 0.666 | (kept stock) | | | | | | | early stop at epoch 3, never beat stock 0.804, stock kept. A side check of the epoch-2 weights: synth val 0.827 (0.916 at tuned thresholds) but MAESTRO val fell from about 0.70 to 0.52. Synthetic-piano-only fine-tuning overfits the renderer timbre and hurts real piano |
| E4 | E2 trainer + all data: 400 GUGS + 700 GM multi-instrument (4 SF2s) + 300 piano (Salamander, Upright KW, MuseScore) + 150 guitar (Spanish Classical) etudes + real GuitarSet p00-03 (320 x 30 s), MAESTRO 35 train pieces (206), SMD train works (438); lr 3e-5 | 0.760 (ep1), 0.721 (ep2) | | | | | | | | stopped at epoch 2 (falling). **Root cause for E2/E4: plain BCE collapses the onset head.** Max onset posterior fell from about 0.97 (stock) to 0.52 (E2) / 0.79 (E4), so notes only come from inferred onsets and recall drops. The Basic Pitch paper trains onsets with class-balanced BCE; that is now the default again (`--onset-loss weighted`) |
| E1 | original script defaults (2-stage, weighted onset loss pw 0.95, BN training, 400 GUGS piano etudes) | synth val only: 0.670 (best epoch 0.727) vs stock 0.879 | | | | | | | | precision collapsed (P 0.60, R 0.88); never beat stock. Best-epoch restore was broken, so the last epoch was kept |

## Decoder finding (no training needed)

Spotify's `min_note_len` of 11 frames (128 ms) drops fast real-piano notes. On 14 MAESTRO
val chunks, stock F1 goes from 0.762 at 11 frames / onset 0.5, to 0.768 at 11 / 0.7,
to **0.801 at 7 / 0.7**. The threshold tuner now grids onset x frame x min_note_len {5, 7, 11}.

## Next

- E4b (running): E4 data + class-balanced onset loss (pos weight 0.95), BN frozen, lr 3e-5
- E3: multi-SoundFont synthetic only (ablation), if time allows
- Candidates are published as GitHub release assets (see "Artifacts").

## Artifacts

Weights live in GitHub releases, never in git. Each release has a SavedModel zip, a
TF.js zip, a Core ML `BasicPitchPoly.mlpackage` zip, `SHA256SUMS`, and a
`models.lock.snippet`. They are built by `tools/model-export/export-model.sh`.

- **Latest: [model-latest](https://github.com/yishengjiang99/earsheet/releases/tag/model-latest)**, currently the stock reference export (`model-ft-exp0`); no fine-tune has beaten stock yet
- [model-ft-exp0](https://github.com/yishengjiang99/earsheet/releases/tag/model-ft-exp0): stock ICASSP 2022 through the export pipeline (recommended thresholds onset 0.7 / frame 0.3)
- iOS integration: [IOS_MODEL_HANDOFF.md](IOS_MODEL_HANDOFF.md)

## Plan

- E2: fixed trainer (plain BCE, BN frozen, warmup + cosine LR 1e-4, augmentation: gain/EQ/reverb/noise), same 400 GeneralUser piano etudes as E1
- E3: + multi-SoundFont / multi-instrument synthetic data (1150 more etudes from 7 SoundFonts; FluidR3 kept unseen for test)
- E4: + real recordings (GuitarSet train players, MAESTRO train subset, SMD train pieces)
- E5: decoder threshold tuning on val for the best model (and stock), then a ship decision

Data sources and licenses: [DATA.md](DATA.md).

## Fixes to the trainer found along the way

- mir_eval `precision_recall_f1_overlap` returns 4 values. The script unpacked 3 and crashed (this affected macOS too).
- Per-head sample weights broke Keras 2.15 ("Can not squeeze dim[0]"), so they were dropped. All heads are always labelled.
- The train and val windowing were reversed: train used fixed windows and val used random ones.
- Best weights were saved as a TF checkpoint but checked as a single file, so they were never restored. Now saved as `.h5`.
- Early stopping now starts from stock's val F1, so a run that never beats stock keeps stock.
- On Linux the Core ML export is skipped (it needs macOS). Training and eval run anywhere.
