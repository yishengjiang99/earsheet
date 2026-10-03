# Basic Pitch fine-tune experiments

<!-- status -->
**Current status (2026-10-03 11:56 PT):** E6 final eval + E7 (onset pos weight 0.01, 2 epochs) in parallel: ft-e6.log, final evaluation, epoch 4/8, 29 min since start. Last: [val-f1] epoch 4: note F1 0.7865 P 0.744 R 0.858 (best 0.8052). Full history: Status log at the bottom (append-only).
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
| E4b | E4 + class-balanced onset loss (pos weight 0.95) | 0.384 / 0.272 / 0.262 | | | | | | | | onsets everywhere (P 0.19-0.30). Plain BCE is about pos weight 0.001 (positives are about 0.1% of onset cells), and 0.95 is far too high |
| E5 probes | all data, lr 3e-5, 1 epoch x 300 steps, onset pos weight 0.1 / **0.03** / 0.3 | 0.747 / **0.813** / (running) | | | | | | | | pw 0.03 is the first setting to beat stock on mixed val (0.813 vs 0.804) |
| E6 | all data, onset pos weight 0.03, lr 3e-5, 8-epoch cosine (stopped at 4, best = epoch 1) | 0.805 (ep1), 0.791, 0.791, 0.787 | 0.874 / tuned 0.904 | 0.857 / 0.909 | 0.676 / 0.731 | 0.785 / 0.832 | 0.703 / 0.720 | 0.727 / 0.761 | same as stock (742 KB tfjs) | Default decoder: better on SMD (+0.024), MAESTRO (+0.008), synth multi (+0.03); worse on GuitarSet (-0.017) and FluidR3 (-0.044). **With tuned decoders, stock still wins on all real sets**: stock tuned [0.7, 0.4, 5] gives GuitarSet 0.843, MAESTRO 0.735, SMD 0.762, while E6 tuned [0.6, 0.4, 7] gives 0.832 / 0.720 / 0.761. Not shipped. Release [model-ft-exp6](https://github.com/yishengjiang99/earsheet/releases/tag/model-ft-exp6) |
| E0t2 | stock, decoder tuned on mixed val with the min_note_len grid: onset 0.7, frame 0.4, min note 5 frames (58 ms) | (tuning set) | 0.887 | 0.921 | 0.731 | **0.843** | **0.735** | **0.762** | 742 KB | the best real-audio numbers so far: +0.04 to +0.06 over Spotify defaults with no retraining |
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

## Status log

Append-only and oldest first. Each loop adds entries here; old entries are never edited
or removed. Entries before 11:30 PT were rebuilt from git history (`git log -p --follow`),
because the earlier status line was overwritten in place. The text in quotes is the
original wording.

| time (PT) | experiment | entry | commit |
|---|---|---|---|
| 2026-10-03 10:33 | E0, E1 | Logged. E0 stock: "synthetic val 0.879, test-gugs 0.861 (P 0.79 R 0.95), test-fluidr3 0.901, real: pending". E1 (original script defaults: 2-stage, weighted onset loss pw 0.95, BN training, 400 GUGS piano etudes): "0.670 (best epoch 0.727); precision collapsed (P 0.60, R 0.88); never beat stock. Best-epoch restore was broken, so the last epoch was kept". Not shipped | b1f02fd |
| 2026-10-03 10:44 | E2 started | Stock real-audio baselines: "GuitarSet 0.802 (0.822 @ onset 0.7); MAESTRO 0.695 (0.716 @ onset 0.6). Higher onset thresholds help stock on real audio". Eval sets then: "guitarset-test: GuitarSet player 05 (real, mic), 30 s chunks, 80 clips; maestro-test: MAESTRO v3 test split pieces; smd-test: pending". Added DATA.md (licenses) | f9b35ab |
| 2026-10-03 10:45 | E2 | Status: "running E2, training, epoch 0/8, 2 min elapsed" | f64522f |
| 2026-10-03 10:55 | E2 | Status: "running E2, final evaluation on test sets, epoch 3/8, 12 min elapsed. Last: [val-f1] epoch 3: note F1 0.6658 P 0.703 R 0.668 (best 0.8039)" | a6263c3 |
| 2026-10-03 10:56 | E2 result | Fixed trainer on synthetic piano: mixed val 0.673 / 0.673 / 0.666 vs stock 0.804, so stock was kept. E0t (stock, onset threshold 0.7) wins on every held-out set. Next then: "E4 (running): all data ..., lr 3e-5; E3: multi-SoundFont synthetic only (ablation)" | 7c18061 |
| 2026-10-03 11:02 | E4 result | Plain BCE + all data, lr 3e-5: mixed val 0.760 (ep1), 0.721 (ep2), stopped. Root cause: plain BCE collapses the onset head (max onset 0.97 down to 0.5-0.8). Weighted onset loss made the default; min_note_len added to the decoder grid (stock MAESTRO val 0.762 at 11 frames, 0.801 at 7). iOS handoff doc; model-ft-exp0 / model-latest releases (stock reference) | 9702000 |
| 2026-10-03 11:05 | E4b | Status: "running E4b, training, epoch 2/8. Last: [val-f1] epoch 1: note F1 0.3841 P 0.297 R 0.613 (best 0.8039)" | 90f8baf |
| 2026-10-03 11:15 | E4b | Status: "running E4b, final evaluation on test sets, epoch 3/8, 13 min elapsed. Last: [val-f1] epoch 3: note F1 0.2623 P 0.186 R 0.530 (best 0.8039)" | 0470760 |
| 2026-10-03 11:25 | E5 probes | Status: "E5 probes (onset positive weight 0.1/0.03/0.3, 1 epoch each)" | 5071e35 |
| 2026-10-03 11:30 | E4b result, E5 probes | E4b (class-balanced onset loss, pos weight 0.95): mixed val 0.384, 0.272, 0.262 (P 0.19-0.30) and stopped; it over-predicts onsets the other way. Probes, 1 epoch each, all data, lr 3e-5: **pw 0.03: 0.8132 (P 0.782 R 0.866), first run to beat stock 0.8039**; pw 0.1: 0.7467 (P 0.682 R 0.845); pw 0.3 running. Next: full E6 run with pw 0.03 | (this commit) |
| 2026-10-03 11:26 | e5 | Status (auto): E5: ft-probe-pw0.3.log, final evaluation, epoch 0/1, 10 min since start. Last: [val-f1] epoch 1: note F1 0.6012 P 0.514 R 0.747 (best 0.8039) | (auto) |
| 2026-10-03 11:36 | e6 | Status (auto): E6 (all data, onset pos weight 0.03, lr 3e-5, 8 epochs): ft-e6.log, final evaluation, epoch 4/8, 9 min since start. Last: [val-f1] epoch 4: note F1 0.7865 P 0.744 R 0.858 (best 0.8052) | (auto) |
| 2026-10-03 11:46 | e6 | Status (auto): E6 final eval + E7 (onset pos weight 0.01, 2 epochs) in parallel: ft-e6.log, final evaluation, epoch 4/8, 19 min since start. Last: [val-f1] epoch 4: note F1 0.7865 P 0.744 R 0.858 (best 0.8052) | (auto) |
| 2026-10-03 11:56 | e6 | Status (auto): E6 final eval + E7 (onset pos weight 0.01, 2 epochs) in parallel: ft-e6.log, final evaluation, epoch 4/8, 29 min since start. Last: [val-f1] epoch 4: note F1 0.7865 P 0.744 R 0.858 (best 0.8052) | (auto) |
| 2026-10-03 11:58 | E6 result | E6 (all data, onset pos weight 0.03, 8-epoch schedule) peaked at epoch 1 (mixed val 0.805, then 0.791 / 0.791 / 0.787) and stopped. Held-out at default decoder vs stock: SMD 0.727 vs 0.703, MAESTRO 0.703 vs 0.695, GuitarSet 0.785 vs 0.802, FluidR3 0.857 vs 0.901. With each model's tuned decoder, stock wins on real audio (stock [0.7/0.4/5]: GuitarSet 0.843, MAESTRO 0.735, SMD 0.762; E6: 0.832 / 0.720 / 0.761). Not shipped; published as release model-ft-exp6. E7 (pos weight 0.01, 2 epochs) reached mixed val 0.8166 at epoch 1 (P 0.801 R 0.854); full held-out comparison running. Export fix: fine-tuned graphs name the input input_1, so it is renamed to input_2 for Core ML | (this commit) |
