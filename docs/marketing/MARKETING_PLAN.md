# AI Music Radar — Marketing Plan (v1)

**Status:** DRAFT v1 (2026-10-03). The pricing and name choices need Yisheng's sign-off; everything else is ready to execute for TestFlight → App Store launch.
**App:** AI Music Radar · bundle `com.ragnus.pnge` · ASC 6818838017 · iOS 17+
**Funnel assets:** [free web demo](https://grepawk.com/music-hear/) · [90-sec explainer](https://github.com/yishengjiang99/earsheet/blob/main/docs/explainer/earsheet-explainer.mp4)

Competitor figures below come from App Store US listings, lookups and recent-review RSS feeds, plus vendor pricing pages, all checked on 2026-10-03. Sources are at the bottom. "1–2★ share" means the share of *recent* US reviews, not lifetime reviews.

---

## 1. One-line pitch & positioning

**Pitch:** *Play it, see it. AI Music Radar turns what you hear into sheet music, live and entirely on your iPhone.*

**Positioning statement:** For musicians who learn and write by ear, AI Music Radar is the transcription app that writes notes **while you play**. It runs **on-device** with no upload, no account and no waiting on a server, then gives you a real engraved score, a piano roll, and MIDI / MusicXML / PDF export.

**Three proof points (in this order):**
1. **Live.** Notes appear as you play or sing; the web demo runs at about 0.7 s latency. No competitor checked on iOS is real-time polyphonic. Melody Scanner's listing says it is "not able to show you live note recognition", and Klangio Transcription Studio says "Not real-time".
2. **On-device and private.** The Core ML model (Spotify Basic Pitch) runs locally: it works offline and needs no login, your audio never leaves the phone, and no server outage can take it down. Cloud reliability is the category's #1 complaint. Melody Scanner has 1.66★ with 16 of its 20 recent reviews at 1–2★, and ScoreCloud Express has 1.97★ with 120 of 150 recent reviews at 1–2★, over errors, logouts that lose files, and credits that don't renew.
3. **Real musician output.** You get an engraved staff, tempo, meter and key estimation, playback with note highlighting, and MIDI / MusicXML / PDF that opens in MuseScore, Dorico, Sibelius or Logic.

**Language rules**
- Lead with *transcription tool*, *live* and *on-device*. Most big music subreddits (and r/iOSApps) are openly hostile to "AI apps", so in community copy the AI is the engine, not the headline. "AI" stays in the brand name only.
- Never claim "perfect" accuracy. Say "a first draft in seconds that you can clean up". Accuracy complaints hurt every competitor's ratings.
- Never use fake testimonials or star counts before real reviews exist.

---

## 2. Audiences & jobs-to-be-done

| Segment | Job-to-be-done | Trigger moment | What sells them | Where they are |
|---|---|---|---|---|
| **Students learning by ear** (piano/guitar/voice, high school → conservatory) | "Help me work out the notes of this melody or passage so I can practice it / check my ear." | No sheet music exists for a song they love; ear-training homework | Live feedback while they play or sing along; slow playback with highlighting; cheap | TikTok/Reels #pianotok, r/piano "how do I find notes" threads, YouTube tutorials |
| **Teachers** (private studio, school music ed) | "Turn what I play at the piano or a student plays into a handout fast." "Show students what they just played." | Lesson prep; arranging simple parts | MusicXML → MuseScore editing; PDF in seconds; works offline in a classroom; no student accounts or uploads (privacy) | r/MusicEd, Facebook teacher groups, MTNA/NAfME circles, music-ed newsletters |
| **Songwriters** | "Capture the idea before I lose it, as notes I can share with a band or producer." | Melody hits on a walk or at the piano | Instant capture, offline; MIDI into the DAW; key/tempo detection | r/Songwriting (mods first), Instagram/TikTok songwriter creators, producer Discords |
| **Cover musicians / arrangers** | "Get a usable first draft of this tune's melody or chords so I'm not transcribing for hours." | Learning a set list; making a cover arrangement | Import audio → score + MIDI; piano roll for checking voicings; much cheaper than desktop tools | YouTube covers, r/Musescore, guitar/bass/piano cover TikTok |

**Primary launch target:** students and cover musicians (largest volume, most viral demo moment). Teachers come second, because they bring word of mouth and a credible institutional segment.

---

## 3. Competitive landscape

| App | Platform | Where it runs | Real-time | Polyphonic | Exports | Price (US, 2026-10-03) | Rating (US) | Weak spot in reviews |
|---|---|---|---|---|---|---|---|---|
| **Melody Scanner** (Klangio) | iOS/Android/web | Cloud | No | Solo instrument | PDF/MIDI/MusicXML | $5.99/mo · $44.99/yr | 1.66★ (35) | Errors, "nothing happens", inaccuracy, login wall |
| **Piano2Notes** (Klangio) | iOS/web | Cloud | No | Yes (piano) | PDF; MIDI/MusicXML need Pro | $9.99/mo · $99.99/yr · tokens $2.99–$24.99 | 4.27★ (294) | Wrong time signatures, crashes, logouts lose files, price |
| **Guitar2Tabs / Sing2Notes** (Klangio) | iOS/web | Cloud | No | Guitar / vocal | Tabs, PDF, MIDI, XML | $9.99/mo · $99.99/yr | 3.43★ / 3.63★ | Inaccurate, credit issues |
| **Klangio Transcription Studio** | iOS (Aug 2026)/web | Cloud ("Internet connection" required) | No ("Not real-time") | Full mixes | PDF/MIDI/XML/GP | Web: $19.99–$29.99/mo | new | — |
| **ScoreCloud Express** | iOS (+ desktop) | Cloud | Near-instant, **mono only** on iOS | Desktop only | Desktop: PDF/MIDI/XML | $2.99 + $4.99/mo; web plans $5.99–$20.99/mo | 1.97★ (257, not updated since 2018) | Crashes, server/login errors |
| **AnthemScore** | Desktop only | Local | No | Yes | PDF/MIDI/XML | One-time $29 / $39 / $99 | n/a | Desktop-only, file-based |
| **Songscription** | Web only | Cloud | No | Multi-instrument | PDF/MIDI/XML/GP | $99.90/yr · $299.90/yr | n/a | No app |
| **Reprise** | iOS (Jun 2026) | Likely cloud | No | Splits arrangements | MIDI/XML | $6.99/wk · $29.99/mo · $39.99/yr | 4.53★ (~300) | Paywall after seconds, accuracy on band mixes |
| **Piano Transcriptionist** | iOS/Mac | **On-device** | No (file-based) | Piano only | MIDI/PDF/video | Free + tips | 4.24★ (42) | Closest tech analog, but piano-only and no live mode |
| **Basic Pitch web** (Spotify) | Web | In browser | No | Yes | **MIDI only** | Free | n/a | No notation, key/meter detection or app |
| Moises / Chordify / Chord ai | iOS etc. | Cloud | Chord ai live | Chords/stems only | Chords, stems | $5.99–$10.99/mo | 4.6–4.7★ | Adjacent category, not note-level scores |

**Where we win:** no competitor checked offers **real-time, polyphonic, on-device transcription on iPhone with an engraved score**. Klangio owns search volume and polyphonic file transcription, but it is cloud-based, not real-time, and full of login and credit complaints.

**Where we're exposed:**
- Full-mix multi-instrument separation (Klangio Studio, Reprise). Answer: "best on a single instrument or voice", plus the upcoming fine-tuned model.
- The free Basic Pitch web tool already gives away raw MIDI. Answer: our value is notation, key/meter detection, live use, playback and the iPhone workflow, not the MIDI itself.

**Do not:** disparage competitors by name in ads. Comparisons stay in an FAQ or blog post, factual and dated.

---

## 4. App Store listing

**Name (≤30):** `AI Music Radar: Sheet Music` (27). Alternatives: `AI Music Radar - Audio to Notes` is 31, too long; `Music Radar: Audio to Notes` (27) if dropping "AI" helps review or community perception.

**Subtitle (≤30), shipped:** `Audio to Sheet Music & MIDI` (27). This is live in `docs/asc/metadata/en-US/subtitle.txt`. Avoid "live" in store copy: the iOS app transcribes after you stop recording, and only the web demo is real-time.
Alternatives: `Audio to Sheet Music, Live` (26) · `Hear it. See the notes. Live.` (29) · `Transcribe music to score` (25)

**Keyword field (≤100 chars, comma-separated, no spaces, no words repeated from the name/subtitle):**
```
transcribe,transcription,midi,musicxml,piano,score,melody,offline,private,songwriter,ear,pdf
```
(Swap in `tabs`/`chords` only once those exist.)

**Why these words:** competitor titles cluster around "Transcribe", "Audio to Sheet Music", "Audio to MIDI" and "Convert ___ to Notes". "audio to sheet music" search results are thin (the top results are small apps with 3–635 ratings), so the term is winnable. **No competitor uses "live", "on-device", "offline" or "private"**, so we own those words in metadata.

**Screenshot captions (draft, in order):**
1. Play it. See the notes. Live.
2. Runs on your iPhone. No upload, no account.
3. Engraved score + piano roll, in key and in time.
4. Playback that follows every note.
5. Export MIDI, MusicXML and PDF.

**App preview video:** a 15–25 s cut of the explainer that opens on a live piano phrase appearing on the staff in the first 2 seconds.

---

## 5. Pricing & monetization (proposal, needs sign-off)

Market norms: $4.99–$14.99/mo and $39–$100/yr. The free tier is usually a 20–30 s clip with MIDI/MusicXML behind the paywall. Klangio sells tokens at $2.99 per song. Because transcription runs on-device, **our marginal cost is roughly zero**, so we can undercut on price and offer a lifetime option almost nobody in the iOS category has.

| Tier | What | Price |
|---|---|---|
| **Free** | Unlimited live transcription on screen; save up to 3 pieces; PDF export of the first 30 s | $0 |
| **Pro** | Unlimited saves, full-length import, MIDI + MusicXML + full PDF, key/meter/tempo edits, slow playback | **$4.99/mo** or **$29.99/yr**, 7-day free trial |
| **Lifetime** | Pro forever | **$49.99** one-time (launch price $39.99 for the first 30 days) |

**Why:**
- The yearly plan sits below Melody Scanner ($44.99) and far below Klangio ($99.99).
- Lifetime is a strong anti-subscription message aimed at the "credits didn't renew" complainers, and it is credible because nothing runs on a server.

**Later:** a teacher/education plan (Apple School Manager volume purchase) and a "fine-tuned model" Pro feature bump once the new model ships.

---

## 6. Launch channels

**The web demo is the funnel.** grepawk.com/music-hear/ is a no-install "try it now" that works in any browser. Every channel points either to the demo or to TestFlight/App Store, and the demo itself converts with:
- a persistent "Get the iPhone app — export MIDI/MusicXML/PDF" banner after the first transcription,
- a QR code on desktop and a deep link on iOS Safari,
- UTM-tagged links per channel (`?utm_source=tiktok` etc.) so we can see which channel drives installs,
- an email capture for "notify me at App Store launch" while the app is TestFlight-only.

**Reddit and communities (rules checked, so play by them):**
- **Never** post "I built an app" to r/WeAreTheMusicMakers, r/Guitar, r/piano or r/guitarlessons. All four ban it, often permanently, and most also ban AI posts.
- **Allowed routes:**
  - r/iOSApps (dev post format: problem / why better / price; once per 30 days)
  - r/Musescore (MusicXML → MuseScore workflow)
  - r/edmproduction weekly Marketplace thread
  - r/AppHookup (for a launch-week lifetime discount)
  - r/Songwriting and r/musictheory only after messaging mods first
  - Genuinely helpful answers to "how do I find the notes to X" questions, with disclosure
- Off Reddit: MuseScore.org forums, Piano World, The Gear Page, music-teacher Facebook groups, and Discords (music theory, producer servers).
- Show HN / Product Hunt: lead with the on-device angle (Core ML Basic Pitch, about 0.7 s latency, WebGPU web demo). The tech crowd shares this kind of thing.

**TikTok / Reels / Shorts (the main growth engine):** short demos where the "wow" happens in the first 2 seconds.
- Formats:
  - "Can it transcribe this?" played live (piano riffs, a hummed hook, a viral sound)
  - "I hum, it writes the notes"
  - Teacher POV: "student plays, sheet music appears"
  - Phone in airplane mode to prove it works offline
- Post 1–2 a day from a brand account and seed 5–10 micro-creators (piano/guitar teachers, 10k–200k followers) with free lifetime codes.

**Other:**
- A YouTube long-form "how to transcribe a song by ear with your iPhone" tutorial (SEO).
- Pitch Apple App Store editorial ("on-device ML" is an Apple-friendly story).
- A press note to music-tech blogs (MusicRadar, Synthtopia, CDM, 9to5Mac).

---

## 7. First-month plan

| Week | Focus | Actions | Success metric |
|---|---|---|---|
| **0 (pre-launch)** | Assets | Finalize listing + screenshots; cut 5 short demos from the explainer; add the app banner, UTMs and email capture to the web demo; open the TestFlight public link | Listing approved; demo → TestFlight click-through measurable |
| **1** | TestFlight + seeding | Post the public TestFlight link to r/iOSApps (format-compliant), MuseScore forum and Discords; DM 20 piano/guitar teachers for feedback; daily TikTok/Reels demo | 200 TestFlight testers; 30 pieces of feedback |
| **2** | Creators + proof | Send lifetime codes to 10 micro-creators; collect real user clips (with permission); fix the top 3 accuracy complaints; Show HN with the web demo | 3 creator posts live; 1 post over 50k views |
| **3** | App Store launch | Go live with the $39.99 lifetime launch price; Product Hunt; r/AppHookup; press note; Apple editorial pitch; post in teacher groups | 1,000 installs; 3%+ trial start; 20+ ratings at 4.5★+ |
| **4** | Optimize | Double down on the best hook/channel by UTM; A/B test the subtitle and first screenshot (Product Page Optimization); in-app review prompt after a 3rd successful export | Install → trial ≥ 8%; trial → paid ≥ 30%; rating ≥ 4.5★ |

The targets are first-month guesses for a zero-budget launch, not benchmarks. Re-set them after week 2 using real data.

---

## 8. Ad / social hooks

1. **"Play it. Watch it become sheet music — live, on your iPhone."** (live demo, piano close-up)
2. **"Hum the song stuck in your head. Get the notes in seconds."** (student/songwriter, selfie-style)
3. **"No upload. No account. Works in airplane mode."** (privacy/offline proof; phone shows airplane mode, then transcribes)

Backup: *"Stop transcribing by ear for 3 hours. Get a first draft in 3 seconds."* (cover musicians)

---

## Sources (checked 2026-10-03)

Melody Scanner: https://apps.apple.com/us/app/melody-scanner/id6472921068 · Piano2Notes: https://apps.apple.com/us/app/piano2notes/id1589420929 · Klangio plans: https://klang.io/help/compare-apps-and-subscriptions/ · https://klang.io/products/ · Klangio Studio: https://apps.apple.com/us/app/id6790710981 · ScoreCloud: https://scorecloud.com/plans-comparison-chart/ · https://apps.apple.com/us/app/scorecloud-express/id566535238 · AnthemScore: https://lunaverus.com/purchase · Songscription: https://www.songscription.ai/pricing · Reprise: https://apps.apple.com/us/app/id6779112344 · Piano Transcriptionist: https://apps.apple.com/us/app/id6456886504 · Moises: https://apps.apple.com/us/app/id1515796612 · Chordify: https://apps.apple.com/us/app/id1073624757 · Chord ai: https://apps.apple.com/us/app/id1446177109 · Basic Pitch: https://basicpitch.spotify.com/ · Ratings/reviews: iTunes lookup + customer-review RSS (US) · Subreddit rules: https://threadfox.vip/rules/piano (and /WeAreTheMusicMakers, /Guitar, /edmproduction, /Songwriting, /guitarlessons, /musicians), https://redpulse.io/subreddit-search/r/musictheory/
