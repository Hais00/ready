// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreFoundation
import LauncherCore

/// Remote membership is scoped to an account/profile. Local installation and
/// preference records remain in place even when that membership is removed.
enum SteamLibraryMerge {
  static let ownersKey = "readySteamCatalogOwners"
  private static let catalogKeys:Set<String>=["shortDescription","description","releaseDate","storeURL","iconURL","capsuleURL","heroURL","bannerURL","developers","publishers","genres","downloadableVariants","metadataComplete","title","contentType","artworkFallbacksUnverified","libraryKind","libraryClassificationSource","libraryMembershipSource","ownedGameListAvailable","ownedGameListed","contentInfoUnavailable","descriptionUnavailable","descriptionSource","publicMetadataUnavailable","platformSizes","platformRequirements"]
  private static let classificationKeys:Set<String>=["libraryKind","libraryClassificationSource","contentType","contentInfoUnavailable"]
  private static let membershipKeys:Set<String>=["libraryMembershipSource","ownedGameListAvailable","ownedGameListed","licensePackageMember","licenseMembershipComplete","ownedGameListStatus"]
  private static func knownKind(_ metadata:[String:JSONValue])->String? {
    for key in ["libraryKind","contentType"] {
      guard case .string(let raw)=metadata[key]else{continue}
      let value=raw.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
      if ["game","demo","application","dlc","tool","runtime","support"].contains(value){return value}
      if value=="software"{return "application"};if value=="mod"{return "game"}
    }
    return nil
  }
  private static func hasDescription(_ metadata:[String:JSONValue])->Bool {
    ["description","shortDescription"].contains{key in
      if case .string(let value)=metadata[key]{return !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty};return false
    }
  }
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
  static func apply(_ incoming: [Game], to state: inout LibraryState, profile: UUID, account: String, retainMissing: Bool = false) {
    if !retainMissing { clearRemoteMembership(in: &state, profile: profile) }
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
        GameStorageDisplayCache.remember(in:&metadata)
        let keepRichCatalog = metadata["metadataComplete"] == .bool(true) && remote.metadata?["metadataComplete"] != .bool(true)
        let incoming=remote.metadata ?? [:]
        let authoritative=["pics","cm_player"].contains(incoming["libraryClassificationSource"]?.foundation as?String ?? "") && knownKind(incoming) != nil
        let hadKnownClassification=knownKind(metadata) != nil
        for (key, value) in incoming where key != ownersKey {
          if membershipKeys.contains(key){metadata[key]=value;continue}
          if classificationKeys.contains(key){
            if authoritative || !hadKnownClassification {metadata[key]=value}
            continue
          }
          if keepRichCatalog,catalogKeys.contains(key),metadata[key] != nil,key != "platformSizes"{continue}
          metadata[key] = value
        }
        if keepRichCatalog,let artwork=old.artworkURL,!artwork.isEmpty{game.artworkURL=artwork}
        GameStorageDisplayCache.remember(in:&metadata)
        game.metadata = metadata
        // Shared discovered installations retain their original visibility.
        game.profileIDs = old.profileIDs == nil && local(old) ? nil : Array(Set((old.profileIDs ?? []) + [profile]))
        var values = owners(old); values[profile.uuidString] = .string(account)
        game.metadata?[ownersKey] = .object(values)
        state.games[index] = game
      } else {
        game.profileIDs = [profile]
        var metadata = game.metadata ?? [:]; metadata[ownersKey] = .object([profile.uuidString: .string(account)])
        GameStorageDisplayCache.remember(in:&metadata)
        game.metadata = metadata; state.games.append(game)
      }
    }
  }
  static func placeholderTitle(_ game:Game)->Bool {
    let title=game.title.trimmingCharacters(in:.whitespacesAndNewlines)
    return title.isEmpty || title==game.storeID || title=="Contenuto Steam · informazioni non disponibili" || title=="Contenuto Steam non identificato" || title=="Gioco Steam · informazioni non disponibili"
  }
  private static func hasArtwork(_ game:Game)->Bool {
    let values=[game.artworkURL,game.metadata?["capsuleURL"]?.foundation as?String,game.metadata?["iconURL"]?.foundation as?String]
    return values.compactMap{$0}.contains{URL(string:$0)?.scheme=="https"}
  }
  static func needsPublicRepair(_ game:Game)->Bool {
    guard game.store == .steam,let app=UInt32(game.storeID),app>0,String(app)==game.storeID else{return false}
    let metadata=game.metadata ?? [:]
    if metadata["publicMetadataUnavailable"] == .bool(true){return false}
    if metadata["metadataComplete"] == .bool(true),(hasDescription(metadata) || metadata["descriptionUnavailable"] == .bool(true)){return false}
    return placeholderTitle(game) || !hasArtwork(game) || game.variants.isEmpty || !hasDescription(metadata)
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
    let oldKind=knownKind(combined),newKind=knownKind(metadata)
    let authoritative=["pics","cm_player"].contains(combined["libraryClassificationSource"]?.foundation as?String ?? "")
    for (key,value) in metadata where catalogKeys.contains(key) && !membershipKeys.contains(key) {
      if classificationKeys.contains(key),authoritative,let oldKind,newKind != oldKind{continue}
      if key=="libraryClassificationSource",authoritative,oldKind != nil{continue}
      combined[key]=value
    }
    if metadata["metadataComplete"] == .bool(true){combined["publicMetadataUnavailable"] = .bool(false)}
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
  @discardableResult static func markPublicMetadataUnavailable(gameID:String,in state:inout LibraryState)->Bool {
    guard let index=state.games.firstIndex(where:{$0.store == .steam && $0.storeID==gameID})else{return false}
    let metadata=state.games[index].metadata ?? [:]
    guard !(metadata["metadataComplete"] == .bool(true) && hasDescription(metadata)),metadata["publicMetadataUnavailable"] != .bool(true)else{return false}
    state.games[index].metadata=(metadata.merging(["publicMetadataUnavailable":.bool(true)]){_,new in new});return true
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
  private var metadataRevisions=[String:Int](),metadataJobRevisions=[String:Int]()
  private var metadataCooldown:DispatchWorkItem?
  private var metadataResumeAfter=Date.distantPast
  private(set) var maintenanceSuspended=false
  private(set) var lastMembershipComplete=true
  private var knownNetworkGeneration:UUID
  var onScopeChanged:(()->Void)?
  var onAccountChanged: ((String) -> Void)?
  var onGames: (([Game], String) -> Void)?
  var onError: ((String) -> Void)?
  init(profile: UUID, network: SteamClientSession) { self.profile = profile; self.network = network;knownNetworkGeneration=network.generation }
  /// Only public library/catalog work is suspended; the authenticated service,
  /// heartbeat, activity and independent user download queue remain untouched.
  func setMaintenanceSuspended(_ value:Bool){
    guard maintenanceSuspended != value else{return};maintenanceSuspended=value
    if value {
      metadataCooldown?.cancel();metadataCooldown=nil
      if let id=libraryRequest{libraryRequest=nil;libraryFlight=nil;refreshRequested=true;network.cancel(id)}
    }else{
      if !synced || refreshRequested{sync()}
      pumpMetadata()
    }
  }
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
    guard !maintenanceSuspended else{refreshRequested=true;return}
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
      if let raw=event["licenseMembershipComplete"] {
        guard let value=raw as?NSNumber,CFGetTypeID(value)==CFBooleanGetTypeID()else{self.synced=true;self.onError?("Risposta della libreria Steam non valida. La copia precedente è stata conservata.");return}
        self.lastMembershipComplete=value.boolValue
      }else{self.lastMembershipComplete=true}
      self.synced = true; self.onGames?(games, account)
    }
    if libraryFlight == flight { libraryRequest = id }
  }
  func metadata(gameID: String, refresh: Bool = false, priority: Bool = false, completion: @escaping Event) {
    guard let value = UInt32(gameID), value > 0, String(value) == gameID else { completion(["type":"error", "code":"invalid_game_id"]); return }
    if !maintenanceSuspended{network.start()}
    guard network.serviceRunning else{completion(["type":"error","code":"service_unavailable"]);return}
    if !refresh,details[gameID+"|refresh"] != nil {details[gameID+"|refresh"]?.append(completion);return}
    if !refresh, let cached = cachedDetails[gameID] { completion(cached); return }
    let key=gameID+(refresh ? "|refresh":"|cached")
    if details[key] != nil {
      details[key]?.append(completion)
      if priority,let index=metadataQueue.firstIndex(of:key){metadataQueue.remove(at:index);metadataQueue.insert(key,at:0)}
      return
    }
    metadataRevisions[gameID,default:0] += 1
    metadataJobRevisions[key]=metadataRevisions[gameID]
    details[key] = [completion]
    if priority{metadataQueue.insert(key,at:0)}else{metadataQueue.append(key)}
    pumpMetadata()
  }
  /// Warm every incomplete visible record once per service generation. Public
  /// lookups never infer ownership; the queue limits concurrency and rate limits.
  func repairCached(games:[Game],prepare:([String])->Void,event:@escaping(String,[String:Any])->Void) {
    guard !maintenanceSuspended else{prepare([]);return}
    guard network.serviceRunning else{prepare([]);return}
    var selected=[String]()
    for game in games.prefix(20000) {
      guard game.profileIDs==nil || game.profileIDs!.contains(profile),SteamLibraryMerge.needsPublicRepair(game),repairAttempted.insert(game.storeID).inserted else{continue}
      selected.append(game.storeID)
    }
    prepare(selected)
    for id in selected {metadata(gameID:id){value in event(id,value)}}
  }
  private func pumpMetadata() {
    guard !maintenanceSuspended,network.serviceRunning else{return}
    guard Date() >= metadataResumeAfter else {
      if metadataCooldown == nil {
        let work=DispatchWorkItem{[weak self] in self?.metadataCooldown=nil;self?.pumpMetadata()}
        metadataCooldown=work;DispatchQueue.main.asyncAfter(deadline:.now()+metadataResumeAfter.timeIntervalSinceNow,execute:work)
      }
      return
    }
    while activeMetadata.count<2,!metadataQueue.isEmpty {
      let key=metadataQueue.removeFirst(),gameID=key.components(separatedBy:"|")[0]
      guard details[key] != nil,let revision=metadataJobRevisions[key]else{continue}
      if metadataRevisions[gameID] != revision {
        let callbacks=details.removeValue(forKey:key) ?? [];metadataJobRevisions.removeValue(forKey:key)
        for callback in callbacks{callback(["type":"error","code":"superseded"])}
        continue
      }
      activeMetadata.insert(key)
      let epoch=generation,networkEpoch=network.generation,identity=account
      let id=network.request("catalog_metadata",options:["gameID":gameID,"language":"italian","refresh":key.hasSuffix("|refresh")]){[weak self]event in
        guard let self,self.generation==epoch,self.network.generation==networkEpoch,self.account==identity else{return}
        guard ["result","error"].contains(event["type"]as?String ?? "")else{return}
        let callbacks=self.details.removeValue(forKey:key) ?? []
        self.detailRequests.removeValue(forKey:key);self.metadataJobRevisions.removeValue(forKey:key);self.activeMetadata.remove(key)
        var result=event
        if self.metadataRevisions[gameID] != revision {result=["type":"error","code":"superseded"]}
        else if event["type"]as?String=="result" {
          if String(describing:event["appID"] ?? "")==gameID,event["metadata"]is[String:Any]{self.cachedDetails[gameID]=event}
          else{result=["type":"error","code":"invalid_catalog_response"]}
        }
        let code=event["code"]as?String ?? ""
        let rateLimited=["rate_limited","metadata_rate_limited"].contains(code)
        var retry:Double?
        if let number=event["retryAfterSeconds"]as?NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),number.doubleValue.isFinite,number.doubleValue>0{retry=min(3600,max(1,number.doubleValue))}
        if rateLimited || (code=="metadata_unavailable" && retry != nil) {
          self.metadataResumeAfter=max(self.metadataResumeAfter,Date().addingTimeInterval(retry ?? 60))
        }
        for callback in callbacks{callback(result)}
        self.pumpMetadata()
      }
      if generation==epoch,activeMetadata.contains(key){detailRequests[key]=id}else{network.cancel(id)}
    }
  }
  func stop() { invalidateRequests(); account = nil; synced = false; refreshRequested=false; online = false }
  private func invalidateRequests() {
    generation = UUID()
    let requests = Array(detailRequests.values) + (libraryRequest.map { [$0] } ?? [])
    libraryRequest = nil; libraryFlight = nil; details.removeAll(); detailRequests.removeAll(); cachedDetails.removeAll()
    metadataQueue.removeAll();activeMetadata.removeAll();repairAttempted.removeAll();metadataRevisions.removeAll();metadataJobRevisions.removeAll()
    metadataCooldown?.cancel();metadataCooldown=nil;metadataResumeAfter = .distantPast
    for id in requests { network.cancel(id) }
  }
}
