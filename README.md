# EarSheet

Home-screen name: **EarSheet**
App Store name: **EarSheet: Music to Sheet**
Bundle id: `com.ragnus.earsheet`
Repo: https://github.com/yishengjiang99/earsheet

Sibling of [SheetCam](https://github.com/yishengjiang99/omr-sheet-cam). SheetCam reads a page. EarSheet hears the music and writes the page.

On-device iOS 17+. Microphone or imported audio goes through a fine-tune of Spotify Basic Pitch (Core ML) and comes out as an engraved staff, SMF MIDI, and MusicXML. Playback uses the SF2 engine from SheetCam. No audio leaves the phone.

## Layout

- `EarSheet.xcodeproj` — app shell, scheme `EarSheet`, team `83D36RPMUM`
- `Sources/App` — SwiftUI app
- `Tests/EarSheetTests` — simulator smoke test the iOS workflow runs
- `Packages/HearSheet` — transcription package
- `tools/poly-render` — SF2 polyphonic label generator
- `scripts/fetch-models` — same entry the SheetCam workflows call; pins live in `models.lock`
- `scripts/asc` — App Store Connect listing script
- `prompts/hearsheet-prompt.md` — fine-tune and listen-mode agent prompt
- `docs/asc/APP_IDENTITY.md` — locked names

## GitHub Actions

Same set as SheetCam, retargeted to this bundle id and scheme:

- `ios-sim.yml` — simulator build, `EarSheetTests/SmokeTests`, HearSheet package tests
- `ios-testflight.yml` — archive and upload
- `ios-screenshots.yml`
- `coreml-diag.yml`
- `asc-status.yml`, `asc-earsheet-upload.yml`, `asc-submit-app-store.yml`, `asc-assign-internal-testing.yml`, `asc-clear-export-compliance.yml`, `asc-cancel-review.yml`

TestFlight profile name expected by the workflow: `EarSheet Music to Sheet App Store`. ASC secrets are the same names as SheetCam (`APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY_P8`).
