# Verovio evaluation (Oct 2026)

**Decision: keep the native engraver (`Packages/HearSheet/Sources/HearSheet/Engraver.swift`) for the
Page view and exports; revisit Verovio later as an optional export path (MusicXML → SVG/PDF).**

## What Verovio is
- C++20 engraving library (RISM Digital), MEI/MusicXML/Humdrum in, SVG out; official Swift binding
  for iOS. https://github.com/rism-digital/verovio
- License: **LGPL-3.0** (COPYING = GPLv3 text + COPYING.LESSER). Compatible with this app's
  AGPL-3.0-or-later. Linking it into an App Store binary needs LGPL compliance (users must be able to
  relink a modified Verovio). Since all of this app's source is published under the AGPL, that is
  satisfiable by shipping the object files / build instructions, but it is an extra obligation to track.
  Its SMuFL fonts (Leipzig: OFL; Bravura: OFL) are fine to bundle.

## Why not now
- **Interactivity:** the Page view highlights notes during playback, maps taps to notes and shows the
  tunable tempo mark. With Verovio the app would render SVG (WKWebView or an SVG renderer) and map
  playback indices to SVG element ids; our layout already exposes note frames to UIKit directly.
- **Size/build:** a C++20 library + fonts adds several MB and a second toolchain to CI; the native
  engraver is ~1k lines of Swift with unit tests that run on macOS and Linux.
- **Scope of the readability bugs:** key-signature positions, chord seconds, accidental columns,
  redundant naturals, ties/flags and full-width justification were fixable in the native engraver
  (see `EngravingReadabilityTests`).
- Not prototyped: this is a docs/license evaluation, not a build trial.

## When to reconsider
Multi-voice notation, tuplets, slurs/dynamics, or print-quality PDF beyond the screen layout.
A low-risk first step is server-side or export-only use (MusicXML → SVG/PDF), leaving the on-screen
view native.
