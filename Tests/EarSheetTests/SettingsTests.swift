// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import EarSheet

/// Settings screen logic (#14, #25).
final class SettingsTests: XCTestCase {
    func testGoProRowRoutesByEntitlement() {
        XCTAssertEqual(SettingsView.goProRoute(isPro: true), .manage)
        XCTAssertEqual(SettingsView.goProRoute(isPro: false), .paywall)
    }
}
