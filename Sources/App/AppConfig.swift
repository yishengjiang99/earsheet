// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Every URL and product ID the app talks to, in one place.
/// Server routes: `server/src/{iap,devices,telemetry}.ts` (deployed at grepawk.com, BASE_PATH=/music-radar).
enum AppConfig {
    /// Server root (docs/IOS_HANDOFF.md §8); endpoints live under `/api/...`.
    /// Override with the `MUSIC_RADAR_API_BASE` env var (scheme / test runner) or, in DEBUG builds,
    /// the `MusicRadarAPIBase` UserDefaults key, e.g. to point at a local server.
    static let defaultServerBase = URL(string: "https://grepawk.com/music-radar")!

    static var serverBase: URL {
        var override = ProcessInfo.processInfo.environment["MUSIC_RADAR_API_BASE"]
        #if DEBUG
        override = override ?? UserDefaults.standard.string(forKey: "MusicRadarAPIBase")
        #endif
        if let s = override, let u = URL(string: s), u.scheme != nil { return u }
        return defaultServerBase
    }

    enum Product {
        static let monthly = "com.ragnus.pnge.pro.monthly"
        static let yearly = "com.ragnus.pnge.pro.yearly"
        static let lifetime = "com.ragnus.pnge.lifetime"
        static let all = [yearly, monthly, lifetime]
        static let subscriptionGroupName = "AI Music Radar Pro"
        /// ASC subscription group id (asc-setup-iap.yml).
        static let subscriptionGroupID = "22437376"
    }

    enum Links {
        static let privacy = URL(string: "https://grepawk.com/music-radar/privacy")!
        static let terms = URL(string: "https://grepawk.com/music-radar/terms")!
        static let support = URL(string: "https://grepawk.com/music-radar/support")!
    }

    /// Free-tier limits (docs/paywall/PAYWALL_FLOW.md §1). The live view, on-screen score,
    /// playback, MP3 and the page photo are always free.
    enum Free {
        static let savedTakes = 3
        static let importSeconds = 30.0
        static let pdfSeconds = 30.0
    }

    /// Hard technical limits (all tiers), shown in the UI, never silent.
    enum Limits {
        /// Longest live take. The recorder stops here and the listening screen says so.
        static let liveRecordingSeconds = 10.0 * 60
        /// Longest imported file Pro can transcribe in one go.
        static let importSeconds = 10.0 * 60
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}
