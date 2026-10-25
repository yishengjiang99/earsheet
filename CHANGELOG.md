# Changelog

## 2026-10-25: sf2player-swift 6ce4941

Bumped the SF2Engine pin in `Packages/SF2Player` from `f7d144c` to `6ce4941` (sync with the gbk JS engine).

Audible changes:
- Reverb sends are about 18 dB louder. The return now matches FluidSynth's default level (2.7, previously 0.35), and the reverb input is the mono send (L+R).
- CC66 is now sostenuto and CC67 is the soft pedal, per MIDI 1.0. The two were previously swapped.
- CC91 and CC93 now reach the reverb and chorus sends on SoundFont 2.04 fonts, whose default modulators have no send entries. This is controlled by `sendCcModulators` and is on by default.

New APIs (additive, so no app code changes are needed):
- `setEffectParams(SF2EffectsParams)`
- `sendCcModulators`
- `trackPan` and `trackFader` (a track stage after the master bus)
- `setVoiceOverrides` and `SF2VoiceOverride`
- `SF2LoudnessMeter` and `SF2LoudnessReport` (BS.1770)
- `SF2OfflineRenderer.renderSong(tailSeconds:normalize:)`

