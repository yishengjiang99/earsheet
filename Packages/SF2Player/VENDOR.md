# SF2Player (app-side glue) + shared SF2Engine

- SoundFont 2 parser + synth (SF2Engine): the shared package
  https://github.com/yishengjiang99/sf2player-swift, pinned by exact revision in `Package.swift`
  (f7d144c78b34b1a21770aa1eb747087d586f13d3 = sf2player-swift main after PRs #1 + #2, 2026-10-22: SoundFont 2.01, .gbk = .spec, track CC7/10/11 via channel state; parity refs from gbk main 4a3da6234c512634df153273adf362fe60ad4dd5). omr-sheet-cam pins the same module.
  Bumped 2026-10-25 to 6ce4941247d1dcd178da5c71b9279a9cf91fc007 (gbk sync: reverb/sends, CC66/67, overrides, track stage, loudness; see CHANGELOG.md).
  Do not copy engine sources here; bump the revision instead.
- Sequencing / real-time player glue (SMFReader, SF2SequenceBuilder, SF2RealtimeCore, SF2MIDIPlayer,
  level meter): vendored from https://github.com/yishengjiang99/omr-sheet-cam `Packages/SF2Player` at
  66a866d (2026-10-03). Earsheet-specific changes may be made here.
- License: AGPL-3.0-or-later (see `LICENSE`).
