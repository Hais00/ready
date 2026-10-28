// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherCore

enum EngineTransactionChecks {
  private enum Failure: Error { case interrupted, failed(String) }
  private static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure.failed(message) }
  }
  private static func rejects(_ label: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw Failure.failed(label)
  }
  private static func interruptedAtCheckpoint(_ body: () throws -> Void) throws {
    do { try body() }
    catch Failure.interrupted { return }
    catch { throw error }
    throw Failure.failed("Expected the named post-projection checkpoint")
  }
  static func validate() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("ready-engine-intent-" + UUID().uuidString).resolvingSymlinksInPath()
    let paths = LauncherPaths(root: root)
    try paths.prepare(); defer { try? fm.removeItem(at: root) }
    let old64 = root.appendingPathComponent("old64"), old32 = root.appendingPathComponent("old32")
    let next64 = root.appendingPathComponent("next64"), next32 = root.appendingPathComponent("next32")
    for (folder, label, names) in [(old64, "old64", ["d3d11.dll", "dxgi.dll"]), (old32, "old32", ["d3d11.dll", "dxgi.dll"]), (next64, "next64", ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "winemetal.dll"]), (next32, "next32", ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "winemetal.dll"])] {
      try fm.createDirectory(at: folder, withIntermediateDirectories: true)
      for name in names { try Data((label + ":" + name).utf8).write(to: folder.appendingPathComponent(name)) }
    }
    var runtime = RuntimeConfiguration(engineDLLs: ["dxvkKosmic": old64.path, "dxmtMetal": next64.path])
    runtime.engineDLLs32 = ["dxvkKosmic": old32.path, "dxmtMetal": next32.path]
    for interruptedSystem in ["system32", "syswow64"] {
      let owner = UUID(), game = "fixture-" + interruptedSystem
      let lease = try PrefixLease(paths: paths, profile: owner, gameID: game)
      try withExtendedLifetime(lease) {
        let prefix = try PrefixManager(paths: paths).prepare(profile: owner, gameID: game)
        try AtomicFile.writePrivate(Data("Synthetic only".utf8), to: prefix.appendingPathComponent(".ready-synthetic-engine"))
        for system in ["system32", "syswow64"] {
          let folder = prefix.appendingPathComponent("drive_c/windows/" + system)
          try fm.createDirectory(at: folder, withIntermediateDirectories: true)
          for name in ["d3d10core.dll", "d3d11.dll", "dxgi.dll"] { try Data(("pure-" + system + ":" + name).utf8).write(to: folder.appendingPathComponent(name)) }
        }
        try EngineInstaller.prepareForRuntimeChange("same-runtime", prefix: prefix)
        try EngineInstaller.configure(.dxvkKosmic, runtime: runtime, paths: paths, prefix: prefix)
        let target = prefix.appendingPathComponent("drive_c/windows/" + interruptedSystem)
        let custom = target.appendingPathComponent("d3d11.dll")
        try Data("custom-before".utf8).write(to: custom)
        try interruptedAtCheckpoint {
          try EngineInstaller.configureFixture(.dxmtMetal, runtime: runtime, paths: paths, prefix: prefix) { system, name in
            if system == interruptedSystem && name == "winemetal.dll" { throw Failure.interrupted }
          }
        }
        let stateName = interruptedSystem == "system32" ? "managed-dlls" : "managed-dlls32"
        let pending = prefix.appendingPathComponent(".ready/" + stateName + ".intent.json")
        try require(fm.fileExists(atPath: pending.path), "Intent survives interruption")
        let ledger = try JSONDecoder().decode([String].self, from: Data(contentsOf: prefix.appendingPathComponent(".ready/" + stateName + ".json")))
        try require(ledger.contains("winemetal.dll"), "New filename recorded before final manifest commit")
        try Data("custom-after-crash".utf8).write(to: target.appendingPathComponent("winemetal.dll"))
        // Version marker is deliberately unchanged: recovery must run before early return.
        try EngineInstaller.prepareForRuntimeChange("same-runtime", prefix: prefix)
        try require(!fm.fileExists(atPath: pending.path), "Recovered intent archived")
        try require(try String(contentsOf: custom) == "custom-before", "Exact pre-swap custom DLL restored")
        try require(!fm.fileExists(atPath: target.appendingPathComponent("winemetal.dll").path), "New previously absent DLL cannot remain untracked")
        var retainedPostCrash = false
        let entries = fm.enumerator(at: prefix.appendingPathComponent(".ready/EngineTransactions"), includingPropertiesForKeys: [.isRegularFileKey])
        while let file = entries?.nextObject() as? URL {
          if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
            (try? Data(contentsOf: file)) == Data("custom-after-crash".utf8) { retainedPostCrash = true }
        }
        try require(retainedPostCrash, "Post-crash custom bytes preserved separately")
        try EngineInstaller.configure(.wineD3D, runtime: runtime, paths: paths, prefix: prefix)
        for system in ["system32", "syswow64"] {
          let folder = prefix.appendingPathComponent("drive_c/windows/" + system)
          try require(!fm.fileExists(atPath: folder.appendingPathComponent("winemetal.dll").path), "Engine change removes tracked new DLL in each architecture")
          try require(try String(contentsOf: folder.appendingPathComponent("d3d11.dll")) == "pure-" + system + ":d3d11.dll", "Matching pure Wine original restored")
        }
        try interruptedAtCheckpoint {
          try EngineInstaller.configureFixture(.dxmtMetal, runtime: runtime, paths: paths, prefix: prefix) { system, name in
            if system == interruptedSystem && name == "winemetal.dll" { throw Failure.interrupted }
          }
        }
        let validIntent = try Data(contentsOf: pending)
        var invalidIntent = try JSONSerialization.jsonObject(with: validIntent) as! [String: Any]
        invalidIntent["names"] = ["../outside.dll"]
        try AtomicFile.writePrivate(JSONSerialization.data(withJSONObject: invalidIntent), to: pending)
        let untouched = try Data(contentsOf: target.appendingPathComponent("d3d11.dll"))
        try rejects("Corrupt journal must not be guessed or discarded") { try EngineInstaller.recoverInterrupted(prefix: prefix) }
        try require(try Data(contentsOf: target.appendingPathComponent("d3d11.dll")) == untouched && fm.fileExists(atPath: pending.path), "Corrupt intent retains files and journal")
        try AtomicFile.writePrivate(validIntent, to: pending)
        try EngineInstaller.recoverInterrupted(prefix: prefix)
        try EngineInstaller.configure(.wineD3D, runtime: runtime, paths: paths, prefix: prefix)
        let state = prefix.appendingPathComponent(".ready/managed-dlls.json")
        try Data("invalid manifest".utf8).write(to: state)
        let before = try Data(contentsOf: target.appendingPathComponent("d3d11.dll"))
        try rejects("Corrupt manifest must fail before unchanged marker return") { try EngineInstaller.prepareForRuntimeChange("same-runtime", prefix: prefix) }
        try rejects("Corrupt manifest must not become an empty list") { try EngineInstaller.configure(.dxmtMetal, runtime: runtime, paths: paths, prefix: prefix) }
        try require(try Data(contentsOf: target.appendingPathComponent("d3d11.dll")) == before, "Corrupt metadata leaves DLLs unchanged")
        try fm.removeItem(at: state)
        try fm.createSymbolicLink(atPath: state.path, withDestinationPath: state.lastPathComponent)
        try rejects("A self-linked manifest is not an absent manifest") { try EngineInstaller.prepareForRuntimeChange("same-runtime", prefix: prefix) }
        try require(try Data(contentsOf: target.appendingPathComponent("d3d11.dll")) == before, "Linked corrupt manifest leaves DLLs unchanged")
      }
    }
    do {
      let owner = UUID()
      let lease = try PrefixLease(paths: paths, profile: owner, gameID: "directory-alias")
      try withExtendedLifetime(lease) {
        let prefix = try PrefixManager(paths: paths).prepare(profile: owner, gameID: "directory-alias")
        try EngineInstaller.prepareForRuntimeChange("old", prefix: prefix)
        try EngineInstaller.configure(.dxvkKosmic, runtime: runtime, paths: paths, prefix: prefix)
        let system = prefix.appendingPathComponent("drive_c/windows/system32")
        try fm.moveItem(at: system, to: prefix.appendingPathComponent("system32-before-alias"))
        let outside = root.appendingPathComponent("external-system")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let externalDLL = outside.appendingPathComponent("d3d11.dll")
        try Data("external immutable".utf8).write(to: externalDLL)
        try fm.createSymbolicLink(at: system, withDestinationURL: outside)
        try rejects("Runtime change must reject redirected system32 before moving files") { try EngineInstaller.prepareForRuntimeChange("new", prefix: prefix) }
        try require(try String(contentsOf: externalDLL) == "external immutable", "External directory DLL unchanged")
        try require(try String(contentsOf: prefix.appendingPathComponent(".ready/dll-runtime-version")) == "old", "Unsafe directory does not advance runtime marker")
      }
    }
    try require(try String(contentsOf: next64.appendingPathComponent("winemetal.dll")) == "next64:winemetal.dll", "Central payload immutable")
    try require(try String(contentsOf: next32.appendingPathComponent("winemetal.dll")) == "next32:winemetal.dll", "Central PE32 payload immutable")
  }
}
