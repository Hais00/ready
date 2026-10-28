import Darwin
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Explicit local development/evaluation mode. This changes configuration, never
/// accepts vendor terms, grants rights, or copies proprietary files into a bundle.
public enum EvaluationMode {
  private struct Session: Codable {
    var id: UUID
    var hadPrevious: Bool
  }
  public static func configuration(paths: LauncherPaths) -> URL {
    paths.runtimes.appendingPathComponent("runtime.json")
  }
  private static func index(paths: LauncherPaths) -> URL {
    paths.runtimes.appendingPathComponent("active-evaluation.json")
  }
  public static func hasRestorePoint(paths: LauncherPaths) -> Bool {
    FileManager.default.fileExists(atPath: index(paths: paths).path)
  }
  private static func readObject(_ data: Data) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw LauncherError.invalid("Configurazione runtime non valida.")
    }
    return value
  }
  private static func prepare(paths: LauncherPaths) throws {
    try paths.prepare()
    let attributes = try FileManager.default.attributesOfItem(atPath: paths.runtimes.path)
    guard (try? FileManager.default.destinationOfSymbolicLink(atPath: paths.runtimes.path)) == nil,
      attributes[.type] as? FileAttributeType == .typeDirectory,
      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
    else {
      throw LauncherError.invalid(
        "La configurazione runtime deve appartenere a questo utente e non può essere un collegamento."
      )
    }
  }
  public static func enable(fragment: URL, paths: LauncherPaths) throws {
    try prepare(paths: paths)
    guard FileManager.default.isReadableFile(atPath: fragment.path) else {
      throw LauncherError.unavailable(
        "Il runtime Apple non è ancora installato e verificato localmente. I componenti proprietari non sono inclusi nel launcher."
      )
    }
    guard !hasRestorePoint(paths: paths) else {
      throw LauncherError.invalid(
        "Ripristina la precedente configurazione di valutazione prima di attivarne un’altra.")
    }
    var object = try RuntimeConfigurationPaths.readDocument(fragment)
    guard let policy = object["appleOptional"] as? [String: Any],
      policy["evaluationOnly"] as? Bool == true,
      policy["enabledForConsumerPlay"] as? Bool == false,
      policy["publicRedistributionEnabled"] as? Bool == false,
      policy["wineABIValidated"] as? Bool == true
    else {
      throw LauncherError.invalid(
        "È richiesto un runtime locale verificato, separato e riservato alla valutazione.")
    }
    object["evaluationModeEnabled"] = true
    let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let runtime = try JSONDecoder().decode(RuntimeConfiguration.self, from: bytes)
    guard (runtime.verifiedEngines ?? []).contains(GraphicsEngine.d3dMetal.rawValue),
      runtime.engineAPIs?[GraphicsEngine.d3dMetal.rawValue]?.contains("d3d12") == true,
      RendererSelector.available(.d3dMetal, runtime: runtime)
    else {
      throw LauncherError.unavailable(
        "Il runtime di valutazione non è disponibile o non ha superato le verifiche locali.")
    }
    let fm = FileManager.default
    let target = configuration(paths: paths)
    let session = Session(id: UUID(), hadPrevious: fm.fileExists(atPath: target.path))
    let history = try SafePath.resolve(
      "EvaluationHistory/" + session.id.uuidString, under: paths.runtimes)
    try fm.createDirectory(
      at: history, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    if session.hadPrevious {
      try AtomicFile.writePrivate(
        Data(contentsOf: target), to: history.appendingPathComponent("previous-runtime.json"))
    }
    try AtomicFile.writePrivate(
      bytes, to: history.appendingPathComponent("evaluation-runtime.json"))
    try AtomicFile.writePrivate(JSONEncoder().encode(session), to: index(paths: paths))
    // A crash before/after this write can always restore through the index above.
    try AtomicFile.writePrivate(bytes, to: target)
  }
  public static func restore(paths: LauncherPaths) throws {
    try prepare(paths: paths)
    let fm = FileManager.default
    let record = index(paths: paths)
    let target = configuration(paths: paths)
    if fm.fileExists(atPath: record.path) {
      let session = try JSONDecoder().decode(Session.self, from: Data(contentsOf: record))
      let history = try SafePath.resolve(
        "EvaluationHistory/" + session.id.uuidString, under: paths.runtimes)
      if fm.fileExists(atPath: target.path) {
        try AtomicFile.writePrivate(
          Data(contentsOf: target),
          to: history.appendingPathComponent("restored-from-" + UUID().uuidString + ".json"))
      }
      if session.hadPrevious {
        try AtomicFile.writePrivate(
          Data(contentsOf: history.appendingPathComponent("previous-runtime.json")), to: target)
      } else if fm.fileExists(atPath: target.path) {
        try fm.removeItem(at: target)  // Our generated configuration is retained in history.
      }
      try fm.removeItem(at: record)
    } else if fm.fileExists(atPath: target.path) {
      // A manually configured evaluation mode has no automatic prior snapshot.
      // Disable only the flag and retain every other setting and the old bytes.
      let original = try Data(contentsOf: target)
      var object = try readObject(original)
      let history = try SafePath.resolve(
        "EvaluationHistory/" + UUID().uuidString, under: paths.runtimes)
      try fm.createDirectory(
        at: history, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try AtomicFile.writePrivate(
        original, to: history.appendingPathComponent("previous-runtime.json"))
      object["evaluationModeEnabled"] = false
      try AtomicFile.writePrivate(
        JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), to: target)
    }
  }
}
