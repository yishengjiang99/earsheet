// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import os

/// Plain-language copy for failures shown to users. The technical error is logged locally
/// (never sent anywhere, never shown) so type names and codes do not leak into alerts.
enum UserFacingError {
    enum Context: String, CaseIterable {
        case listeningStart, transcription, writePage, playback, fileWrite, renderMP3, savePhoto, saveLibrary
    }

    private static let log = Logger(subsystem: "com.ragnus.pnge", category: "errors")

    static func message(for error: Error?, context: Context) -> String {
        if let error {
            log.error("\(context.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .private)")
        } else {
            log.error("\(context.rawValue, privacy: .public) failed")
        }
        return copy(for: context)
    }

    static func copy(for context: Context) -> String {
        switch context {
        case .listeningStart:
            return "Couldn't start listening. Make sure no other app is using the microphone, then try again."
        case .transcription:
            return "Something went wrong while listening. Please try again."
        case .writePage:
            return "Couldn't write the page from that recording. Please try again."
        case .playback:
            return "Couldn't play this piece. Please try again."
        case .fileWrite:
            return "Couldn't create the file to share. Check that your device has free storage, then try again."
        case .renderMP3:
            return "Couldn't render the MP3. Please try again."
        case .savePhoto:
            return "Couldn't save the photo. Check that AI Music Radar can add photos in Settings, then try again."
        case .saveLibrary:
            return "Couldn't save your takes. Check that your device has free storage, then try again."
        }
    }
}
