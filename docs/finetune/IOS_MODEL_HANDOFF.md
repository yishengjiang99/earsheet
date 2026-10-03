# iOS handoff: embedding the (fine-tuned) Basic Pitch model

> **Shipping config (2026-10-03): stock ICASSP 2022 weights + tuned decoder thresholds.**
> The weights are the stock model the app already bundles through `models.lock`
> (Spotify's `nmp.mlpackage`), so nothing needs to be downloaded or re-pinned.
> The tuned decoder settings are **onset 0.7, frame 0.4, min note length 5 frames (58 ms)**
> (Spotify's defaults: 0.5 / 0.3 / 11). They ship as the thresholds sidecar
> **`decoder-thresholds.json`** in release
> [`model-latest`](https://github.com/yishengjiang99/earsheet/releases/tag/model-latest)
> (keys `onset_threshold`, `frame_threshold`, `min_note_len_frames`). The app reads them per model
> at load time: `models.lock` pins that asset as `models/BasicPitchPoly.thresholds.json`, next to
> the package (see §6a).
> Held-out onset F1 vs Spotify defaults: GuitarSet 0.843 vs 0.802, MAESTRO 0.735 vs 0.695,
> SMD 0.762 vs 0.703. No fine-tune beat this on real audio (EXPERIMENTS.md). The rest of
> this doc covers swapping in a different checkpoint later.

This doc covers getting a model built by `scripts/finetune-basic-pitch` (or the stock
model) into the EarSheet iOS app. Weights are **never committed**. They are published as
GitHub release assets and pinned by SHA-256 in `models.lock`.

- **Latest model:** release [`model-latest`](https://github.com/yishengjiang99/earsheet/releases/tag/model-latest). It is a moving release, and its notes say which `model-ft-expN` it equals.
- **Per-experiment releases:** `model-ft-exp0`, `model-ft-exp1`, and so on. Metrics and the changes behind each one are in [EXPERIMENTS.md](EXPERIMENTS.md).

## 1. What a release contains

| asset | what | use |
|---|---|---|
| `basic-pitch-<tag>-coreml.zip` | `BasicPitchPoly.mlpackage` (ML Program, fp32, iOS 16+), converted with coremltools 8.3 from the SavedModel | the iOS app |
| `basic-pitch-<tag>-savedmodel.zip` | TF SavedModel (`nmp/`), Keras 2 / TF 2.15 | re-conversion, Python eval (`basic_pitch.inference.Model`) |
| `basic-pitch-<tag>-tfjs.zip` | TF.js graph model (`model.json` + `group1-shard1of1.bin`) | the web demo |
| `SHA256SUMS` | sha256 of every zip | verification |
| `models.lock.snippet` | the `models.lock` line for the Core ML zip, plus the package-tree hash | pinning |

The release notes also list the TF.js file hashes, the Core ML package-tree hash, the
held-out metrics, and the **recommended decoder thresholds** for that model.

`model-ft-exp0` is the **stock** ICASSP 2022 model (Apache-2.0) exported through the same
pipeline. It is the reference build for parity checks. If a later model was trained
on MAESTRO, it carries MAESTRO's CC BY-NC-SA 4.0 terms (see [DATA.md](DATA.md)).

## 2. Download (the repo is private)

`curl` cannot fetch private release assets without auth, so download them with `gh`
and point `fetch-models` at the folder:

```sh
gh release download model-latest -R yishengjiang99/earsheet -D ~/Downloads/model-latest
(cd ~/Downloads/model-latest && shasum -a 256 -c SHA256SUMS)
```

## 3. Pin it: models.lock + scripts/fetch-models

In `models.lock`, replace the three stock `BasicPitchPoly.mlpackage/...` lines with the
single line from `models.lock.snippet`:

```
<sha256 of the coreml zip>  BasicPitchPoly.mlpackage  https://github.com/yishengjiang99/earsheet/releases/download/<tag>/basic-pitch-<tag>-coreml.zip
```

Then fetch:

```sh
MODELS_ASSET_DIR=~/Downloads/model-latest scripts/fetch-models
```

`fetch-models` takes the asset from `MODELS_ASSET_DIR` if a file with the URL's name is
there (otherwise it uses `curl`). It checks the zip's sha256 against the lock, extracts
`BasicPitchPoly.mlpackage/` into `models/`, and writes a stamp holding the
package-tree hash. A mismatch fails the run, and nothing half-written is left in
`models/`. Xcode's build phase runs the same script.

Alternative (local build): if you have a SavedModel instead of a release, convert it
yourself (section 4), then run `scripts/bundle-coreml path/to/BasicPitchPoly.mlpackage`.
That copies the package into `models/` and writes a `local BasicPitchPoly.mlpackage sha256:<tree hash>`
line, which `fetch-models` verifies but never downloads. Do not commit a `local` line
for a release build; commit the URL pin.

## 4. Converting a SavedModel to Core ML

`tools/model-export/export-model.sh <savedmodel> <tag> [metrics.json] [--publish] [--latest]`
does the whole job (SavedModel zip, TF.js, Core ML, checksums, release). The Core ML step
also works on Linux, because coremltools can convert there (it just can't run
predictions):

```python
import coremltools as ct, tensorflow as tf   # coremltools 8.3, tensorflow 2.15.1, numpy<2
m = tf.keras.models.load_model("nmp", compile=False)
ml = ct.convert(m, convert_to="mlprogram", source="tensorflow",
                inputs=[ct.TensorType(name="input_2", shape=(1, 43844, 1))],
                compute_precision=ct.precision.FLOAT32,
                minimum_deployment_target=ct.target.iOS16)
ml.save("BasicPitchPoly.mlpackage")
```

- **Precision:** keep fp32 unless parity (section 8) passes for fp16. On macOS, `scripts/finetune-basic-pitch` tries fp16 first and falls back to fp32 if its 5-clip note comparison fails.
- **Size:** the weights are tiny either way. Stock `weight.bin` is 145,956 bytes; the TF.js bin is 742 KB because it also stores the CQT kernels.
- **`.mlmodelc`:** do not ship a precompiled one. The app compiles the `.mlpackage` on first use and caches the result (section 7). If you need a compiled model for a test target, run `xcrun coremlcompiler compile BasicPitchPoly.mlpackage out/`.

## 5. Tensor contract (unchanged from stock)

| | name | shape | notes |
|---|---|---|---|
| input | `input_2` | [1, 43844, 1] float32 | mono waveform, **22,050 Hz**, raw samples in [-1, 1]. No normalisation (the CQT front end is inside the graph) |
| output | `Identity` | [1, 172, 264] | contour (pitch salience, 3 bins/semitone) |
| output | `Identity_1` | [1, 172, 88] | note (frame activation, MIDI 21-108) |
| output | `Identity_2` | [1, 172, 88] | onset |

There are 172 frames per window at 86.13 frames/s (hop 256 samples). `BasicPitchModel.resolveFeatureNames`
accepts `Identity*` and also `note`/`onset`/`contour`, so an export with renamed outputs
still loads.

## 6. Windowing, hop, decoder thresholds

Windowing is identical to Spotify's `basic_pitch.inference`, already ported in
`Packages/HearSheet/Sources/HearSheet/Transcriber.swift`:

- front pad 3,840 samples (`overlap_len / 2`)
- window 43,844, hop 36,164 (`AUDIO_N_SAMPLES - 30 * FFT_HOP`)
- strip 15 frames off each side of every window (142 kept), then trim to `int(L / hop * 142)` frames

The decoder is `BasicPitchDecoder.decode(frames:onset:contour:thresholds:)` (a port of
`note_creation.model_output_to_notes`: infer_onsets, melodia trick, min note length 11
frames, energy tolerance 11).

**Thresholds (shipping):** onset **0.7**, frame **0.4**, min note **5 frames**. They are published
in `decoder-thresholds.json` (release `model-latest`) and reach the app as the model's sidecar (§6a). They were tuned for the stock weights by grid search (onset 0.3-0.8 x frame 0.2-0.5 x
min note {5, 7, 11}) on the mixed validation set, then checked on the held-out tests:

| set | tuned 0.7 / 0.4 / 5 | Spotify 0.5 / 0.3 / 11 |
|---|---|---|
| GuitarSet player 05 (real) | 0.843 | 0.802 |
| MAESTRO test (real) | 0.735 | 0.695 |
| SMD test (real) | 0.762 | 0.703 |
| synthetic GUGS / FluidR3 | 0.887 / 0.921 | 0.861 / 0.901 |

A different checkpoint needs its own tuned values (they ship in each release's notes /
`metrics.json` / `decoder-thresholds.json`); they go in that model's sidecar (§6a).
The web demo uses the same values (min note 58 ms = 5 frames).

### 6a. Where thresholds live (per model)

- **File:** `<models>/<Package>.thresholds.json` next to the package, e.g. `models/BasicPitchPoly.thresholds.json`
  beside `BasicPitchPoly.mlpackage` (outside the package, so retuning never changes the compiled-model cache key).
  Format = the release's `decoder-thresholds.json`: `onset_threshold`, `frame_threshold`, optional
  `min_note_len_frames` (extra keys ignored).
- **Pinned in `models.lock`** like any model file (sha256 + release URL). `scripts/fetch-models` installs it,
  using `gh release download` for this private repo's release URLs (CI sets `GH_TOKEN`); the Xcode build
  phase bundles every `models.lock` name, so it ships inside `<App>.app/models/`.
- **Read at load time:** `BasicPitchModel(modelsDirectory:)` sets `model.thresholds` (and
  `thresholdsFromSidecar`); `Transcriber` and `StreamingTranscriber` decode with `model.thresholds`.
  There are no global threshold constants; `minNoteLenFrames` is part of the per-model value.
- **Missing or invalid sidecar:** documented Spotify defaults, `Thresholds.basicPitchDefaults`
  (onset 0.5, frame 0.3, min note 11 frames).
- **New fine-tuned release:** in `models.lock`, replace the three stock `BasicPitchPoly.mlpackage/*` lines with the
  release's Core ML zip line (`models.lock.snippet`) and replace the `BasicPitchPoly.thresholds.json` line with that
  release's `decoder-thresholds.json` (sha256 from `SHA256SUMS`). `models.release.lock` is a working example
  (model-latest zip + sidecar); CI fetches it into a separate folder and runs `ModelThresholdsTests` against it.
  Pin by sha256: `model-latest` moves, so a re-pointed release fails the hash check until the lock is updated.

## 7. Where it plugs in

- `Packages/HearSheet/Sources/HearSheet/BasicPitchModel.swift`: `BasicPitchModel(modelsDirectory:)` loads `<models>/BasicPitchPoly.mlpackage`, compiles it once, and runs `predict(waveform:)` on one 43,844-sample window. No graph changes are needed: a fine-tuned checkpoint has the same contract.
- `ModelBox` shares one loaded model. It is used by `Sources/App/LibraryView.swift` (file import) and `Sources/App/ListeningView.swift` (live).
- `Sources/App/BundledModels.swift` `modelsDirectory()` decides where `models/` lives in the app bundle. The Xcode build phase copies `models/` after `scripts/fetch-models`.
- `Transcriber.transcribe(samples:model:)` does the windowing and decoding (section 6).

**Compiled-model cache key.** `persistentCompiledURL(for:)` names the cached `.mlmodelc`
`BasicPitchPoly-<key>.mlmodelc` in Application Support, where `<key>` is an FNV-1a hash
over **every file** in the package (relative path + bytes, sorted). That includes
`Data/com.apple.CoreML/weights/weight.bin`, not just `Manifest.json` / `model.mlmodel`.
This matters: a fine-tune changes only `weight.bin`, so a key over the manifest or
spec alone would keep loading the stale stock compile. Keep hashing the whole package
if you touch this code. The release's "package tree sha256" (same recipe as
`fetch-models`/`bundle-coreml`) identifies the package for humans; the app's FNV key is
its own, but it covers the same bytes.

## 8. Verifying parity

1. **Stock export vs upstream stock (Mac).** `model-ft-exp0` must match Spotify's `nmp.mlpackage`.
   - Its `weight.bin` is the same size (145,956 B), but the bytes differ (different converter version), so compare outputs, not hashes.
   - On a Mac run the existing app tests with each package in `models/` (e.g. `StreamingExportTests`), or in Python:

   ```python
   import coremltools as ct, numpy as np
   from basic_pitch import inference, ICASSP_2022_MODEL_PATH
   x = (np.random.randn(1, 43844, 1) * 0.1).astype(np.float32)
   a = ct.models.MLModel("BasicPitchPoly.mlpackage").predict({"input_2": x})
   b = inference.Model(ICASSP_2022_MODEL_PATH).predict(x)   # TF reference
   for k in ("Identity", "Identity_1", "Identity_2"):
       print(k, np.abs(a[k] - b[k]).max())                    # expect < 1e-3 (fp32)
   ```
2. **Fine-tuned Core ML vs its own SavedModel.** Run the same check with the release's `savedmodel.zip` as reference. Then compare notes on real audio: `scripts/finetune-basic-pitch` `export_coreml` already gates on a 5-clip TensorFlow-vs-Core ML note comparison (macOS).
3. **App level.** Transcribe the same file with stock and with the new model and compare note counts / F1 against a reference MIDI. The web demo's `tools/web-demo/test.mjs` fixtures (triad, twinkle, two-hands) are a quick sanity set. With the fine-tuned model the expected notes should still all be found.
4. **Cache.** After swapping packages, confirm that a new `BasicPitchPoly-<key>.mlmodelc` appears in Application Support (the key changed) and that the old one is not loaded.
