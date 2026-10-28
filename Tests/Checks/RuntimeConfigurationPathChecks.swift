// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import LauncherCore

enum RuntimeConfigurationPathChecks {
  private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw LauncherError.failed(message) }
  }
  private static func rejects(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw LauncherError.failed("Invalid portable runtime document was accepted")
  }
  private static func write(_ document: [String: Any], to url: URL) throws {
    try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: url)
  }
  static func validate() throws {
    let fm = FileManager.default
    guard let temporary = realpath(fm.temporaryDirectory.path, nil) else {
      throw LauncherError.failed("Cannot resolve temporary fixture directory")
    }
    let root = URL(fileURLWithPath: String(cString: temporary)).appendingPathComponent("ready-config-paths-" + UUID().uuidString)
    free(temporary)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let original = root.appendingPathComponent("original runtime")
    for relative in ["engine/bin", "engine/pe64", "engine/pe32", "icd"] {
      try fm.createDirectory(at: original.appendingPathComponent(relative), withIntermediateDirectories: true)
    }
    // Availability fixtures only: this is not a Wine/renderer compatibility test.
    let fixtureWine = original.appendingPathComponent("engine/bin/wine")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fixtureWine)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixtureWine.path)
    for relative in ["engine/pe64", "engine/pe32"] {
      for name in ["d3d11.dll", "dxgi.dll", "winemetal.dll", "d3d12.dll", "kernel32.dll"] {
        try Data("Synthetic path fixture only".utf8).write(to: original.appendingPathComponent(relative + "/" + name))
      }
    }
    try Data("{}".utf8).write(to: original.appendingPathComponent("icd/kosmic.json"))
    let document: [String: Any] = [
      "pathFormat": RuntimeConfigurationPaths.relativeFormat,
      "runtimeID": "synthetic-relative-runtime", "wineVersion": "fixture",
      "wine": "engine/bin/wine", "wineServer": "engine/bin/wine", "wineBoot": NSNull(),
      "wineBinary": "engine/bin/wine", "kosmicICD": "icd/kosmic.json",
      "kosmicNativeICD": "icd/kosmic.json", "moltenICD": "icd/kosmic.json",
      "vulkanLibrary": "engine/vulkan.dylib", "immutableRuntimeSet": "engine",
      "sourceDependencyPrefix": "engine/dependencies", "builtin32Directory": "engine/pe32",
      "engineDLLs": ["dxmtMetal": "engine/pe64"], "engineDLLs32": ["dxmtMetal": "engine/pe32"],
      "engineWineBinaries": ["dxmtMetal": "engine/bin/wine"],
      "engineWineServers": ["dxmtMetal": "engine/bin/wine"],
      "engineSearchPaths": ["dxmtMetal": "engine"],
      "engineBootstrap32Dirs": ["dxmtMetal": "engine/pe32"],
      "engineBuiltin32Dirs": ["dxmtMetal": "engine/pe32"],
      "engineOverrides": ["dxmtMetal": "d3d11,dxgi,winemetal=b"],
      "engineAPIs": ["dxmtMetal": ["d3d11"]], "verifiedEngines": ["dxmtMetal"],
      "provenance": ["originalBuildRoot": original.path],
    ]
    let file = original.appendingPathComponent("runtime.json")
    try write(document, to: file)
    let originalBytes = try Data(contentsOf: file)
    let moved = root.appendingPathComponent("moved runtime with spaces")
    try fm.moveItem(at: original, to: moved)
    let resolvedRoot = moved.standardizedFileURL.resolvingSymlinksInPath()
    let movedFile = moved.appendingPathComponent("runtime.json")
    let resolved = try RuntimeConfigurationPaths.readDocument(movedFile)
    let runtime = try RuntimeConfiguration.read(movedFile)
    try require(runtime.wine == resolvedRoot.appendingPathComponent("engine/bin/wine").path, "Wine remained bound to the old installation")
    try require(runtime.engineDLLs32?["dxmtMetal"] == resolvedRoot.appendingPathComponent("engine/pe32").path, "PE32 payload was not relocated")
    try require(runtime.bootstrap32Directory(engine: .dxmtMetal) == resolvedRoot.appendingPathComponent("engine/pe32").path, "Pure PE32 provider was not relocated")
    try require(runtime.runtimeIdentity == "synthetic-relative-runtime", "Relocation changed the runtime's version identity")
    try require(RendererSelector.available(.dxmtMetal, runtime: runtime, architecture: .x86), "Consumers did not receive resolved payload locations")
    try require(try RuntimeLocationStore.validate(moved).windowsAvailable, "The central-runtime selector did not use the same path resolver")
    try require(try Data(contentsOf: movedFile) == originalBytes, "Loading changed portable configuration bytes")
    try require(resolved["pathFormat"] == nil, "Resolved configuration could be rebased a second time")
    try require((resolved["provenance"] as? [String: String])?["originalBuildRoot"] == original.path, "Historical provenance paths were rewritten")
    try require((resolved["engineOverrides"] as? [String: String])?["dxmtMetal"] == "d3d11,dxgi,winemetal=b", "DLL load policy was treated as a path")
    for key in ["wineBinary", "kosmicNativeICD", "immutableRuntimeSet", "sourceDependencyPrefix"] {
      try require((resolved[key] as? String)?.hasPrefix(resolvedRoot.path + "/") == true, "Operational metadata did not relocate: " + key)
    }
    var invalid = document
    for value in ["/usr/bin/true", "../wine", "engine/../wine", "engine//bin/wine", "./engine/bin/wine", "engine\\bin\\wine", ""] {
      invalid["wine"] = value
      try rejects { _ = try RuntimeConfigurationPaths.absoluteDocument(invalid, root: moved) }
    }
    invalid = document; invalid["engineDLLs"] = ["dxmtMetal": "../../outside"]
    try rejects { _ = try RuntimeConfigurationPaths.absoluteDocument(invalid, root: moved) }
    invalid = document; invalid["pathFormat"] = "future-unknown-format"
    try write(invalid, to: movedFile)
    try rejects { _ = try RuntimeConfiguration.read(movedFile) }
    try require(RuntimeConfiguration.load(movedFile).wine == nil, "Unsupported format was executed as a legacy configuration")
    try write(document, to: movedFile)
    let outside = root.appendingPathComponent("outside")
    try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: moved.appendingPathComponent("escape"), withDestinationURL: outside)
    invalid = document; invalid["wine"] = "escape/wine"
    try rejects { _ = try RuntimeConfigurationPaths.absoluteDocument(invalid, root: moved) }
    try fm.createSymbolicLink(atPath: moved.appendingPathComponent("engine/bin/current").path, withDestinationPath: "wine")
    invalid = document; invalid["wine"] = "engine/bin/current"
    let alias = try RuntimeConfigurationPaths.absoluteDocument(invalid, root: moved)
    try require(alias["wine"] as? String == runtime.wine, "An internal relative alias did not resolve")
    let fifo = root.appendingPathComponent("pipe.json")
    try require(mkfifo(fifo.path, 0o600) == 0, "Cannot prepare FIFO rejection fixture")
    try rejects { _ = try RuntimeConfiguration.read(fifo) }
    var oversized = document; oversized["padding"] = String(repeating: "x", count: 4 * 1024 * 1024)
    let huge = root.appendingPathComponent("oversized.json")
    try write(oversized, to: huge)
    try rejects { _ = try RuntimeConfiguration.read(huge) }
    let legacy = root.appendingPathComponent("legacy.json")
    try write(["wine": "/usr/bin/true", "engineDLLs": [String: String]()], to: legacy)
    try require(try RuntimeConfiguration.read(legacy).wine == "/usr/bin/true", "Existing absolute configurations changed behavior")
    try evaluationProjection(document, runtimeRoot: moved, dataRoot: root.appendingPathComponent("separate-user-data"))
  }
  private static func evaluationProjection(_ template: [String: Any], runtimeRoot: URL, dataRoot: URL) throws {
    var fragment = template
    fragment["engineDLLs"] = ["d3dMetal": "engine/pe64"]
    fragment["verifiedEngines"] = ["d3dMetal"]
    fragment["engineAPIs"] = ["d3dMetal": ["d3d12"]]
    fragment["evaluationOnlyEngines"] = ["d3dMetal"]
    fragment["evaluationModeEnabled"] = false
    fragment["appleOptional"] = ["evaluationOnly": true, "enabledForConsumerPlay": false,
      "publicRedistributionEnabled": false, "wineABIValidated": true]
    let source = runtimeRoot.appendingPathComponent("synthetic-evaluation.json")
    try write(fragment, to: source)
    let original = try Data(contentsOf: source)
    let paths = LauncherPaths(root: dataRoot)
    try paths.prepare()
    let previous = Data("{\"engineDLLs\":{},\"runtimeID\":\"previous\"}\n".utf8)
    try AtomicFile.writePrivate(previous, to: EvaluationMode.configuration(paths: paths))
    try EvaluationMode.enable(fragment: source, paths: paths)
    let enabled = try RuntimeConfiguration.read(EvaluationMode.configuration(paths: paths))
    try require(enabled.wine == runtimeRoot.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("engine/bin/wine").path, "Saved evaluation configuration was rebased into user data")
    try require(enabled.evaluationModeEnabled == true && RendererSelector.available(.d3dMetal, runtime: enabled), "Explicit evaluation policy was changed by path resolution")
    try require(try Data(contentsOf: source) == original, "Portable evaluation fragment was modified")
    try EvaluationMode.restore(paths: paths)
    try require(try Data(contentsOf: EvaluationMode.configuration(paths: paths)) == previous, "Portable activation broke exact configuration restoration")
  }
}
