// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherCore

enum EvaluationModeChecks {
  static func validate() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(
      "ready-evaluation-mode-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    func require(_ value: Bool, _ message: String) throws {
      if !value { throw LauncherError.failed(message) }
    }
    func rejects(_ operation: () throws -> Void) throws {
      do { try operation() } catch { return }
      throw LauncherError.failed("Evaluation policy unexpectedly accepted an invalid activation")
    }
    let payload = root.appendingPathComponent("fixture-dlls")
    try fm.createDirectory(at: payload, withIntermediateDirectories: true)
    for name in RendererSelector.requiredDLLs(.d3dMetal) {
      try Data("fixture".utf8).write(to: payload.appendingPathComponent(name))
    }
    var object: [String: Any] = [
      "wine": "/usr/bin/true", "engineDLLs": ["d3dMetal": payload.path],
      "verifiedEngines": ["d3dMetal"], "engineAPIs": ["d3dMetal": ["d3d12"]],
      "evaluationOnlyEngines": ["d3dMetal"], "evaluationModeEnabled": false,
      "appleOptional": [
        "evaluationOnly": true, "enabledForConsumerPlay": false,
        "publicRedistributionEnabled": false, "wineABIValidated": true,
      ],
    ]
    let fragment = root.appendingPathComponent("fragment.json")
    let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try bytes.write(to: fragment)
    let paths = LauncherPaths(root: root.appendingPathComponent("custom-state"))
    try paths.prepare()
    let previous = Data(
      "{\"wine\":\"/usr/bin/true\",\"engineDLLs\":{},\"runtimeID\":\"previous-custom\"}\n".utf8)
    try AtomicFile.writePrivate(previous, to: EvaluationMode.configuration(paths: paths))
    try EvaluationMode.enable(fragment: fragment, paths: paths)
    let active = RuntimeConfiguration.load(EvaluationMode.configuration(paths: paths))
    try require(
      active.evaluationModeEnabled == true
        && RendererSelector.available(.d3dMetal, runtime: active),
      "Explicit activation was not applied")
    try require(EvaluationMode.hasRestorePoint(paths: paths), "Previous runtime was not retained")
    try rejects { try EvaluationMode.enable(fragment: fragment, paths: paths) }
    try require(try Data(contentsOf: fragment) == bytes, "Activation modified its source fragment")
    let permissions =
      try fm.attributesOfItem(atPath: EvaluationMode.configuration(paths: paths).path)[
        .posixPermissions] as! NSNumber
    try require(permissions.intValue & 0o777 == 0o600, "Runtime configuration was not private")
    try EvaluationMode.restore(paths: paths)
    try require(
      try Data(contentsOf: EvaluationMode.configuration(paths: paths)) == previous,
      "Restore did not preserve exact original configuration bytes")
    try require(!EvaluationMode.hasRestorePoint(paths: paths), "Restore did not complete")
    let fresh = LauncherPaths(root: root.appendingPathComponent("fresh-state"))
    try EvaluationMode.enable(fragment: fragment, paths: fresh)
    try EvaluationMode.restore(paths: fresh)
    try require(
      !fm.fileExists(atPath: EvaluationMode.configuration(paths: fresh).path),
      "Fresh state did not return to default lookup")
    let history = fresh.runtimes.appendingPathComponent("EvaluationHistory")
    try require(
      (try fm.contentsOfDirectory(atPath: history.path)).count == 1,
      "Evaluation history was deleted")
    object["appleOptional"] = [
      "evaluationOnly": true, "enabledForConsumerPlay": true, "publicRedistributionEnabled": false,
      "wineABIValidated": true,
    ]
    try JSONSerialization.data(withJSONObject: object).write(to: fragment)
    try rejects { try EvaluationMode.enable(fragment: fragment, paths: fresh) }
    try require(
      !fm.fileExists(atPath: EvaluationMode.configuration(paths: fresh).path),
      "Rejected license policy changed runtime settings")
    let unsafe = LauncherPaths(root: root.appendingPathComponent("symlink-state"))
    try fm.createDirectory(at: unsafe.root, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: unsafe.runtimes, withDestinationURL: paths.runtimes)
    try rejects { try EvaluationMode.enable(fragment: fragment, paths: unsafe) }
    try require(
      try Data(contentsOf: EvaluationMode.configuration(paths: paths)) == previous,
      "Symlink activation changed another root")
  }
}
