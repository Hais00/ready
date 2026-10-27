import LauncherChecks
// SPDX-License-Identifier: GPL-3.0-only
import XCTest

final class LauncherCoreTests: XCTestCase {
  func testDomainInvariants() {
    for result in CoreChecks().run() {
      XCTAssertEqual(result["status"], "pass", "\(result["name"] ?? ""): \(result["detail"] ?? "")")
    }
  }
}
