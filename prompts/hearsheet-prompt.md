# Agent prompt: build EarSheet

Build the listen-to-sheet app in this repo. Do not rename it, do not add a second synth, do not block the app on training.

## Locked

Repo: https://github.com/yishengjiang99/earsheet (private).
Sibling synth: https://github.com/yishengjiang99/omr-sheet-cam `Packages/SF2Player`. Vendor that package. Do not port another SoundFont engine.

- App Store name: AI Music Radar (ASC app 6818838017, SKU SI-music-radar)
- Home screen: AI Music Radar
- Bundle id: com.ragnus.pnge
- Team: 83D36RPMUM
- Scheme / project: EarSheet, EarSheet.xcodeproj
- iOS 17+. License AGPL-3.0-or-later. Basic Pitch is Apache-2.0. Update NOTICE.
- Identity file: docs/asc/APP_IDENTITY.md. Do not edit the names.

Already on main, keep and extend:
- Sources/App/EarSheetApp.swift
- Tests/EarSheetTests/SmokeTests.swift (ios-sim.yml runs EarSheetTests/SmokeTests; do not delete it)
- Packages/HearSheet (library + HearSheetTests)
- scripts/fetch-models, models.lock
- .github/workflows, same names and secrets as SheetCam
- tools/poly-render is a stub. Fill it in phase B only.

## Product

Mic or imported audio stays on the phone, becomes an engraved page, SMF MIDI, and MusicXML, then plays through SF2MIDIPlayer. Airplane mode still transcribes. No account, no upload, no server fallback.

Ship phase A on the released ICASSP 2022 Basic Pitch Core ML weights. Phase B may replace the weights. The app code must not care which checkpoint is loaded.

## Do not

- Change the Basic Pitch graph. Heads stay note [time, 88], onset [time, 88], contour [time, 264].
- Train from scratch. Do not swap in MT3, YourMT3, Onsets and Frames, or MuScriptor.
- Hand-roll note creation. Port Spotify's onset / frame / minimum-length / contour decoder. Defaults are Spotify's. The four thresholds are debug-only.
- Invent a player. Use SF2MIDIPlayer.load(soundFont:), load(midi:), play(), activeNoteIDs.
- Pretend SF2 modulators work. Program change, velocity, overlap, and pitch bend only if the sequence player honors bend. Channel 10 is not drums.
- Commit .mlpackage, .onnx, or .sf2. Pin fetches in models.lock. scripts/fetch-models must stay idempotent.
- Break ios-sim.yml. SmokeTests still pass. New tests are additive.

## Phase A — app, stock model

1. Vendor Packages/SF2Player from omr-sheet-cam at a pinned commit. Link it from the app target and from HearSheet if needed. ios-sim.yml already skips the package test when the directory is missing; after vendor, that step must run.
2. Fetch the published Basic Pitch Core ML package (BasicPitch_nmp contract) via scripts/fetch-models. Record sha256 in models.lock.
   - Input waveform [1, 43844, 1] at 22050 Hz mono.
   - Outputs note [1, 172, 88], onset [1, 172, 88], contour [1, 172, 264].
3. Packages/HearSheet owns capture, inference, decode, quantize, MusicXML, engraving. The app target only shows UI and calls the package.
   - AVAudioEngine tap, 22050 Hz mono float. Import m4a / wav / aac through AVAudioFile.
   - Sliding 43844-sample window, hop matched to the Basic Pitch iOS postprocess. Overlap-add posteriorgrams, then decode once.
   - Core ML computeUnits .all, persistent compiled cache.
   - Gate A0–C8.
   - Meter from onset IOIs: prefer 4/4, allow 3/4 and 6/8. Key from pitch-class histogram, major or minor. Snap to a 16th grid. Simultaneous notes share a stem.
   - SMF format 1, 480 TPQ.
   - MusicXML 4.0, partwise, one part. Treble, or grand staff when the range crosses middle C by more than an octave and the chord needs two staves.
   - Engrave on device. Staff is the product. Piano roll is the second view. Beams, barline ties, chord stacking, accidentals from the estimated key. Playhead highlight from activeNoteIDs.
4. UI. One screen, not a lab.
   - Record, elapsed time, stop. Then "Writing the page". Budget 10 seconds for a one-minute take on iPhone 13 class.
   - Page, play, share. Share sheet: MIDI, MusicXML, PDF of the engraved page.
   - Denied mic, empty take, too-quiet: one sentence each. Too-quiet offers import.
   - Dynamic Type. VoiceOver on record, play, share.
   - Mic copy already in the target: the recording stays on the device.
5. Tests.
   - Keep SmokeTests.
   - HearSheetTests: a known posterior fixture decodes to a C major triad; MusicXML from that triad opens as three chord tones; SMF tick times match the sidecar.
   - Simulator: import a bundled wav of that triad, show the staff, export MIDI.

Phase A is done when import transcription works on the simulator, mic transcription works on a device, playback uses SF2MIDIPlayer, and ios-sim.yml is green. Do not wait on phase B.

## Phase B — fine-tune, then swap weights

Only after phase A is green.

tools/poly-render is a macOS tool linking SF2Player. Offline bounce is SF2OfflineRenderer.render(midi:soundFont:). Inspect the signature. SoundFont: GeneralUser GS or another font whose license allows rendered wavs and forbids committing the sf2. Write tools/poly-render/FONT.md. Fail if the font file is missing.

Each clip: SMF format 1, 480 TPQ, tempo map, 4/4 and 3/4, 60–140 BPM, 8–20 seconds. One to three melodic programs (piano, guitar, strings, flute, choir, organ, mallet). Skip silent presets. At least 30% of sounding frames have two or more notes. Pitches inside A0–C8. Velocities 40–110. Pitch bend at most ±2 semitones, or a flat contour label if the renderer ignores bend.

Bounce, record the renderer rate, resample to basic_pitch AUDIO_SAMPLE_RATE and AUDIO_N_CHANNELS (22050 Hz stereo). Save wav, mid, json (programs, tempo, meter, onset, offset, midi, velocity, channel, bend).

8,000 train / 1,000 val / 500 test. Stratify by program family and polyphony. No shared seed across splits.

Augment audio only: ±6 dB, one room IR, noise at 20–35 dB SNR, phone-mic EQ (high-pass near 80 Hz). Optional ±20 cent detune on a minority, and shift contour labels by the same amount. Do not flip semitone identity.

Real gate, never trained on: at least 30 phone-mic clips (piano, guitar, hummed chords, speaker playing a bounce), clap-aligned.

Serialize with basic_pitch.data.tf_example_serialization.to_transcription_tfexample. Source tag synthetic_sf2.

Fine-tune https://github.com/spotify/basic-pitch v0.4.0. Init from ICASSP 2022. models.loss(label_smoothing=0.2, weighted=True), onset positive weight 0.95. Freeze harmonic stacking for 2 epochs, then unfreeze. Adam 1e-4, then 1e-5. Early stop on val note-event F1, patience 8, cap 40 epochs. Do not change kernels, bins, or hop.

Eval with inference.predict and mir_eval, 50 ms onset tolerance. Note F1, onset F1, offset F1, split by polyphony 1 / 2 / 3+ and by program family. Same table for the frozen checkpoint and for the 30 real clips. Write both to artifacts/metrics.json.

Ship the fine-tune only if synthetic val note F1 is at least the original and real-mic note F1 is not more than 2 points worse. Otherwise keep the ICASSP weights and say so in the PR.

Export Core ML under the same input and output contract. Fail if decoded notes differ from TensorFlow on 5 clips. fp16 if notes match, else fp32. Name BasicPitchPoly.mlpackage. Pin sha256 in models.lock. App load path stays the one from phase A.

## Done

- Phase A green on simulator import and device mic.
- A 10-second piano triad becomes a staff with those chord tones, plays through SF2MIDIPlayer, and exports MIDI and MusicXML a desktop editor can open.
- ios-sim.yml green, SmokeTests intact.
- Phase B either swaps BasicPitchPoly under the ship rule, or documents why the stock weights stayed.
- NOTICE names Apache-2.0 Basic Pitch and the SoundFont license used for training audio.
