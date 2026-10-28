// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct CompatibilityRule: Codable, Equatable {
  public var gameID: String
  public var wineVersion: String
  public var engines: [GraphicsEngine]
  public var verified: Bool
  public var evidence: String
  public init(
    gameID: String, wineVersion: String, engines: [GraphicsEngine], verified: Bool, evidence: String
  ) {
    self.gameID = gameID
    self.wineVersion = wineVersion
    self.engines = engines
    self.verified = verified
    self.evidence = evidence
  }
}
public enum RendererSelector {
  public static func requiredDLLs(_ engine: GraphicsEngine) -> [String] {
    switch engine {
    case .dxmtMetal: return ["d3d11.dll", "dxgi.dll", "winemetal.dll"]
    case .d3dMetal: return ["d3d11.dll", "d3d12.dll", "dxgi.dll"]
    case .dxvkKosmic, .dxvkMolten: return ["d3d11.dll", "dxgi.dll"]
    case .vkd3dKosmic: return ["d3d12.dll", "d3d12core.dll", "dxgi.dll"]
    default: return []
    }
  }
  public static func available(
    _ engine: GraphicsEngine, runtime: RuntimeConfiguration,
    architecture: BinaryArchitecture = .unknown
  ) -> Bool {
    let fm = FileManager.default
    if engine == .d3dMetal || runtime.evaluationOnlyEngines?.contains(engine.rawValue) == true,
      runtime.evaluationModeEnabled != true
    {
      return false
    }
    guard let wine = runtime.engineWineBinaries?[engine.rawValue] ?? runtime.wine,
      RuntimeExecutable.isAvailable(atPath: wine)
    else { return false }
    if architecture == .x86 {
      guard let builtin = runtime.bootstrap32Directory(engine: engine),
        fm.isReadableFile(
          atPath: URL(fileURLWithPath: builtin).appendingPathComponent("kernel32.dll").path)
      else { return false }
    }
    switch engine {
    case .automatic: return false
    case .wineD3D: return true
    case .dxvkKosmic, .vkd3dKosmic, .vulkanKosmic:
      guard let icd = runtime.kosmicICD, fm.fileExists(atPath: icd) else { return false }
    case .dxvkMolten, .vulkanMolten:
      guard let icd = runtime.moltenICD, fm.fileExists(atPath: icd) else { return false }
    case .dxmtMetal, .d3dMetal: break
    }
    if [.dxmtMetal, .d3dMetal, .dxvkKosmic, .dxvkMolten, .vkd3dKosmic].contains(engine) {
      let payload = architecture == .x86 ? runtime.engineDLLs32 : runtime.engineDLLs
      guard let directory = payload?[engine.rawValue],
        requiredDLLs(engine).allSatisfy({
          fm.isReadableFile(atPath: URL(fileURLWithPath: directory).appendingPathComponent($0).path)
        })
      else { return false }
    }
    return true
  }
  /// Fallback is evaluated between launches. Never hot-swap DLLs in a running prefix.
  public static func select(
    game: Game, runtime: RuntimeConfiguration, rules: [CompatibilityRule],
    failed: Set<GraphicsEngine> = [], architecture: BinaryArchitecture = .unknown
  ) throws -> GraphicsEngine {
    if game.engine != .automatic {
      if game.engine == .d3dMetal
        || runtime.evaluationOnlyEngines?.contains(game.engine.rawValue) == true,
        runtime.evaluationModeEnabled != true
      {
        throw LauncherError.unavailable(
          "Questo runtime è riservato alla valutazione esplicita dei giochi e richiede i componenti e la licenza del fornitore. Non è abilitato per il gioco ordinario."
        )
      }
      guard available(game.engine, runtime: runtime, architecture: architecture) else {
        throw LauncherError.unavailable("Il motore scelto non è installato per questo runtime.")
      }
      return game.engine
    }
    let verified = Set(runtime.verifiedEngines ?? [])
    let requiredAPI: String? = {
      if case .string(let api) = game.metadata?["graphicsAPI"] { return api }
      return nil
    }()
    func supportsRequiredAPI(_ engine: GraphicsEngine) -> Bool {
      // A successful PE64 probe does not certify the PE32 route. Advanced manual
      // overrides may still try an available experimental payload explicitly.
      if architecture == .x86,
        !(runtime.engineArchitectures?[engine.rawValue]?.contains("i386") == true
          || runtime.engineArchitectures?[engine.rawValue]?.contains("x86") == true)
      {
        return false
      }
      guard let api = requiredAPI else { return true }
      return runtime.engineAPIs?[engine.rawValue]?.contains(api) == true
    }
    let candidates = rules.filter {
      $0.gameID == game.id && $0.wineVersion == runtime.runtimeIdentity && $0.verified
        && !$0.evidence.isEmpty
    }.flatMap { $0.engines }
    if let selected = candidates.first(where: {
      !failed.contains($0) && verified.contains($0.rawValue) && supportsRequiredAPI($0)
        && available($0, runtime: runtime, architecture: architecture)
    }) {
      return selected
    }
    // A detected/imported API can use a verified generic path, but is not mislabelled as game-specific validation.
    let api = game.metadata?["graphicsAPI"]
    let generic: [GraphicsEngine]
    switch api {
    case .string("d3d12"): generic = [.d3dMetal, .vkd3dKosmic]
    case .string("d3d11"): generic = [.dxmtMetal, .d3dMetal, .dxvkKosmic, .dxvkMolten, .wineD3D]
    case .string("vulkan"): generic = [.vulkanKosmic, .vulkanMolten]
    default: generic = [.dxmtMetal, .d3dMetal, .wineD3D]
    }
    if let engine = generic.first(where: {
      verified.contains($0.rawValue) && supportsRequiredAPI($0) && !failed.contains($0)
        && available($0, runtime: runtime, architecture: architecture)
    }) {
      return engine
    }
    if requiredAPI == "d3d12", runtime.evaluationModeEnabled != true {
      throw LauncherError.unavailable(
        "Nessun percorso DX12 verificato è disponibile per questo gioco e runtime. Il percorso Apple resta separato e riservato alla valutazione."
      )
    }
    throw LauncherError.unavailable(
      "Nessun percorso grafico disponibile e verificato per questa API/versione. Il launcher non combina automaticamente DLL incompatibili."
    )
  }
}
