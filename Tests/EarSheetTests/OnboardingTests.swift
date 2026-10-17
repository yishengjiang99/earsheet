// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import EarSheet

final class OnboardingTests: XCTestCase {
    func testOnboardingCopyDoesNotClaimNothingLeavesPhone() {
        let text = OnboardingCopy.hearText.lowercased()
        XCTAssertFalse(text.contains("nothing ever leaves"))
        XCTAssertFalse(text.contains("nothing leaves"))
        XCTAssertTrue(text.contains("recordings never leave your phone"))
    }
}
