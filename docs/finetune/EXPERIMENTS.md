# Basic Pitch fine-tune experiments

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
| guitarset-test | GuitarSet player 05 (real, mic), 30 s chunks | 80 |
| maestro-test | MAESTRO v3 "test" split pieces (real piano) | see below |
| smd-test | Saarland Music Data piano, piece-level split (real piano) | see below |

Caveat: stock Basic Pitch was trained on GuitarSet and MAESTRO, among other data. Its
scores on those sets may be optimistic, and they are not fully independent tests for
stock. SMD was not in its training data, so SMD is the primary real-audio check.

## Results

| exp | change | val F1 | test-gugs | test-fluidr3 | real sets | notes |
|---|---|---|---|---|---|---|
| E0 | stock ICASSP 2022 | 0.879 | 0.861 (P 0.79 R 0.95) | 0.901 | pending | baseline |
| E1 | original script defaults (2-stage, weighted onset loss pw 0.95, BN training, 400 GUGS piano etudes) | 0.670 (best epoch 0.727) | - | - | - | precision collapsed (P 0.60, R 0.88); never beat stock. Best-epoch restore was broken, so the last epoch was kept |

## Fixes to the trainer found along the way

- mir_eval `precision_recall_f1_overlap` returns 4 values. The script unpacked 3 and crashed (this affected macOS too).
- Per-head sample weights broke Keras 2.15 ("Can not squeeze dim[0]"), so they were dropped. All heads are always labelled.
- The train and val windowing were reversed: train used fixed windows and val used random ones.
- Best weights were saved as a TF checkpoint but checked as a single file, so they were never restored. Now saved as `.h5`.
- Early stopping now starts from stock's val F1, so a run that never beats stock keeps stock.
- On Linux the Core ML export is skipped (it needs macOS). Training and eval run anywhere.
