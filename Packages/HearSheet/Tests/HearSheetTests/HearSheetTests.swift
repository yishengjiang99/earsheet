import XCTest
@testable import HearSheet

final class HearSheetTests: XCTestCase {
    func testIdentity() {
        XCTAssertEqual(HearSheet.bundleIdentifier, "com.ragnus.earsheet")
        XCTAssertEqual(HearSheet.modelName, "BasicPitchPoly")
    }
}
