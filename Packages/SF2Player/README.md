# SF2Player

SoundFont 2 playback for MIDI `Data`: SMF reader (formats 0/1, tempo map), sequencer, sample-accurate
scheduler and an `AVAudioEngine` player. The SF2 parser and voice synth are the shared **SF2Engine**
package ([yishengjiang99/sf2player-swift](https://github.com/yishengjiang99/sf2player-swift), pinned by
revision in `Package.swift`; the same module is used by the earsheet app), re-exported by `import SF2Player`. Swift port of
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
| SF2Engine (shared package): parser, regions, synth, modulators | `sf2-parser.ts`, `src/sf2-renderer.ts` |
| `Exports.swift` | re-exports SF2Engine |
| `SMFReader.swift` | `parseMidiBuffer` |
| `SF2Sequence.swift` | `midireader.tsx` `onExportWav` (UI defaults) |
| `SF2RealtimeCore.swift` | `src/midi-timer.worker.ts` + render worklet; lock-free, no allocation on the render thread |
| `SF2LevelMeter.swift` | (new) lock-free output level meter + ballistics |
| `SF2MIDIPlayer.swift` | AVAudioEngine + AVAudioSourceNode, session/interruption/route handling |

## Fidelity

`SF2MIDIPlayer.fidelity` (default `.spec`) picks the engine rules; plans carry it (`plan(fidelity:)`).

- `.spec`: SoundFont 2.04. Default + file modulators (instrument replaces identical, preset adds), zone
  override rules with preset key/velocity range intersection, filter cutoff modulation and Q, the file's
  CC1/7/10/11 and pitch bend (RPN 0 range, CC121) as live engine events, per-MIDI-channel presets with
  channel 10 on the bank-128 kit, triangle LFOs at 8.176 Hz x 2^(cents/1200), key-number envelope
  scaling, +6 dB makeup (`specMakeupGain`). Not handled: sustain pedal, reverb/chorus, aftertouch, NRPN,
  modulator links.
- `.gbk`: yishengjiang99/gbk's export, gaps included (no pitch bend, CC or modulators, no filter Q, no drum
  channel handling, preset ranges ignored so multi-split presets layer, sine LFOs at 2^(cents/1200) Hz).
  ParityTests use it and stay bit-identical.

## Tests

`swift test --package-path Packages/SF2Player` (Linux or macOS). Needs `models/GeneralUser-GS.sf2`
(`scripts/fetch-models`) or `SF2PLAYER_SF2=/path/to.sf2`; SF2-dependent tests skip otherwise.

Parity fixtures in `fixtures/sf2/` come from gbk's own TypeScript renderer:

```sh
cd scripts/sf2-parity && npm ci && node render-gbk.mjs --gbk /path/to/gbk --sf2 ../../models/GeneralUser-GS.sf2
```

Current result: `c_scale.mid` and `fixtures/samples/ode-to-joy.mid` render bit-identical PCM to gbk (SHA-256 match).
