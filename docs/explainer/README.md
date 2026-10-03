# AI Music Radar — explainer video & landing page

[`ai-music-radar-explainer.mp4`](ai-music-radar-explainer.mp4) (~4:47, 1920×1080, H.264/AAC) is the
current explainer. It covers the on-device pipeline (mic → 22 kHz mono → Core ML Basic Pitch →
Swift decoder → quantizer → engraved score), verified model weights (models.lock + SHA-256,
release assets, never in git), the tuned decoder (onset 0.7 / frame 0.4 / min-note 5 frames —
GuitarSet 80.2→84.3, MAESTRO 69.5→73.5, SMD 70.3→76.2), and the active fine-tuning work:
the velocity audit (velocity was model confidence, not loudness), the velocity-head experiment
vs. the winning energy calibration (MAE 9.2 vs 19.4), and note-off tuning (offset F1 0.202→0.245).
Closes with the app output tour and Free / Pro / Lifetime pricing.

The narration is synthetic text-to-speech and the scenes are HTML rendered to frames
(see the build notes below). Branding uses the current App Store identity: **AI Music Radar**
(bundle `com.ragnus.pnge`).

[`index.html`](index.html) is a landing page embedding the video, the five iPhone App Store
screenshots (`../asc/screenshots/en-US/iphone-69-*.png`), and marketing copy from
`docs/marketing/MARKETING_PLAN.md` (pitch, proof points, pricing, web-demo CTA).
[`poster.jpg`](poster.jpg) is the video poster frame.

## Transcript (abridged)

**1. Title:** AI Music Radar. Play it, see it. Point your iPhone at music and watch it become
sheet music — nothing leaves the phone.

**2. Pipeline:** Microphone at 22 kHz mono → Spotify's Basic Pitch in Core ML on the Neural
Engine, overlapping two-second windows → Swift decoder (posteriors to notes) → quantizer
(tempo, meter, key, sixteenth-note grid) → engraved score. No upload, no account, no server;
works in airplane mode.

**3. Verified models:** Every weight file pinned in models.lock, SHA-256 verified on fetch,
shipped as versioned release assets — never committed to git.

**4. Decoder tuning:** Onset 0.7, frame 0.4, min note 5 frames (58 ms). Note F1 on real
recordings: GuitarSet 80.2→84.3, MAESTRO 69.5→73.5, SMD 70.3→76.2. No retraining.

**5. Dynamics gap:** The audit found velocity = 127 × mean note probability — model confidence,
not loudness. A quiet clear note could score 121 while a loud noisy one scored lower.

**6. Teaching loudness:** A velocity head trained on MAESTRO/SMD true velocities (590 chunks,
29,373 matched notes) vs. a plain per-pitch energy calibration. Calibration won: MAE 9.2,
r=0.71, vs. head 11.3 and old confidence 19.4 (worse than guessing the median).

**7. Note-offs:** Offset F1 0.202→0.245 via decoder grid search, costing 0.031 onset F1.
A dedicated note-off head is queued model work.

**8. Output:** Engraved score + piano roll, playback with note highlighting, MIDI / MusicXML /
PDF export. A first draft in seconds — not a promise of perfection.

**9. Pricing:** Free (unlimited transcription, 3 saves); Pro $4.99/mo or $29.99/yr (7-day trial);
Lifetime $49.99 (launch $39.99). Try the web demo at grepawk.com/music-hear.

## Build notes

Scenes are deterministic HTML (`window.renderAt(t)` — no wall-clock animation), recorded
frame-by-frame with headless Chromium at 24 fps, narration synthesized per scene with the
`tts` CLI, assembled with ffmpeg (per-scene mp4 + padded narration, concatenated, muxed).

## Previous version

[`earsheet-explainer.mp4`](earsheet-explainer.mp4) (~94 s) is the earlier cut, kept so existing
links keep working. It describes the app as built on `main` at the time: the one-screen flow,
the `Packages/HearSheet` pipeline, SF2Player playback, model pinning, optional Phase B
fine-tuning, and CI.
