# Basic Pitch fine-tune experiments

<!-- status -->
**Status (2026-10-03 10:45 PT):** running E2, training, epoch 0/8, 2 min elapsed. Last: n/a
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

| exp | change | val F1 | test-gugs | test-fluidr3 | real sets | notes |
|---|---|---|---|---|---|---|
| E0 | stock ICASSP 2022 | 0.879 (mixed val 0.804) | 0.861 (P 0.79 R 0.95) | 0.901 | GuitarSet 0.802 (0.822 @ onset 0.7); MAESTRO 0.695 (0.716 @ onset 0.6) | baseline. Higher onset thresholds help stock on real audio |
| E1 | original script defaults (2-stage, weighted onset loss pw 0.95, BN training, 400 GUGS piano etudes) | 0.670 (best epoch 0.727) | - | - | - | precision collapsed (P 0.60, R 0.88); never beat stock. Best-epoch restore was broken, so the last epoch was kept |

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
