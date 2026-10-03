# Agent prompt: Hear-to-sheet on EarSheet

You are implementing a consumer-ready listen app, plus the offline fine-tune that produces the Core ML weights it runs. Do not invent a second synth, a second MIDI stack, or a new app identity.

## Product

Repo: https://github.com/yishengjiang99/earsheet
Sibling synth and OMR reference: https://github.com/yishengjiang99/omr-sheet-cam (Packages/SF2Player). Link or vendor that package. Do not fork a second SoundFont engine.

App identity, locked:
- App Store name: EarSheet: Music to Sheet
- Home-screen name: EarSheet
- Bundle id: com.ragnus.earsheet
- Platform: native iOS/iPadOS 17+
- License: AGPL-3.0-or-later. Basic Pitch is Apache-2.0. Keep NOTICE accurate.

Microphone or imported audio to on-device transcription to engraved sheet music, MIDI, and SF2 playback.

The model is a fine-tune of Spotify Basic Pitch (ICASSP 2022 NMP), run as Core ML on device. No network at inference. No server fallback.

## Hard rules

- Do not change the Basic Pitch graph. Three heads stay: note [time, 88], onset [time, 88], contour [time, 264]. Harmonic stacking stays. The iOS decoder must match Spotify's note-event postprocess, not a hand-rolled threshold.
- Do not train from scratch. Initialize from the released ICASSP 2022 checkpoint.
- Do not swap in MT3, YourMT3, Onsets and Frames, or MuScriptor.
- Synthetic audio is necessary and not sufficient. SF2 renders supply labels. A small real recorded set is the acceptance gate. If real-mic note F1 is worse than the untuned checkpoint by more than 2 points, do not ship the fine-tune.
- SF2 synthesis for training data goes through Packages/SF2Player only. Offline entry point is SF2OfflineRenderer.render(midi:soundFont:). Inspect the current signature and use it. Do not port another SoundFont engine.
- The engine does not apply modulators. Do not pretend CC11 or CC1 changes timbre. Levers that actually work: MIDI program change, bank select as the parser implements it, velocity, note overlap, pitch bend if the sequence player honors it, and external audio augmentation after the bounce.
- Channel 10 is not a drum map. Do not generate drum kits and expect GM percussion.
- Training code does not ship in the app. The app ships only the Core ML package, the decoder, and the engraver.

## Part 1 — labeled polyphonic audio from SF2Player

Build a macOS command-line generator in tools/poly-render. It links the SF2Player package.

SoundFont: GeneralUser GS or another font whose license allows generating training audio and redistributing nothing but the rendered wavs. Do not commit a restricted SF2. Document the font name, version, and license in tools/poly-render/FONT.md. Fail the generator if the font file is missing.

For each example:
1. Write an SMF format 1, 480 TPQ, with a tempo map. 4/4 and 3/4 both appear. Tempos 60–140 BPM.
2. Pick 1–3 programs from the font's melodic presets (piano, guitar, strings, flute, choir, organ, mallet). Insert a program change before the first note on each channel. Skip presets that render as silence.
3. Compose 8–20 seconds of polyphonic music: single line, two-voice, block chords, and arpeggios. At least 30% of sounding frames have 2 or more notes. Keep pitches inside A0–C8. Velocities 40–110. Some notes overlap. Some clips include pitch bend of at most ±2 semitones if the renderer supports it; otherwise omit bend and emit a flat contour label.
4. Bounce with SF2OfflineRenderer.render(midi:soundFont:). Record the bounce sample rate and channel count. Resample to the Basic Pitch training contract: AUDIO_SAMPLE_RATE and AUDIO_N_CHANNELS from basic_pitch constants (22050 Hz stereo WAV). Duplicate mono if the bounce is mono.
5. Save wav, mid, and a json sidecar: programs, tempo, meter, note events (onset sec, offset sec, midi pitch, velocity, channel, bend contour).

Volume: 8,000 clips train, 1,000 val, 500 test. Stratify by program family and polyphony. No shared musical seed across splits.

After the bounce, augment only the audio, never the labels:
- Random gain ±6 dB.
- One convolution from a small set of room IRs (closet, living room, hall).
- Additive noise at 20–35 dB SNR (room tone, street, cafe).
- A mild phone-mic EQ (high-pass near 80 Hz, presence dip).
- Optional ±20 cent static detune on a minority of clips, and shift the contour labels by the same amount. Do not detune so far that semitone identity flips.

Also record a real gate set, at least 30 clips, phone mic, same rooms: piano, guitar, hummed chords, and a speaker playing the SF2 bounces. Align by a clap at t=0 or by tapping along to a click that is not in the analyzed region. This set is never used for training.

Serialize with basic_pitch.data.tf_example_serialization.to_transcription_tfexample. Keys required: file_id, source, audio_wav, notes_indices, notes_values, onsets_indices, onsets_values, contours_indices, contours_values, notes_onsets_shape, contours_shape. Source tag synthetic_sf2. Onset targets are the first frames of each note. Note targets cover the sounding frames. Contour targets are 3 bins per semitone from the bend curve, or the center bin when there is no bend.

## Part 2 — fine-tune

Upstream: https://github.com/spotify/basic-pitch v0.4.0, Apache-2.0. Training entry basic_pitch/train.py. Model basic_pitch/models.py model(). Loss models.loss(label_smoothing=0.2, weighted=True) with onset positive weight 0.95.

- pip install basic-pitch[tf], pinned to the TensorFlow range the repo accepts.
- Load the ICASSP 2022 weights.
- Freeze harmonic stacking for 2 epochs, then unfreeze.
- Adam 1e-4, drop to 1e-5 after validation note loss stalls for 3 epochs. Early stop on validation note-event F1, patience 8, cap 40 epochs.
- Do not change kernel sizes, bin counts, or hop.

Eval with the stock inference.predict path and mir_eval, 50 ms onset tolerance:
- Note F1, onset F1, offset F1.
- Split by polyphony 1 / 2 / 3+ and by program family.
- Same metrics on the frozen original checkpoint.
- Same metrics on the 30 real phone clips.
Ship the fine-tune only if synthetic val note F1 is at least the original, and real-mic note F1 is not more than 2 points below the original. Write both tables to artifacts/metrics.json.

## Part 3 — Core ML export

Convert with the repo Core ML path. The package must match the iOS sample contract:
- Input waveform [1, 43844, 1] at 22050 Hz mono (the window the published BasicPitch_nmp package uses).
- Outputs note [1, 172, 88], onset [1, 172, 88], contour [1, 172, 264].

Compare Core ML against TensorFlow on 5 clips. Fail export if decoded note events differ. Ship fp16 if the note events match; otherwise fp32. Name the package BasicPitchPoly.mlpackage. Checksum-lock the weights. Do not commit the package if it is large; document the fetch.

## Part 4 — on-device listen path

New package Packages/HearSheet (AGPL-3.0-or-later). The app target links it. No Python in the app.

Audio in:
- AVAudioEngine input tap, 22050 Hz mono float, also accept imported m4a/wav/aac via AVAudioFile.
- Permission copy is plain: the recording stays on the phone.
- Level meter reuses SF2Player's meter style so record and playback feel like one app.

Inference:
- Sliding window of 43844 samples with the same hop the Basic Pitch iOS postprocess expects. Overlap-add the posteriorgrams before decoding.
- Core ML, computeUnits .all, a persistent compiled cache.
- Decode with a Swift port of Spotify's note-event creation: onset threshold, frame threshold, minimum note length, pitch-bend trace from the contour head. Expose those four as debug-only. Defaults are Spotify's.
- Frequency gate A0–C8.

Notation:
- Estimate meter from onset IOIs (prefer 4/4, allow 3/4 and 6/8). Estimate key from pitch-class histogram (major/minor). Snap to a 16th-note grid in that tempo, then re-voice chords so simultaneous notes share a stem.
- Write SMF format 1, 480 TPQ.
- Write MusicXML 4.0, partwise, one part, with divisions, key, time, clef (treble, or grand staff when the range crosses middle C by more than an octave and polyphony needs two staves).
- Engrave on device. A readable staff is the product, not a piano roll. Piano roll is the secondary view. Beams, ties for notes that crossed a barline, chord stacking, accidentals from the estimated key. Highlight the note under the playhead.
- Playback goes through SF2MIDIPlayer: load(soundFont:), load(midi:), play(), activeNoteIDs driving the highlight. Do not add another player.

UI, consumer not lab:
- Big record button, elapsed time, stop. After stop, a progress state "Writing the page" under 10 seconds for a one-minute take on iPhone 13 class hardware. Then the engraved page, play, and share.
- Share sheet: MIDI, MusicXML, and a PDF of the engraved page. No account, no upload.
- Empty, denied-mic, and too-quiet states in one sentence each. Too-quiet offers import instead.
- Dynamic Type, VoiceOver labels on record, play, and share.

## Part 5 — done when

- tools/poly-render produces 50 clips end to end on a developer Mac, wav plus mid plus json, and a unit test checks that a C major triad MIDI bounces to non-silent audio and that the sidecar notes match the MIDI.
- Fine-tune metrics file exists and meets the ship rule above. If it fails the rule, ship the original ICASSP Core ML weights and say so in the PR.
- App runs on the simulator for import-file transcription and on a device for mic transcription.
- A 10-second piano triad recording becomes a staff with those chord tones, plays back through SF2MIDIPlayer, and exports MIDI and MusicXML that a desktop notation tool can open.
- No audio leaves the device. Airplane mode still transcribes.
- LICENSE and NOTICE mention Apache-2.0 Basic Pitch and the SoundFont license used to build the training set.
