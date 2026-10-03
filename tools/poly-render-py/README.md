# poly-render-py

Python/FluidSynth edition of the Phase-B paired-data generator.
Renders MIDI through FluidSynth and writes, per stem:

- `<stem>.wav` — 22050 Hz mono 16-bit PCM (what basic-pitch 0.4.0 requires)
- `<stem>.mid` — the MIDI that was rendered
- `<stem>.json` — sidecar: tempo, key, notes, generator seed

Same output format as `../poly-render` (Swift, which renders via the vendored
SF2Player's `SF2OfflineRenderer`). Timbre differs slightly (FluidSynth vs
`Sf2SynthEngine`); the note labels are what the fine-tune pipeline trains on.

## Requirements

- Python 3.9+, stdlib only (no pip packages)
- The `fluidsynth` binary on PATH:
  - macOS: `brew install fluid-synth`
  - Debian/Ubuntu: `sudo apt install fluidsynth`
- The SoundFont, fetched (never committed): `scripts/fetch-models`

## Usage

```sh
# seeded etudes (same generator as the Swift tool: splitmix64, 4 patterns)
tools/poly-render-py/poly_render.py \
  --soundfont models/GeneralUser-GS.sf2 \
  --out ~/earsheet-data/train \
  --generate 200 --seed 7 --seconds 12

# render existing MIDI files
tools/poly-render-py/poly_render.py \
  --soundfont models/GeneralUser-GS.sf2 \
  --out ~/earsheet-data/train \
  --midi a.mid b.mid
```

Then train exactly as in `prompts/finetune-bundle.md`:

```sh
scripts/finetune-basic-pitch \
  --pairs ~/earsheet-data/train \
  --val ~/earsheet-data/val \
  --mic-gate ~/earsheet-data/mic \
  --epochs 8 \
  --lr 1e-4
```

## Notes

- Etude generation mirrors the Swift tool (splitmix64 RNG, 16th-note grid,
  chord loops / scales / arpeggios / random-walk melody + bass, A0–C8 clamp),
  so datasets are comparable across implementations.
- MIDI is written as SMF format 0, 480 TPQ, with a 2 s tail so FluidSynth
  renders release/reverb decay.
- FluidSynth renders stereo; the script mixes down to mono and asserts the
  22050 Hz sample rate rather than resampling silently.
