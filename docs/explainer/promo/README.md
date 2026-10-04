# Promo video build (landing + TikTok)

Sources for `../ai-music-radar-landing.mp4` (1920×1080, 39.5 s) and `../ai-music-radar-tiktok.mp4`
(1080×1920, 19 s). Every note on screen is a real transcription, not drawn by hand:

1. `compose.py` writes a short original melody (`piano.mid`, 4 bars @ 120 BPM, C/Am) and a guitar
   arpeggio (`guitar.mid`). These are rendered with FluidSynth (Salamander Grand Piano / Spanish Classical
   Guitar SF2).
2. `demo.py` uploads each WAV to the web demo (`web/`, served locally) in headless Chrome and scrapes the
   transcribed note table, which becomes `data.js`. The page view uses the web demo's own ABC output
   (`piano.abc`, treble voice only) rendered with abcjs.
3. `bed.py` writes the music bed: an original drum, bass, keys and pad loop (C–Am–F–G, 120 BPM) rendered with
   FluidR3_GM, so it's royalty-free. `mix.py` swaps the bed to a drums-only stem (`bed.py N out.mid drums`) under the demo audio, jump-cuts the live take on a beat and adds tap clicks. The
   playback audio is the transcribed notes re-synthesized.
4. `scene.html?mode=landing|tiktok` is a deterministic `renderAt(t)` scene: a phone mock of the app's
   Listening / Take (Piano roll / Page) / Export screens, matching `Sources/App`, plus captions. `render.py`
   screenshots it at 30 fps into ffmpeg, then the WAV is muxed in (loudnorm −14 LUFS).

The scripts were run from `/workspace/vid2` with `site/` holding `scene.html`, `data.js`,
`abcjs-basic-min.js` and `icon.png`. This copy points at `web/vendor` and the app icon by relative path instead.
