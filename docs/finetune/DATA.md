# Fine-tune data: sources and licenses

No audio, MIDI, SoundFonts or weights are committed (repo rule). Everything below is
downloaded or generated locally, then turned into pairs with
`tools/poly-render-py/poly_render.py` (synthetic) or `tools/real-data/prepare_real.py` (real).

## SoundFonts (synthetic renders via FluidSynth)

| SoundFont | Source | License | Used for |
|---|---|---|---|
| GeneralUser GS (S. Christian Collins) | scripts/fetch-models (models.lock pin) | GeneralUser GS license: free use, including commercial | train, val, test-gugs |
| FluidR3_GM (Frank Wen) | Debian `fluid-soundfont-gm` | MIT | **test only** (unseen-timbre tests) |
| MuseScore General (S. Christian Collins) | Debian `musescore-general-soundfont` | MIT | train |
| TimGM6mb (Tim Brechbill) | Debian `timgm6mb-soundfont` | GPL-2 | train |
| sf_GMbank (csound) | Debian `csound` assets | LGPL-2.1+ | train |
| Salamander Grand Piano V3 SF2 (Alexander Holm; SF2 by freepats) | freepats.zenvoid.org | CC BY 3.0 | train (piano) |
| Upright Piano KW (freepats) | freepats.zenvoid.org | CC0 1.0 | train (piano) |
| Spanish Classical Guitar (freepats) | freepats.zenvoid.org | CC0 1.0 | train (guitar) |

Training on renders does not redistribute the SoundFonts. The model weights are not
derivative sample data. Attribution for the CC BY sources is given here anyway.

## Real recordings with aligned notes

| Dataset | Source | License | Split used here |
|---|---|---|---|
| GuitarSet (Xi et al., ISMIR 2018), mono mic audio + JAMS note_midi | Zenodo 3371780 | CC BY 4.0 | players 00-03 train, 04 (subset) val, **05 test** |
| MAESTRO v3.0.0 (Hawthorne et al., ICLR 2019), subset streamed with remotezip | magenta storage | **CC BY-NC-SA 4.0** (non-commercial, share-alike) | 35 "train" pieces train, 5 "train" pieces val, **12 "test" pieces test** |
| Saarland Music Data (SMD) piano v2 (Müller et al.) | Zenodo 13753319 | CC BY 3.0 | piece-level split, about 25% test |

**License note:** a model fine-tuned on MAESTRO inherits its NC-SA terms. That is
acceptable for this demo, but it is not OK for a commercial release. Any shipped
weights trained with MAESTRO must be labelled that way. To get a commercially clean
model, train without MAESTRO (GuitarSet + SMD + SoundFont renders only).

Stock Basic Pitch was itself trained on GuitarSet, MAESTRO, and other data, so its
scores on GuitarSet and MAESTRO test sets are likely optimistic.
