# EarSheet

Home-screen name: **EarSheet**
App Store name: **EarSheet: Music to Sheet**
Bundle id (proposed): `com.ragnus.earsheet`
Repo: https://github.com/yishengjiang99/earsheet

Sibling of [SheetCam](https://github.com/yishengjiang99/omr-sheet-cam). SheetCam reads a page. EarSheet hears the music and writes the page.

On-device iOS 17+. Microphone or imported audio goes through a fine-tune of Spotify Basic Pitch (Core ML) and comes out as an engraved staff, SMF MIDI, and MusicXML. Playback uses the SF2 engine from SheetCam. No audio leaves the phone.

Training-data generation and the agent prompt live in `prompts/hearsheet-prompt.md`.
