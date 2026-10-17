// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest

final class TelemetryPrivacyTests: XCTestCase {
    private func manifest() throws -> [String: Any] {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
            "PrivacyInfo.xcprivacy is not in the app bundle")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testPrivacyManifestPresentAndDeclaresUserDefaults() throws {
        let m = try manifest()
        XCTAssertEqual(m["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((m["NSPrivacyTrackingDomains"] as? [Any])?.count, 0)

        let apis = try XCTUnwrap(m["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let ud = try XCTUnwrap(apis.first {
            $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryUserDefaults"
        })
        XCTAssertEqual(ud["NSPrivacyAccessedAPITypeReasons"] as? [String], ["CA92.1"])
    }

    func testPrivacyManifestCollectedDataIsLinkedAndNotTracking() throws {
        let m = try manifest()
        let types = try XCTUnwrap(m["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let names = Set(types.compactMap { $0["NSPrivacyCollectedDataType"] as? String })
        XCTAssertEqual(names, [
            "NSPrivacyCollectedDataTypePurchaseHistory",
            "NSPrivacyCollectedDataTypeDeviceID",
            "NSPrivacyCollectedDataTypeProductInteraction",
        ])
        for t in types {
            XCTAssertEqual(t["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
            XCTAssertEqual(t["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
            XCTAssertFalse((t["NSPrivacyCollectedDataTypePurposes"] as? [String] ?? []).isEmpty)
        }
    }

    func testPrivacyPageDoesNotClaimDataIsUnlinked() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let page = try String(
            contentsOf: root.appendingPathComponent("docs/legal/music-radar/privacy.html"),
            encoding: .utf8)
        XCTAssertFalse(page.contains("not linked to your identity"))
        XCTAssertTrue(page.contains("random install ID"))
    }
}
