// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum LocalDiscovery {
  public static func importGame(_ url: URL) throws -> Game {
    let isApp = url.pathExtension.lowercased() == "app"
    let exe = isApp ? ArchitectureProbe.applicationExecutable(url) : url
    guard let exe,
      FileManager.default.isExecutableFile(atPath: exe.path)
        || exe.pathExtension.lowercased() == "exe"
    else { throw LauncherError.invalid("Seleziona un’app macOS o un eseguibile Windows.") }
    let arch = try ArchitectureProbe.inspect(exe)
    let platform: GamePlatform = exe.pathExtension.lowercased() == "exe" ? .windows : .macOS
    let variant = GameVariant(
      id: platform.rawValue, platform: platform, architecture: arch, executable: exe.path,
      installationRoot: isApp ? url.path : exe.deletingLastPathComponent().path,
      installed: true, verification: "Header del binario locale verificato")
    var game = Game(
      id: "local:" + UUID().uuidString, store: .local, storeID: exe.path,
      title: url.deletingPathExtension().lastPathComponent, variants: [variant])
    PEImports.annotate(&game, variant: variant)
    return game
  }
  public static func steamLibraries(home: URL = FileManager.default.homeDirectoryForCurrentUser)
    throws -> [Game]
  {
    let steam = home.appendingPathComponent("Library/Application Support/Steam")
    var roots = [steam]
    let folders = steam.appendingPathComponent("steamapps/libraryfolders.vdf")
    if let s = try? String(contentsOf: folders),
      let obj = try? KeyValues.parse(s)["libraryfolders"]?.object
    {
      for (_, entry) in obj {
        if let path = entry["path"]?.string { roots.append(URL(fileURLWithPath: path)) }
      }
    }
    var games = [Game]()
    var seen = Set<String>()
    for root in roots {
      let apps = root.appendingPathComponent("steamapps")
      for manifest
        in (try? FileManager.default.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil))
        ?? []
      where manifest.lastPathComponent.hasPrefix("appmanifest_") && manifest.pathExtension == "acf"
      {
        guard let s = try? String(contentsOf: manifest),
          let kv = try? KeyValues.parse(s)["AppState"], let id = kv["appid"]?.string,
          let name = kv["name"]?.string, let dir = kv["installdir"]?.string, !seen.contains(id)
        else { continue }
        let gameDir = try SafePath.resolve(dir, under: apps.appendingPathComponent("common"))
        let enumr = FileManager.default.enumerator(
          at: gameDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var variants = [GameVariant]()
        var scanned = 0
        while let file = enumr?.nextObject() as? URL, scanned < 4000 {
          scanned += 1
          if file.pathExtension == "app" {
            enumr?.skipDescendants()
            if let exe = ArchitectureProbe.applicationExecutable(file),
              let a = try? ArchitectureProbe.inspect(exe)
            {
              variants.append(
                .init(
                  id: "mac:" + file.lastPathComponent, platform: .macOS, architecture: a,
                  executable: exe.path, installationRoot: gameDir.path, installed: true,
                  verification: "Binario installato verificato"))
            }
          }
          if file.pathExtension.lowercased() == "exe",
            !file.lastPathComponent.lowercased().contains("unins")
          {
            variants.append(
              .init(
                id: "win:" + file.lastPathComponent, platform: .windows,
                architecture: (try? ArchitectureProbe.inspect(file)) ?? .unknown,
                executable: file.path, installationRoot: gameDir.path, installed: true,
                verification: "Eseguibile trovato; conferma il programma di avvio"))
          }
        }
        seen.insert(id)
        games.append(
          Game(
            id: "steam:" + id, store: .steam, storeID: id, title: name,
            artworkURL:
              "https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/library_600x900.jpg",
            variants: variants))
      }
    }
    return games.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
  }
}
