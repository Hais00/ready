// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Launcher-owned code is relocatable with the app; versioned engines and store
/// tools live outside it. Resolving paths never creates directories or copies data.
public struct FrontendSupportPaths {
  public let codeRoot: URL
  public let runtimeRoot: URL
  public let isBundled: Bool
  public let runtimeLocationOrigin: String
  public let runtimeLocationIssue: String?

  public init(
    paths: LauncherPaths, resourceRoot: URL? = Bundle.main.resourceURL,
    executable: URL = URL(fileURLWithPath: CommandLine.arguments[0]),
    workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    let fm = FileManager.default
    let bundled = resourceRoot?.appendingPathComponent("ReadySupport", isDirectory: true)
    if let source = environment["READY_PROJECT_ROOT"], !source.isEmpty {
      codeRoot = URL(fileURLWithPath: source).standardizedFileURL
      isBundled = false
    } else if let bundled, fm.fileExists(atPath: bundled.appendingPathComponent("frontend-package.json").path) {
      codeRoot = bundled.standardizedFileURL
      isBundled = true
    } else {
      // swift run / a directly invoked .build executable still finds its source
      // checkout when the shell's working directory is elsewhere.
      var candidate = executable.standardizedFileURL.deletingLastPathComponent()
      var source: URL?
      for _ in 0..<7 {
        if fm.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path),
          fm.fileExists(atPath: candidate.appendingPathComponent("StoreBridge/bridge.py").path) {
          source = candidate
          break
        }
        candidate.deleteLastPathComponent()
      }
      codeRoot = (source ?? workingDirectory).standardizedFileURL
      isBundled = false
    }
    var saved: URL?
    var issue: String?
    do { saved = try RuntimeLocationStore.savedRoot(paths: paths) }
    catch { issue = error.localizedDescription }
    runtimeLocationIssue = issue
    if let external = environment["READY_RUNTIME_ROOT"], !external.isEmpty {
      runtimeRoot = URL(fileURLWithPath: external).standardizedFileURL
      runtimeLocationOrigin = "environment"
    } else if let saved {
      runtimeRoot = saved
      runtimeLocationOrigin = "saved"
    } else {
      runtimeRoot = isBundled ? paths.runtimes : codeRoot.appendingPathComponent("Runtime")
      runtimeLocationOrigin = isBundled ? "application-data" : "development"
    }
  }

  /// Existing user configuration always has priority over the external default.
  public static func configuration(paths: LauncherPaths, runtimeRoot: URL) -> URL {
    let local = paths.runtimes.appendingPathComponent("runtime.json")
    return FileManager.default.fileExists(atPath: local.path)
      ? local : runtimeRoot.appendingPathComponent("runtime.json")
  }
  public var sessionHost: URL { codeRoot.appendingPathComponent("Build/ReadySessionHost") }
  public var overlay: URL { codeRoot.appendingPathComponent("Build/libReadyOverlay.dylib") }
  public var storeBridge: URL { codeRoot.appendingPathComponent("StoreBridge/bridge.py") }
}
