// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import LauncherChecks
final class LauncherCoreTests:XCTestCase {
    func testDomainInvariants() {
        for result in CoreChecks().run() { XCTAssertEqual(result["status"],"pass", "\(result["name"] ?? ""): \(result["detail"] ?? "")") }
    }
}
