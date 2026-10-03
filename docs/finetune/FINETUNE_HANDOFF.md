# Basic Pitch fine-tuning: methodology, results, and what to try next

A self-contained summary of the October 2026 fine-tuning effort for EarSheet's polyphonic
transcription model. The outcome: **no fine-tune beat stock Basic Pitch on held-out
real audio. We ship the stock weights with a tuned decoder (onset 0.7, frame 0.4, min
note 5 frames).** Full per-run log: [EXPERIMENTS.md](EXPERIMENTS.md) (append-only status
log at the bottom). Data licenses: [DATA.md](DATA.md). App integration:
[IOS_MODEL_HANDOFF.md](IOS_MODEL_HANDOFF.md).

## 1. Methodology

### 1.1 Constraints

- **Model:** same architecture and I/O as stock Basic Pitch (ICASSP 2022 "NMP"):
  - input `[1, 43844, 1]` at 22,050 Hz
  - outputs contour `[1,172,264]` (`Identity`), note `[1,172,88]` (`Identity_1`), onset `[1,172,88]` (`Identity_2`)
  - **16,864 parameters**: 742 KB TF.js bin (which includes the CQT kernels), 146 KB Core ML `weight.bin`
  - must stay real time in WASM, so no architecture changes
- **Hardware:** one shared Linux box with 8 x86 cores, about 6 GB free RAM, **no GPU**.
- **Environment:**
  - Python 3.11, `basic-pitch[tf]==0.4.0`, TF 2.15 (Keras 2), `setuptools<81`
  - TF.js conversion: tensorflowjs 4.22 in its own env
  - Core ML conversion: coremltools 8.3 + TF 2.15.1 in its own env

### 1.2 Data

All audio is 22,050 Hz mono 16-bit, paired with `basename.mid`. Nothing is committed.

**Synthetic renders** (`tools/poly-render-py/poly_render.py`, FluidSynth, deterministic
splitmix64 generator, 12 s etudes on a 16th-note grid):

| set | count | SoundFonts | generator options | role |
|---|---|---|---|---|
| `train` | 400 | GeneralUser GS | piano, 4 patterns (chord loop + bass, scales, arpeggios, random walk + bass), velocity 70-105, seed 7 | train |
| `train-gm` | 700 | GeneralUser GS, MuseScore General, TimGM6mb, sf_GMbank (one per etude) | 19 GM programs (pianos, EP, harpsichord, vibes, organs, guitars, strings, brass, reeds, flute); `--multi-instrument` (notes below MIDI 55 on a second program); `--extra-patterns` (dense 4-6-note voicings, fast 16th runs, melody over sustained chords); velocity 25-127; reverb p=0.5, chorus p=0.3, gain 0.5-1.2; seed 11 | train |
| `train-piano` | 300 | Salamander Grand V3 (CC BY 3.0), Upright Piano KW (CC0), MuseScore General | piano, same options, seed 12 | train |
| `train-guitar` | 150 | Spanish Classical Guitar (CC0) | notes octave-folded into 40-84, seed 13 | train |
| `val` | 60 | GeneralUser GS | default piano generator, seed 1007 | validation |
| `test-gugs` | 60 | GeneralUser GS | seed 2007 | test (seen timbre) |
| `test-fluidr3` | 60 | **FluidR3_GM (never trained on)** | seed 3007 | test (unseen timbre) |
| `test-multi-fluidr3` | 80 | FluidR3_GM | multi-instrument options, seed 4007 | test (unseen timbre, dense/multi) |

Rendering 1,150 etudes with `--jobs 6` took about 4 minutes. With default options,
`poly_render.py` output is byte-identical to the original version (verified with `diff -r`).

**Real recordings** (`tools/real-data/prepare_real.py`): cut into 30 s chunks; notes
cropped to the chunk; notes whose onset falls before the chunk start are dropped; chunks
with fewer than 3 notes are skipped; peaks above 0.99 are normalised down.

| dataset | how it was built | train | val | test |
|---|---|---|---|---|
| GuitarSet (CC BY 4.0), mono mic audio, JAMS `note_midi` rounded to MIDI | split by **player** | players 00-03: 320 chunks | 20 chunks from player 04 (the rest of player 04 unused) | **player 05: 80 chunks** |
| MAESTRO v3 (CC BY-NC-SA 4.0), streamed with `remotezip` (only the chosen files were downloaded) | MAESTRO's own split; one performance per composer+title; pieces ≤ 900 s; seed 0 | 35 "train" pieces, ≤ 6 chunks each: 206 | 5 other "train" pieces: 28 chunks | **12 "test" works, ≤ 4 chunks: 48** |
| SMD piano v2 (CC BY 3.0), real Disklavier recordings `wav_22050_mono` (not the bundled MIDI re-synthesis) | split by **work** (sha1 hash of e.g. `Chopin_Op028-03`, 25% test) | 438 chunks | (none) | **126 chunks**. Beethoven WoO 80 was removed from test because its work also appears in our MAESTRO train subset |

Caveat: stock Basic Pitch was trained on GuitarSet and MAESTRO, among other data, so its
scores there may be optimistic. **SMD is the only real set that is unseen by stock.**

**Validation set (identical from E2 on):** the synthetic `val` (60) + GuitarSet val (20)
+ MAESTRO val (28) = 108 clips, called the "mixed val". Stock scores 0.8039 on it.

### 1.3 Preprocessing and targets

`scripts/finetune-basic-pitch` serializes pairs with basic_pitch's own
`_to_transcription_tfex`, using the frame grid `ANNOTATION_HOP` = 256/22050 s (86.13 fps),
which matches upstream mirdata `to_sparse_index`:

- **Note target:** every frame from round(start) to round(end).
- **Onset target:** the single onset frame (`onsets_only`).
- **Contour target:** the nearest of the 264 bins (3 per semitone) for the note pitch.
- **Windows:** 43,844 samples. Training draws 8 random windows per track per pass, fresh each epoch. Validation uses fixed windows. (The original script had these two reversed.)
- **Alignment check:** shifting the predictions by -46 to +46 ms against the labels peaks at 0 to +12 ms on all sets (synthetic is about half a frame late because of the FluidSynth attack). The labels are not misaligned.

### 1.4 Augmentation (`--augment`, on by default, training windows only)

Implemented in TF ops inside `tf.data`:

- **EQ** (p=0.6): spectral tilt of ±3 dB/oct plus one bell of ±9 dB, 0.7-3 octaves wide.
- **Synthetic room reverb** (p=0.35): exponentially decaying noise IR, RT60 0.15-1.0 s, wet 0.1-0.6.
- **Coloured noise** (p=0.5): white to pink at 10-40 dB SNR.
- **Gain** -18 to +3 dB, then clipping to [-1, 1].

Labels are unchanged.

### 1.5 Model and what was trained

- **Start point:** `models.model()` with the ICASSP 2022 weights loaded by `set_weights`. Outputs match the frozen SavedModel to about 5e-7.
- **What trains:** all conv layers (16,782 trainable params). The CQT and harmonic-stacking front end are fixed ops.
- **BatchNorm** is frozen in inference mode (`--freeze-bn`, default) so batches of 8 do not drag the moving statistics.
- **E1 only:** used the original 2-stage schedule with BN training. Its "harmonic stacking freeze" turned out to be a no-op.

### 1.6 Losses

`basic_pitch.models.loss`: BCE with label smoothing 0.2 on contour and note. The onset
head was trained one of two ways:

- **plain:** BCE over all cells. Onset positives are about 0.1% of cells, so this behaves like a positive weight of about 0.001.
- **weighted:** class-balanced, `(1-p)·mean BCE(negatives) + p·mean BCE(positives)`. Values tried: p = 0.95, 0.3, 0.1, 0.03, 0.01.

**This was the key knob.** Plain BCE collapses the onset head: peak onset posterior fell
from about 0.97 (stock) to 0.52, so recall falls. p = 0.95 floods onsets (precision
0.19-0.30). Only p ≈ 0.01-0.03 preserves calibration.

### 1.7 Optimisation and early stopping

- **Optimizer:** Adam, linear warmup over 200 steps, then cosine decay to 5% of peak.
- **Peak LR:** 1e-4 (E2) or 3e-5 (E4 onward).
- **Batch** 8, **300 steps per epoch** (about 75-80 s on 8 CPU cores).
- **Max epochs:** 8 (E2/E4/E6), 1 (probes), 2 (E7/E8).
- **Early stopping:** after each epoch, the SavedModel is scored on the mixed val (onset F1) in a subprocess (about 3-4 min). Patience is 3, and the baseline is the **stock score**, so a run that never beats stock keeps stock. The best weights are saved as `.h5` and restored at the end. (The original script never restored them, because it checked for a TF-checkpoint path that did not exist.)
- **Wall time:** about 45 min for an 8-epoch run including final tests; about 8 min for a 1-epoch probe.

### 1.8 Metrics

- **Score:** mir_eval `precision_recall_f1_overlap`, **onset tolerance 50 ms, offsets ignored** (`offset_ratio=None`), averaged per clip. F1 with offsets (20% / 50 ms) is also logged.
- **Notes** come from basic_pitch's own decoder `note_creation.model_output_to_notes` (infer_onsets, melodia trick, energy tolerance 11), run on `inference.run_inference` outputs, so the windowing is identical to the app's `Transcriber`.

### 1.9 Decoder tuning (E0t, E0t2)

- **Method:** cache model outputs once, then grid onset {0.3, 0.4, 0.5, 0.6, 0.7, 0.8} x frame {0.2, 0.3, 0.4, 0.5} x min note length {5, 7, 11 frames}. Pick the best mean F1 on the **mixed val only**, then apply it unchanged to the tests.
- **E0t:** the first grid without min note length, giving onset 0.7 / frame 0.3.
- **E0t2:** the full grid, giving **0.7 / 0.4 / 5**.
- **Fine-tunes** get their own tuned settings the same way, so comparisons are tuned-vs-tuned.
- **Tools:** `scripts/finetune-basic-pitch --eval-only --tune-thresholds` does this for one dir. `tools/finetune-eval/compare_models.py --model name=PATH ... --val ... --test ...` does it for several models (tune on the union of `--val`, report every `--test` at defaults and at tuned settings).

### 1.10 Conversion and verification (`tools/model-export/export-model.sh`)

- **TF.js:** `convert_tf_saved_model(signature_def='serving_default', strip_debug_ops=True)` (strips an Assert op). Stock round trip: same op set and the same 742,392-byte bin as `@spotify/basic-pitch@1.0.1`. Fine-tuned signatures map contour/note/onset to `Identity`/`Identity_1`/`Identity_2` exactly as stock.
- **Core ML (on Linux):** `ct.convert(..., convert_to="mlprogram", inputs=[TensorType(shape=(1,43844,1))], compute_precision=FLOAT32, minimum_deployment_target=iOS16)`. Fine-tuned graphs name the input `input_1`, so the export renames it to `input_2` (the name the app feeds) and asserts the output names and shapes. The stock `weight.bin` comes out the same size as Spotify's (145,956 B). Bit-level parity needs a Mac, because Core ML cannot predict on Linux; IOS_MODEL_HANDOFF.md section 8 has the check.
- **Release:** zips + `SHA256SUMS` + `models.lock.snippet` are published as GitHub release assets (`model-ft-expN`, `model-latest`).
- **Web demo:** `tools/web-demo/test.mjs` (file decode on wasm/webgl) and `test-live.mjs` (fake-mic streaming).

## 2. Experiments

Onset F1 on held-out sets at Spotify defaults, with each model's own tuned decoder after the slash where measured.

| exp | change | mixed val | GuitarSet p05 | MAESTRO test | SMD test | gugs | FluidR3 | why it failed / note |
|---|---|---|---|---|---|---|---|---|
| E0 | stock, defaults 0.5 / 0.3 / 11 | 0.804 | 0.802 | 0.695 | 0.703 | 0.861 | 0.901 | baseline |
| **E0t2** | **stock, tuned 0.7 / 0.4 / 5** | (tuning set) | **0.843** | **0.735** | **0.762** | 0.887 | **0.921** | **shipped** |
| E1 | original script: 2-stage, weighted onset p 0.95, BN training, 400 GUGS piano | synth val 0.670 (stock 0.879) | | | | | | onset flood (P 0.60), BN drift, best epoch never restored |
| E2 | fixed trainer, plain BCE, lr 1e-4, 400 GUGS piano | 0.673 | | | | | | onset head collapse; synthetic-only training also hurt real piano (MAESTRO val 0.70 to 0.52) while synth val rose to 0.916 tuned. **Synthetic gains don't transfer** |
| E4 | + all data (1,550 synth + 964 real chunks), lr 3e-5, plain BCE | 0.760, 0.721 | | | | | | onset head collapse (peak 0.79) |
| E4b | all data, onset p 0.95 | 0.384 | | | | | | onset flood (P 0.19-0.30) |
| E5 | probes, 1 epoch: p 0.3 / 0.1 / 0.03 | 0.601 / 0.747 / **0.813** | 0.794 / 0.836 | 0.701 / 0.707 | 0.728 / 0.753 | 0.881 / 0.903 | 0.873 / 0.917 | p 0.03 is the first to beat stock on val; tuned, it still loses to tuned stock on every real set |
| E6 | p 0.03, 8-epoch schedule | 0.805 (ep1), then falling | 0.785 / 0.832 | 0.703 / 0.720 | 0.727 / 0.761 | 0.874 / 0.904 | 0.857 / 0.909 | more steps = more drift. The default-decoder gains on SMD/MAESTRO disappear against tuned stock |
| E7 | p 0.01, 2-epoch schedule | 0.817 / 0.840 | 0.797 / 0.828 | 0.685 / 0.697 | 0.728 / 0.747 | 0.898 / 0.902 | 0.885 / 0.912 | best val, yet still below tuned stock on real audio |
| E8 | real data only, p 0.01, 2 epochs | 0.806, 0.807 | | | | | | stopped before tests (training concluded) |

**Lessons:**

1. Decoder tuning alone (+0.04 to +0.06 on real sets) beat every fine-tune.
2. Fine-tunes improved the default-decoder numbers mostly by shifting the precision/recall balance, which the decoder can do for free.
3. Onset-loss weighting is the knob everything else depends on.
4. Stock is already trained on GuitarSet and MAESTRO, so a few hundred chunks add little and invite forgetting.
5. Synthetic renders improve synthetic tests only.

## 3. Shipping config and how to reproduce

- **Weights:** stock ICASSP 2022 (iOS already pins Spotify's `nmp.mlpackage` in `models.lock`; web pins `@spotify/basic-pitch@1.0.1`).
- **Decoder:** onset **0.7**, frame **0.4**, min note **5 frames (58 ms)**. These are the defaults in the web demo (`web/app.js` / `index.html`) and in the `decoder-thresholds.json` sidecar of `model-latest`. iOS adoption is on the `agent/ios-thresholds` ticket (main's `BasicPitchDecoder` still uses Spotify's 0.5 / 0.3 / 11).
- **Release:** [`model-latest`](https://github.com/yishengjiang99/earsheet/releases/tag/model-latest), with `decoder-thresholds.json` and checksums.

Reproduce the numbers:

```sh
uv venv -p 3.11 .venv && . .venv/bin/activate
uv pip install 'basic-pitch[tf]==0.4.0' sox 'setuptools<81' remotezip soundfile
sudo apt install fluidsynth ffmpeg
# synthetic
P=tools/poly-render-py/poly_render.py; G=models/GeneralUser-GS.sf2   # scripts/fetch-models
python3 $P --soundfont $G --out data/val --generate 60 --seed 1007
python3 $P --soundfont $G --out data/test-gugs --generate 60 --seed 2007
python3 $P --soundfont /usr/share/sounds/sf2/FluidR3_GM.sf2 --out data/test-fluidr3 --generate 60 --seed 3007
# real (download GuitarSet annotation + audio_mono-mic zips from Zenodo 3371780, SMD from 13753319)
tools/real-data/prepare_real.py guitarset --src guitarset --out data/real
tools/real-data/prepare_real.py smd --src smd --out data/real          # then drop smd_Beethoven_WoO080_* from smd-test
tools/real-data/prepare_real.py maestro --src https://storage.googleapis.com/magentadata/datasets/maestro/v3.0.0/maestro-v3.0.0.zip --out data/real
#   val: move ~1/4 of player-04 GuitarSet chunks to guitarset-val (drop the rest of 04), every 8th MAESTRO train piece to maestro-val
# tuned-stock numbers
tools/finetune-eval/compare_models.py --model stock=$(python -c 'from basic_pitch import ICASSP_2022_MODEL_PATH as p;print(p)') \
  --val data/val data/real/guitarset-val data/real/maestro-val \
  --test data/test-gugs data/test-fluidr3 data/real/guitarset-test data/real/maestro-test data/real/smd-test --out compare.json
# a fine-tune (E7 settings)
scripts/finetune-basic-pitch --pairs <train dirs> --val <3 val dirs> --test <test dirs> \
  --lr 3e-5 --onset-loss weighted --positive-weight 0.01 --steps-per-epoch 300 --max-epochs 2
```

## 4. Better strategies, ranked by expected gain vs cost

Grounded in what we saw: the decoder and onset calibration dominate. Synthetic and
small real-data fine-tunes don't transfer. The real target, phone-mic audio in a room,
was never measured.

| rank | strategy | expected gain | cost | why |
|---|---|---|---|---|
| 1 | **Evaluate on iPhone-mic captures** (30-60 clips: play MAESTRO/SMD/GuitarSet test pieces or MIDI on a piano/speaker, record with the app, align by cross-correlation) | unblocks every decision; the script's `--mic-gate` ship rule needs ≥ 30 clips | 1-2 days, no GPU | today's tests are clean studio audio; the product hears phones in rooms |
| 2 | **Learned / per-condition decoder settings** (tune onset / frame / min-note on the mic set; optionally per-pitch-range onset thresholds, or a tiny logistic calibrator on onset peaks) | +0.02 to +0.05 more on mic audio (decoder tuning already gave +0.04-0.06) | hours, CPU | cheapest proven lever |
| 3 | **Real-recording-heavy training with phone-mic + room augmentation**: measured iPhone mic impulse responses / EQ, real RIRs (e.g. MIT IR survey, OpenAIR), phone AGC/compression and noise-suppression simulation, background noise from real rooms; no synthetic renders | the main way to beat stock *on mic audio*; on clean sets expect ≈ 0 | 1 day data + GPU runs | our augmentation was synthetic IRs/noise only, and stock never saw phone-mic conditions |
| 4 | **Low LR + L2-SP / EWC penalty toward stock weights**, pos weight 0.01-0.03, 1-2 epochs | removes the drift that sank E6/E7 (val peaked at epoch 1, then fell); keeps GuitarSet/MAESTRO from regressing | small code change (one penalty term), CPU-feasible | every run degraded with more steps |
| 5 | **Freeze early layers, tune only the heads** (onset head `conv2d_5` + note head `conv2d_3`/`conv2d_4`, about 7k params) | similar to 4; safer calibration | trivial | the front end is generic; the errors are in calibration and onset decisions |
| 6 | **Pseudo-labels on unlabeled real phone audio** (teacher = tuned stock or a big model, keep high-confidence notes) | medium; scales data cheaply | moderate (filtering heuristics) | labelled phone audio is the scarce resource |
| 7 | **Distillation from a larger teacher** (MT3, Onsets-and-Frames / hFT-Transformer for piano) on real + phone audio; soft targets on note/onset | medium-high on piano, especially MAESTRO/SMD-like audio where stock is weakest (0.73-0.76) | needs GPU for teacher inference (MT3 is about 0.5-1 s per 10 s clip on a T4) | soft targets also fix the onset-calibration problem we hit with hard single-frame labels |
| 8 | **Small per-instrument heads** (shared trunk, piano / guitar / other onset+note heads selected in the app UI) | medium for the selected instrument | 3 heads x about 7k params, so still tiny; app UI + export work | instrument-specific calibration without a single compromise |

**GPU cost estimate:** the model is 17k params, so compute is dominated by the CQT front
end and I/O.

- On a single T4 / L4 (about $0.35-0.80/h on-demand), one epoch over about 20k windows takes about 1-2 min, versus about 5 min on our 8-core CPU (plus 3-4 min of eval).
- A full sweep (5 configs x 3 seeds x 5 epochs, with per-epoch eval) is about 3-5 GPU-hours, roughly $2-4.
- MT3 teacher labelling of 50 h of audio is about 5-10 T4-hours, roughly $5-8.
- Per-seed repeats matter: E5-E7 differences on val were around 0.01, close to seed noise.

## 5. Next plan (2-3 runs)

**Run A (mic eval set, no training).**
- Record 40 clips on an iPhone with the app (20 piano: SMD/MAESTRO test MIDI played on a Disklavier or speaker; 10 guitar; 10 mixed) and align them to reference MIDI.
- Evaluate stock at defaults and at 0.7 / 0.4 / 5, then re-tune on half of the clips and test on the other half.
- *Success:* tuned stock ≥ defaults + 0.03 on the mic test half. This becomes the ship gate (`--mic-gate`).

**Run B (conservative fine-tune for mic audio).**
- Settings: heads-only (rank 5) + L2-SP (λ ≈ 1e-3) + pos weight 0.01-0.02, lr 1e-5, 2 epochs, 3 seeds.
- Data: real GuitarSet/MAESTRO/SMD train + phone-mic augmentation (rank 3).
- Selection: on mixed val + mic val, then compare tuned-vs-tuned.
- *Success:* beats tuned stock by ≥ 0.02 on the mic test half and on SMD, regresses ≤ 0.01 on GuitarSet/MAESTRO/FluidR3, and the gap holds on all 3 seeds. Only then ship it as the web demo's "Fine-tuned" option and a new `model-latest`.

**Run C (distillation, only if B wins or stalls).**
- MT3 / Onsets-and-Frames soft labels on real + unlabeled phone audio; same student, same gates as B.
- *Success:* +0.03 on piano mic audio over tuned stock.

## 6. Refined goal: velocity, loudness, note-off, MIDI record/playback (2026-10-03)

User-refined goal: ship a refined model based on stock Basic Pitch that detects
polyphonic music from audio — pitch, velocity, loudness, note-on and note-off —
encoded into a MIDI file for record and playback. The October effort (§§1-5) optimized
onset pitch F1 with offsets ignored and never measured velocity; this section records
what the app already does, where the gap is, and how the strategy changes.

### 6.1 What the app already does (audit of main, 2026-10-03)

The velocity chain is complete and preserving end to end; nothing normalizes it:

| stage | file | behavior |
|---|---|---|
| decode | `Packages/HearSheet/Sources/HearSheet/BasicPitchDecoder.swift` | per-note `amplitude` = mean note-posterior over the note's frames |
| transcribe | `Transcriber.swift` / `StreamingTranscriber.swift` | `velocity = clamp(1..127, round(127 * amplitude))` |
| quantize | `Quantize.swift` | velocity preserved into `QuantizedNote` |
| MIDI write | `SMFWriter.swift` | note-on `0x90` carries per-note velocity; note-off `0x80` vel 0; conductor track + program change; shared by playback and export via `MIDISupport.data(for:)` in `TakeLibrary.swift` |
| playback | `TakeLibrary.swift` → `SF2MIDIPlayer` → `Sf2SynthEngine.pickRegions` | SF2 regions filtered by velocity range; velocity drives voice gain — dynamics are audible |
| web demo | `web/app.js` | velocity = amplitude (0..1); playback gain `0.15 + 0.5*v`; Tone.js note velocity clamped |

### 6.2 The gap

The velocity *estimate* is uncalibrated: `amplitude` is the mean note-posterior (model
confidence), not audio energy. A quiet-but-clear note scores posterior ~0.95 →
velocity ~121; a loud-but-noisy note can score lower. Dynamics in the MIDI file and in
playback therefore track confidence, not loudness. Offsets were never measured (the
§1.8 metric ignores them) and there is no velocity metric at all.

### 6.3 Loudness scoping

In MIDI, per-note loudness *is* velocity. Continuous loudness inside a note (a swell
on a sustained tone) is CC7/CC11, not velocity — relevant only for sustained
instruments (strings, winds, organ). Piano/guitar notes cannot get louder after the
attack, so velocity covers them fully. Decision: ship velocity first; CC11 expression
curves are a later ticket, only if sustained instruments are in scope.

### 6.4 Strategy changes vs §4

- **Scorecard first:** onset F1 (50 ms) + offset-aware F1 + velocity MAE on matched
  notes + dynamics correlation (playback loudness contour vs recording). Without this,
  runs optimize pitch and silently regress the rest.
- **Velocity via calibrated energy mapping (no model change):** replace
  `127 * posterior-mean` with a curve fit on MAESTRO/SMD true velocities, using
  per-note audio energy (RMS over the note's frames). This is the velocity analog of
  the §2 lesson 1 (decoder tuning beat every fine-tune).
- **Calibrate relative, per performance:** phone AGC/compression destroys absolute
  level, so normalize to each recording's dynamic range instead of fitting an
  absolute dB→velocity map.
- **Velocity is greenfield for stock:** the §2 lesson 4 ("a few hundred real chunks
  add little and invite forgetting") was about pitch/onset, where stock was already
  trained on GuitarSet/MAESTRO. Stock knows nothing about velocity — real velocity
  labels are pure gain with no forgetting risk. Synthetic FluidSynth renders (exact
  velocity labels) become useful again for pre-training.
- **Distillation moves up:** MT3 emits velocity and has good note-offs; one
  distillation run teaches both missing pieces, with soft targets that also fix the
  onset-calibration problem from §1.6. Ranked just behind the mic-eval set now.
- **Mic-eval set is more urgent:** phone processing distorts amplitude, which is
  exactly what velocity reads. Run A clips should include known-velocity performances
  (MAESTRO MIDI through a speaker, or Disklavier) so velocity has ground truth too.

### 6.5 Shipping sequence

1. Tuned decoder thresholds on iOS (`agent/ios-thresholds` ticket — already
   validated, reads `decoder-thresholds.json` from release `model-latest`).
2. Velocity via calibrated energy mapping, wired through the existing MIDI writer;
   no weight changes.
3. Audible-dynamics check on device: transcribe something with obvious dynamics,
   confirm playback reproduces them.
4. Only then: new heads or MT3 distillation — ship weights only if they beat tuned
   stock on the mic set under the §6.4 scorecard.
