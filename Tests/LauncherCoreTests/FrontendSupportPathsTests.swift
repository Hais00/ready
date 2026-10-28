// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import LauncherCore
import XCTest

final class FrontendSupportPathsTests: XCTestCase {
  func testBundleAndRuntimeBoundaries() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temp) }
    let resources = temp.appendingPathComponent("relocated.app/Contents/Resources")
    let code = resources.appendingPathComponent("ReadySupport")
    try FileManager.default.createDirectory(at: code, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: code.appendingPathComponent("frontend-package.json"))
    let paths = LauncherPaths(root: temp.appendingPathComponent("private-data"))
    let support = FrontendSupportPaths(paths: paths, resourceRoot: resources, environment: [:])
    XCTAssertTrue(support.isBundled)
    XCTAssertEqual(support.codeRoot.path, code.path)
    XCTAssertEqual(support.runtimeRoot, paths.runtimes)
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.root.path))
    let external = temp.appendingPathComponent("external")
    let explicit = FrontendSupportPaths(paths: paths, resourceRoot: resources, environment: ["READY_RUNTIME_ROOT": external.path])
    XCTAssertEqual(explicit.runtimeRoot, external)
    XCTAssertEqual(FrontendSupportPaths.configuration(paths: paths, runtimeRoot: external), external.appendingPathComponent("runtime.json"))
    try FileManager.default.createDirectory(at: paths.runtimes, withIntermediateDirectories: true)
    let local = paths.runtimes.appendingPathComponent("runtime.json")
    try Data("{}".utf8).write(to: local)
    XCTAssertEqual(FrontendSupportPaths.configuration(paths: paths, runtimeRoot: external), local)
  }

  func testExplicitDevelopmentRootRetainsHistoricalRuntimeFallback() {
    let root = URL(fileURLWithPath: "/development/ready")
    let paths = LauncherPaths(root: URL(fileURLWithPath: "/isolated-test-data"))
    let support = FrontendSupportPaths(paths: paths, resourceRoot: nil, environment: ["READY_PROJECT_ROOT": root.path])
    XCTAssertFalse(support.isBundled)
    XCTAssertEqual(support.codeRoot, root)
    XCTAssertEqual(support.runtimeRoot, root.appendingPathComponent("Runtime"))
  }

  func testWineValidationRejectsDirectoryAndAllowsFinalFileSymlink() throws {
    let fm = FileManager.default
    let resolved = try XCTUnwrap(realpath(fm.temporaryDirectory.path, nil))
    let canonicalTemp = String(cString: resolved)
    free(resolved)
    let temp = URL(fileURLWithPath: canonicalTemp).appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: temp) }
    try fm.createDirectory(at: temp, withIntermediateDirectories: true)
    let config = temp.appendingPathComponent("runtime.json")
    func configuration(wine: String) throws {
      let object: [String: Any] = ["engineDLLs": [String: String](), "wine": wine]
      try JSONSerialization.data(withJSONObject: object).write(to: config)
    }
    // A searchable directory passes isExecutableFile, but cannot be a Wine binary.
    try configuration(wine: temp.path)
    XCTAssertThrowsError(try RuntimeLocationStore.validate(temp))
    let file = temp.appendingPathComponent("wine-file")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    let link = temp.appendingPathComponent("wine-link")
    try fm.createSymbolicLink(at: link, withDestinationURL: file)
    try configuration(wine: link.path)
    XCTAssertTrue(try RuntimeLocationStore.validate(temp).windowsAvailable)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    XCTAssertThrowsError(try RuntimeLocationStore.validate(temp))
  }

}
