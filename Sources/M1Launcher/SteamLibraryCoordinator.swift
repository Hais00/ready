// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreFoundation
import LauncherCore

/// Remote membership is scoped to an account/profile. Local installation and
/// preference records remain in place even when that membership is removed.
enum SteamLibraryMerge {
  static let ownersKey = "readySteamCatalogOwners"
  private static let catalogKeys:Set<String>=["shortDescription","description","releaseDate","storeURL","iconURL","capsuleURL","heroURL","bannerURL","developers","publishers","genres","downloadableVariants","metadataComplete","title","contentType","artworkFallbacksUnverified"]
  private static func owners(_ game: Game) -> [String: JSONValue] {
    if case .object(let value) = game.metadata?[ownersKey] { return value }; return [:]
  }
  private static func local(_ game: Game) -> Bool {
    game.variants.contains { $0.installed || $0.executable != nil || $0.installationRoot != nil }
  }
  static func clearRemoteMembership(in state: inout LibraryState, profile: UUID) {
    let key = profile.uuidString
    for index in state.games.indices where state.games[index].store == .steam {
      var game = state.games[index], values = owners(state.games[index])
      let tracked = values.removeValue(forKey: key) != nil
      // Legacy uninstalled remote catalog entries predate the account marker.
      if tracked || (!local(game) && game.profileIDs?.contains(profile) == true) {
        if let ids = game.profileIDs { game.profileIDs = ids.filter { $0 != profile } }
        if game.metadata == nil { game.metadata = [:] }
        game.metadata?[ownersKey] = .object(values)
        state.games[index] = game
      }
    }
  }
  static func clearOtherAccountMembership(in state: inout LibraryState, profile: UUID, account: String) {
    for index in state.games.indices where state.games[index].store == .steam {
      var game = state.games[index], values = owners(state.games[index])
      guard case .string(let oldAccount) = values[profile.uuidString], oldAccount != account else { continue }
      values.removeValue(forKey:profile.uuidString)
      if let ids=game.profileIDs { game.profileIDs=ids.filter{$0 != profile} }
      game.metadata?[ownersKey] = .object(values);state.games[index]=game
    }
  }
  static func apply(_ incoming: [Game], to state: inout LibraryState, profile: UUID, account: String) {
    clearRemoteMembership(in: &state, profile: profile)
    var seen = Set<String>()
    for remote in incoming where remote.store == .steam {
      guard let app = UInt32(remote.storeID), app > 0, String(app) == remote.storeID,
        seen.insert(remote.storeID).inserted else { continue }
      var game = remote
      // The service describes availability; it cannot grant executable paths.
      game.variants = remote.variants.map { variant in
        var v = variant; v.installed = false; v.executable = nil
        v.installationRoot = nil; v.workingDirectory = nil; v.arguments = []; return v
      }
      game.controllerInputMode = nil
      if let index = state.games.firstIndex(where: { $0.store == .steam && $0.storeID == game.storeID }) {
        let old = state.games[index]
        if !placeholderTitle(old){game.title=old.title}
        game.id = old.id; game.engine = old.engine; game.selectedVariant = old.selectedVariant
        game.lastPlayed = old.lastPlayed
        game.saveRules = old.saveRules + remote.saveRules.filter { !old.saveRules.contains($0) }
        let localIDs = Set(old.variants.map(\.id))
        game.variants = old.variants + game.variants.filter { incoming in
          !localIDs.contains(incoming.id) && !(incoming.architecture == .unknown && old.variants.contains{$0.platform==incoming.platform})
        }
        var metadata = old.metadata ?? [:]
        let keepRichCatalog = metadata["metadataComplete"] == .bool(true) && remote.metadata?["metadataComplete"] != .bool(true)
        for (key, value) in remote.metadata ?? [:] where key != ownersKey {
          // PICS still refreshes launch/depot fields. Its catalog placeholders
          // must not erase an already completed public metadata response.
          if keepRichCatalog,catalogKeys.contains(key),metadata[key] != nil{continue}
          metadata[key] = value
        }
        if keepRichCatalog,let artwork=old.artworkURL,!artwork.isEmpty{game.artworkURL=artwork}
        game.metadata = metadata
        // Shared discovered installations retain their original visibility.
        game.profileIDs = old.profileIDs == nil && local(old) ? nil : Array(Set((old.profileIDs ?? []) + [profile]))
        var values = owners(old); values[profile.uuidString] = .string(account)
        game.metadata?[ownersKey] = .object(values)
        state.games[index] = game
      } else {
        game.profileIDs = [profile]
        var metadata = game.metadata ?? [:]; metadata[ownersKey] = .object([profile.uuidString: .string(account)])
        game.metadata = metadata; state.games.append(game)
      }
    }
  }
  static func placeholderTitle(_ game:Game)->Bool {
    let title=game.title.trimmingCharacters(in:.whitespacesAndNewlines)
    return title.isEmpty || title==game.storeID
  }
  private static func hasArtwork(_ game:Game)->Bool {
    let values=[game.artworkURL,game.metadata?["capsuleURL"]?.foundation as?String,game.metadata?["iconURL"]?.foundation as?String]
    return values.compactMap{$0}.contains{URL(string:$0)?.scheme=="https"}
  }
  static func needsPublicRepair(_ game:Game)->Bool {
    guard game.store == .steam,let app=UInt32(game.storeID),app>0,String(app)==game.storeID else{return false}
    return placeholderTitle(game) || !hasArtwork(game) || game.variants.isEmpty
  }
  /// Candidate URLs only. No image existence or entitlement is inferred.
  static func addArtworkFallback(gameID:String,in state:inout LibraryState)->Bool {
    guard let app=UInt32(gameID),app>0,String(app)==gameID,
      let index=state.games.firstIndex(where:{$0.store == .steam && $0.storeID==gameID}),!hasArtwork(state.games[index]) else{return false}
    var metadata=state.games[index].metadata ?? [:]
    let base="https://cdn.akamai.steamstatic.com/steam/apps/\(gameID)/"
    metadata["capsuleURL"] = .string(base+"library_600x900.jpg")
    if (metadata["bannerURL"]?.foundation as?String).flatMap({URL(string:$0)})?.scheme != "https" { metadata["bannerURL"] = .string(base+"header.jpg") }
    metadata["artworkFallbacksUnverified"] = .bool(true)
    state.games[index].metadata=metadata;state.games[index].artworkURL=base+"library_600x900.jpg"
    return true
  }
  static func enrich(_ metadata: [String: JSONValue], gameID: String, in state: inout LibraryState) {
    guard let index = state.games.firstIndex(where: { $0.store == .steam && $0.storeID == gameID }) else { return }
    var combined = state.games[index].metadata ?? [:]
    for (key, value) in metadata where catalogKeys.contains(key) { combined[key] = value }
    state.games[index].metadata = combined
    if placeholderTitle(state.games[index]),case .string(let raw)=metadata["title"] {
      let title=String(raw.unicodeScalars.filter{!CharacterSet.controlCharacters.contains($0)}).trimmingCharacters(in:.whitespacesAndNewlines)
      if !title.isEmpty {state.games[index].title=String(title.prefix(256))}
    }
    addAvailability(metadata,at:index,in:&state)
    if case .string(let image) = metadata["capsuleURL"], URL(string: image)?.scheme == "https" {
      state.games[index].artworkURL = image
    }
  }
  /// Upgrade cached public metadata without any service, credential or network
  /// request. Bound startup work and report whether one repository save is due.
  static func projectCachedAvailability(in state:inout LibraryState)->Bool {
    var changed=false
    for index in state.games.indices.prefix(20000) where state.games[index].store == .steam {
      guard let metadata=state.games[index].metadata else{continue}
      let count=state.games[index].variants.count
      addAvailability(metadata,at:index,in:&state)
      if state.games[index].variants.count != count{changed=true}
    }
    return changed
  }
  private static func addAvailability(_ metadata:[String:JSONValue],at index:Int,in state:inout LibraryState) {
    // Public platform availability is not installation or account ownership.
    // Keep every local variant intact and use the PICS platform ID convention.
    if case .array(let offered) = metadata["downloadableVariants"] {
      for case .string(let raw) in offered {
        guard let platform=GamePlatform(rawValue:raw),
          !state.games[index].variants.contains(where:{$0.platform==platform || $0.id==raw}) else{continue}
        state.games[index].variants.append(GameVariant(id:raw,platform:platform,architecture:.unknown,
          installed:false,verification:"Disponibilità Steam; architettura da verificare dopo l’installazione"))
      }
    }
  }

}

@MainActor
final class SteamLibraryCoordinator {
  typealias Event = ([String: Any]) -> Void
  let profile: UUID
  private let network: SteamClientSession
  private var generation = UUID()
  private var account: String?
  private var online = false
  private var synced = false
  private var refreshRequested = false
  private var libraryRequest: String?
  private var libraryFlight: UUID?
  private var details = [String: [Event]]()
  private var detailRequests = [String: String]()
  private var cachedDetails = [String: [String: Any]]()
  private var metadataQueue=[String](),activeMetadata=Set<String>(),repairAttempted=Set<String>()
  private var knownNetworkGeneration:UUID
  var onScopeChanged:(()->Void)?
  var onAccountChanged: ((String) -> Void)?
  var onGames: (([Game], String) -> Void)?
  var onError: ((String) -> Void)?
  init(profile: UUID, network: SteamClientSession) { self.profile = profile; self.network = network;knownNetworkGeneration=network.generation }
  func observe(_ state: SteamClientState) {
    if knownNetworkGeneration != network.generation {
      knownNetworkGeneration=network.generation;invalidateRequests();account=nil;synced=false;if network.serviceRunning{onScopeChanged?()}
    }
    let wasOnline = online; online = state.online
    guard state.online, network.accountReadyForGame(), !state.steamID.isEmpty else {
      if !state.online {
        synced=false
        if wasOnline {let id=libraryRequest;libraryRequest=nil;libraryFlight=nil;if let id{network.cancel(id)}}
      }
      return
    }
    if account != state.steamID {
      invalidateRequests(); account = state.steamID; synced = false; onAccountChanged?(state.steamID);onScopeChanged?()
    }
    if !wasOnline { synced = false }
    if !synced || refreshRequested { sync() }
  }
  func sync() {
    guard online else { return }
    guard network.accountReadyForGame(),let account,network.state.steamID==account else{refreshRequested=true;return}
    guard libraryFlight==nil else{return}
    refreshRequested=false
    let flight = UUID(), epoch = generation, networkEpoch = network.generation
    libraryFlight = flight
    var pages = [Game](), pageCount = 0, seen = Set<String>(), malformed = false
    let id = network.request("library", options:["paged":true]) { [weak self] event in
      guard let self, self.generation == epoch, self.libraryFlight == flight,
        self.network.generation == networkEpoch, self.network.state.online, self.network.state.steamID == account else { return }
      func integer(_ raw:Any?) -> Int? {
        guard let n=raw as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),let value=Int(n.stringValue),value>=0 else{return nil};return value
      }
      func decode(_ raw:Any?) -> [Game]? {
        guard let raw=raw as?[[String:Any]],raw.count<=20000,
          let bytes=try?JSONSerialization.data(withJSONObject:raw),let values=try?JSONDecoder().decode([Game].self,from:bytes) else{return nil}
        for game in values {
          guard game.store == .steam,let app=UInt32(game.storeID),app>0,String(app)==game.storeID,seen.insert(game.storeID).inserted else{return nil}
        }
        return values
      }
      let type=event["type"] as? String ?? ""
      if type == "library_page" {
        guard !malformed,integer(event["pageIndex"])==pageCount,let values=decode(event["games"]),values.count<=50,pages.count+values.count<=20000 else {
          malformed=true;return
        }
        pages += values;pageCount += 1;return
      }
      guard ["result","error"].contains(type) else{return}
      self.libraryFlight=nil;self.libraryRequest=nil
      if type == "error" {
        self.synced=true;self.onError?("La libreria Steam non è stata sincronizzata. Puoi riprovare con Aggiorna.");return
      }
      let games:[Game]
      if event["games"] != nil, pageCount==0, let values=decode(event["games"]) {games=values}
      else if !malformed,integer(event["gameCount"])==pages.count,integer(event["pageCount"])==pageCount {games=pages}
      else {self.synced=true;self.onError?("Risposta della libreria Steam non valida. La copia precedente è stata conservata.");return}
      self.synced = true; self.onGames?(games, account)
    }
    if libraryFlight == flight { libraryRequest = id }
  }
  func metadata(gameID: String, completion: @escaping Event) {
    network.start()
    guard network.serviceRunning else{completion(["type":"error","code":"service_unavailable"]);return}
    guard let value = UInt32(gameID), value > 0, String(value) == gameID else { completion(["type":"error", "code":"invalid_game_id"]); return }
    if let cached = cachedDetails[gameID] { completion(cached); return }
    if details[gameID] != nil { details[gameID]?.append(completion); return }
    details[gameID] = [completion];metadataQueue.append(gameID);pumpMetadata()
  }
  /// A bounded pass over this profile's cached visible rows, never an owned
  /// library request. Failed public lookups consume their one attempt too.
  func repairCached(games:[Game],prepare:([String])->Void,event:@escaping(String,[String:Any])->Void) {
    guard network.serviceRunning else{prepare([]);return}
    var selected=[String]()
    for game in games.prefix(20000) where repairAttempted.count<64 {
      guard game.profileIDs==nil || game.profileIDs!.contains(profile),SteamLibraryMerge.needsPublicRepair(game),repairAttempted.insert(game.storeID).inserted else{continue}
      selected.append(game.storeID)
    }
    prepare(selected)
    for id in selected {metadata(gameID:id){value in event(id,value)}}
  }
  private func pumpMetadata() {
    while activeMetadata.count<2,!metadataQueue.isEmpty {
      let gameID=metadataQueue.removeFirst()
      guard details[gameID] != nil else{continue}
      activeMetadata.insert(gameID)
      let epoch=generation,networkEpoch=network.generation,identity=account
      let id=network.request("catalog_metadata",options:["gameID":gameID,"language":"italian"]){[weak self]event in
        guard let self,self.generation==epoch,self.network.generation==networkEpoch,self.account==identity else{return}
        guard ["result","error"].contains(event["type"]as?String ?? "")else{return}
        let callbacks=self.details.removeValue(forKey:gameID) ?? []
        self.detailRequests.removeValue(forKey:gameID);self.activeMetadata.remove(gameID)
        var result=event
        if event["type"]as?String=="result" {
          if String(describing:event["appID"] ?? "")==gameID,event["metadata"]is[String:Any]{self.cachedDetails[gameID]=event}
          else{result=["type":"error","code":"invalid_catalog_response"]}
        }
        for callback in callbacks{callback(result)}
        self.pumpMetadata()
      }
      if generation==epoch,activeMetadata.contains(gameID){detailRequests[gameID]=id}else{network.cancel(id)}
    }
  }
  func stop() { invalidateRequests(); account = nil; synced = false; refreshRequested=false; online = false }
  private func invalidateRequests() {
    generation = UUID()
    let requests = Array(detailRequests.values) + (libraryRequest.map { [$0] } ?? [])
    libraryRequest = nil; libraryFlight = nil; details.removeAll(); detailRequests.removeAll(); cachedDetails.removeAll()
    metadataQueue.removeAll();activeMetadata.removeAll();repairAttempted.removeAll()
    for id in requests { network.cancel(id) }
  }
}
