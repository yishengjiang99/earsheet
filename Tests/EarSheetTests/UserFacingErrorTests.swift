// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import EarSheet

extension ExportFlowTests {
    func testUserFacingErrorCopyHasNoTypeNames() {
        struct Technical: Error, CustomStringConvertible {
            var description: String { "EarSheet.BundledModels.LoadError error 0 GeneralUser-GS.sf2" }
        }
        let ns = NSError(domain: "EarSheet.BundledModels.LoadError", code: 42,
                         userInfo: [NSLocalizedDescriptionKey: "The operation couldn't be completed. (EarSheet.BundledModels.LoadError error 0.)"])
        for context in UserFacingError.Context.allCases {
            for error in [Technical(), ns, nil] as [Error?] {
                let message = UserFacingError.message(for: error, context: context)
                XCTAssertEqual(message, UserFacingError.copy(for: context))
                XCTAssertFalse(message.isEmpty)
                let lower = message.lowercased()
                for banned in ["error", "earsheet.", "loaderror", "domain", "operation couldn", ".sf2", "nserror"] {
                    XCTAssertFalse(lower.contains(banned), "\(context): \(message)")
                }
                XCTAssertNil(message.rangeOfCharacter(from: .decimalDigits), "\(context): \(message)")
            }
        }
    }
}
