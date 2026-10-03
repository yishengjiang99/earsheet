# SF2Player (app-side glue) + shared SF2Engine

- SoundFont 2 parser + synth (SF2Engine): the shared package
  https://github.com/yishengjiang99/sf2player-swift, pinned by exact revision in `Package.swift`
  (53b45034270f50936dc83565e62e89e568abffb3, 2026-10-03). omr-sheet-cam pins the same module.
  Do not copy engine sources here; bump the revision instead.
- Sequencing / real-time player glue (SMFReader, SF2SequenceBuilder, SF2RealtimeCore, SF2MIDIPlayer,
  level meter): vendored from https://github.com/yishengjiang99/omr-sheet-cam `Packages/SF2Player` at
  66a866d (2026-10-03). Earsheet-specific changes may be made here.
- License: AGPL-3.0-or-later (see `LICENSE`).
