// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

/// Only an explicitly versioned runtime document may contain relative paths.
/// In-memory configurations always contain absolute paths, so existing launch,
/// provider initialization and evaluation-policy code share one representation.
public enum RuntimeConfigurationPaths {
  public static let relativeFormat = "runtime-relative-v1"
  private static let scalarPaths = [
    "wine", "wineServer", "wineBoot", "kosmicICD", "moltenICD", "vulkanLibrary",
    "builtin32Directory", "wineBinary", "kosmicNativeICD", "immutableRuntimeSet",
    "sourceDependencyPrefix",
  ]
  private static let mapPaths = [
    "engineDLLs", "engineDLLs32", "engineSearchPaths", "engineWineBinaries",
    "engineWineServers", "engineBootstrap32Dirs", "engineBuiltin32Dirs",
  ]
  private static func absolute(_ value: String, root: URL) throws -> String {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"),
      !value.utf8.contains(0),
      parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { throw LauncherError.invalid("Percorso relativo del runtime non valido.") }
    return try SafePath.resolve(value, under: root).path
  }
  /// Historical source paths, hashes, version IDs, APIs and DLL overrides are
  /// deliberately not rewritten. They are not executable-location fields.
  public static func absoluteDocument(_ document: [String: Any], root: URL) throws -> [String: Any] {
    guard let format = document["pathFormat"] else { return document }
    guard let format = format as? String, format == relativeFormat else {
      throw LauncherError.invalid("Formato dei percorsi runtime non supportato.")
    }
    var result = document
    for key in scalarPaths {
      guard let value = result[key], !(value is NSNull) else { continue }
      guard let path = value as? String else {
        throw LauncherError.invalid("Campo percorso runtime non valido: " + key)
      }
      result[key] = try absolute(path, root: root)
    }
    for key in mapPaths {
      guard let value = result[key], !(value is NSNull) else { continue }
      guard let paths = value as? [String: String] else {
        throw LauncherError.invalid("Mappa dei percorsi runtime non valida: " + key)
      }
      result[key] = try paths.mapValues { try absolute($0, root: root) }
    }
    // Resolved documents may be saved elsewhere (e.g. evaluation history).
    // Retaining the relative-format tag would rebase them a second time.
    result.removeValue(forKey: "pathFormat")
    return result
  }
  public static func readDocument(_ url: URL) throws -> [String: Any] {
    guard url.isFileURL else { throw LauncherError.invalid("Configurazione runtime locale richiesta.") }
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw LauncherError.unavailable("Configurazione runtime non leggibile.") }
    defer { Darwin.close(descriptor) }
    var info = stat()
    let limit = 4 * 1024 * 1024
    guard fstat(descriptor, &info) == 0,
      info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size <= limit
    else { throw LauncherError.invalid("Configurazione runtime non regolare o troppo grande.") }
    var bytes = [UInt8](repeating: 0, count: 65_536)
    var data = Data()
    while true {
      let count = Darwin.read(descriptor, &bytes, min(bytes.count, limit + 1 - data.count))
      if count < 0 && errno == EINTR { continue }
      guard count >= 0, data.count + max(0, count) <= limit else {
        throw LauncherError.invalid("Configurazione runtime non leggibile o troppo grande.")
      }
      if count == 0 { break }
      data.append(contentsOf: bytes.prefix(count))
    }
    guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw LauncherError.invalid("Configurazione runtime non valida.")
    }
    return try absoluteDocument(document, root: url.resolvingSymlinksInPath().deletingLastPathComponent())
  }
}

extension RuntimeConfiguration {
  public static func read(_ url: URL) throws -> RuntimeConfiguration {
    let document = try RuntimeConfigurationPaths.readDocument(url)
    return try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: document))
  }
}
