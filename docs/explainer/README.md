# EarSheet explainer video

[`earsheet-explainer.mp4`](earsheet-explainer.mp4) runs about 94 seconds (1920×1080, H.264/AAC). It walks through how EarSheet works as the code stands on `main`: the one-screen app, the on-device pipeline in `Packages/HearSheet`, SF2Player playback, model pinning, optional Phase B fine-tuning, and CI.

The narration is synthetic text-to-speech, and the slides are rendered from HTML.

## Transcript

**1. What EarSheet is:** EarSheet turns music you play into sheet music, right on your iPhone. Record or import audio, and you get an engraved staff, MIDI, and MusicXML. No audio leaves the phone.

**2. User flow:** It's one screen. Tap record, tap stop, and it starts writing the page. You get the staff or a piano roll, playback that highlights each note, and a share sheet with MIDI, MusicXML, and PDF. Takes max out at sixty seconds.

**3. Transcription pipeline:** Audio comes in at twenty-two kilohertz mono. Spotify's Basic Pitch model runs in Core ML over overlapping two-second windows. A Swift port of Spotify's decoder turns its outputs into notes. The quantizer then estimates tempo, meter, and key, and snaps every note to a sixteenth-note grid.

**4. Code map:** The HearSheet package owns that pipeline, along with the engraver and the MIDI and MusicXML writers. The SwiftUI app only drives the screen. Playback goes through SF2Player, a vendored SoundFont synth.

**5. Models:** Weights are never committed. The fetch-models script downloads what models dot lock pins and checks every SHA-256.

**6. Phase B fine-tuning:** Fine-tuning is an optional Mac-only phase. Poly-render turns MIDI into paired training audio. The fine-tune script starts from Spotify's published weights and ships only if the result holds up against them.

**7. CI and building:** In CI, the iOS simulator workflow runs the smoke and triad-import tests, plus both package test suites. To build it yourself, run fetch-models and open the Xcode project.
