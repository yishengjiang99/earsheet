# SF2Player

SoundFont 2 playback for MIDI `Data`: SF2 parser, voice synth, SMF reader (formats 0/1, tempo map),
sample-accurate scheduler and an `AVAudioEngine` player. Swift port of
[yishengjiang99/gbk](https://github.com/yishengjiang99/gbk) @ `b43f004`. Licensed AGPL-3.0-or-later like the rest of the app (see `LICENSE`).

```swift
import SF2Player

let player = SF2MIDIPlayer()
try await player.load(soundFont: sf2URL)   // parsed off the main actor
try player.load(midi: midiData)
player.play()                               // pause(), stop(), seek(to:), tempoScale (0.25–4)
// @Published: position (seconds + tick), isPlaying, duration, activeNoteIDs
// player.onFinished = { ... }                 // end of song (auto-advance a playlist)
// player.meter.update(now:) -> SF2MeterLevels // live output level, poll at ~30 Hz
```

Level meter: `SF2RealtimeCore.render` adds each callback's peak and Σx² to a lock-free accumulator
(C atomics: CAS max on float bits, CAS add on double bits, exchange-to-zero on read), so nothing
between two UI polls is lost and the audio thread never blocks. `SF2MeterBallistics` gives the
displayed levels: RMS bar with instant attack and 40 dB/s fall, peak marker held 1 s then 24 dB/s
fall, −60 dBFS floor. The math lives in `SF2LevelMath` / `SF2MeterBallistics` (unit-tested).

Offline render (the gbk export path): `SF2OfflineRenderer.render(midi:soundFont:)`.

## Layout

| File | gbk source |
|---|---|
| `SF2SoundFont.swift`, `SF2Region.swift` | `sf2-parser.ts` |
| `SynthPrimitives.swift`, `Sf2SynthEngine.swift`, `SF2RegionStore.swift` | `src/sf2-renderer.ts` |
| `SMFReader.swift` | `parseMidiBuffer` |
| `SF2Sequence.swift` | `midireader.tsx` `onExportWav` (UI defaults) |
| `SF2RealtimeCore.swift` | `src/midi-timer.worker.ts` + render worklet; lock-free, no allocation on the render thread |
| `SF2LevelMeter.swift` | (new) lock-free output level meter + ballistics |
| `SF2MIDIPlayer.swift` | AVAudioEngine + AVAudioSourceNode, session/interruption/route handling |

## Faithful to gbk, including its gaps

No pitch bend, no drum-channel special-casing (channel 10 uses CC0/CC32 bank like any other), the
file's CC7/10/11 are not applied (track defaults 100/64/127), SF2 modulators parsed but not applied,
no filter Q, LFO frequency `2^(cents/1200)` Hz, per-region peak-normalized samples. Not ported:
gbk export's master dynamics stage. Seeking does not retrigger notes held across the seek point.

## Tests

`swift test --package-path Packages/SF2Player` (Linux or macOS). Needs `models/GeneralUser-GS.sf2`
(`scripts/fetch-models`) or `SF2PLAYER_SF2=/path/to.sf2`; SF2-dependent tests skip otherwise.

Parity fixtures in `fixtures/sf2/` come from gbk's own TypeScript renderer:

```sh
cd scripts/sf2-parity && npm ci && node render-gbk.mjs --gbk /path/to/gbk --sf2 ../../models/GeneralUser-GS.sf2
```

Current result: `c_scale.mid` and `sweden.midi` render bit-identical PCM to gbk (SHA-256 match).
