// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherCore

/// Presentation never turns an opaque package entitlement into a named game.
/// Non-game records and installation data remain in the repository; the unified
/// games view excludes them without deleting entitlement or storage data.
enum LibraryEntryPresentation {
  static func kind(_ game:Game)->String? {
    guard game.store == .steam else{return nil}
    for key in ["libraryKind","contentType"] {
      guard let raw=game.metadata?[key]?.foundation as?String else{continue}
      let value=raw.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
      if ["game","demo","application","dlc","tool","runtime","support","music","video","config","unknown"].contains(value){return value}
      if value=="software"{return "application"};if value=="mod"{return "game"}
    }
    return nil
  }
  static func isOtherContent(_ game:Game)->Bool {
    guard game.store == .steam else{return false}
    if let kind=kind(game){return !["game","demo","application"].contains(kind)}
    // Preserve named legacy games until an authoritative classification arrives.
    let title=game.title.trimmingCharacters(in:.whitespacesAndNewlines)
    return (title.isEmpty || title==game.storeID || title=="Contenuto Steam · informazioni non disponibili" || title=="Contenuto Steam non identificato" || title=="Gioco Steam · informazioni non disponibili") || game.metadata?["contentInfoUnavailable"] == .bool(true)
  }
  static func title(_ game:Game)->String {
    let value=game.title.trimmingCharacters(in:.whitespacesAndNewlines)
    if value.isEmpty || (game.store == .steam && value==game.storeID){return "Contenuto Steam non identificato"}
    return value
  }
  static func unavailableDescription(_ game:Game)->String {
    if isOtherContent(game){return "Questo elemento appartiene al catalogo delle licenze Steam. Le informazioni di un gioco autonomo non sono disponibili; i dati e le eventuali installazioni sono conservati."}
    return "Descrizione non disponibile nelle informazioni Steam ricevute. I dati già presenti sono conservati."
  }
}
