# poly-render

Phase-B paired-data generator (macOS only — runs on the MacBook, not in CI).
Links Packages/SF2Player from this repo (do not fork a second synth).

Renders MIDI through `SF2OfflineRenderer.render(midi:soundFont:)` at 22050 Hz,
mixes to mono 16-bit PCM, and writes per stem:

- `<stem>.wav` — 22050 Hz mono (what `basic-pitch` 0.4.0 requires; its
  serializer asserts 1 channel, so stereo is not an option)
- `<stem>.mid` — the MIDI that was rendered
- `<stem>.json` — sidecar: tempo, key, note list, generator seed

Usage (from the repo root; fetch the SoundFont first):

```
scripts/fetch-models
swift run --package-path tools/poly-render poly-render \
  --soundfont models/GeneralUser-GS.sf2 \
  --out ~/earsheet-data/train \
  --generate 200 --seed 7 --seconds 12
```

Or render existing MIDIs:

```
swift run --package-path tools/poly-render poly-render \
  --soundfont models/GeneralUser-GS.sf2 \
  --out ~/earsheet-data/val \
  --midi val/*.mid
```

The SoundFont is fetched, not committed. Generation is deterministic from
`--seed` (splitmix64), so a dataset can be reproduced exactly.
