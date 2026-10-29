// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherCore
@main struct ReadySteamMetadataRepairProbe {
  @MainActor static func main()throws {
    let run=URL(fileURLWithPath:CommandLine.arguments[3]),profile=UUID(),other=UUID()
    var checks=[String:Bool]()
    func check(_ value:Bool,_ name:String)throws{checks[name]=value;if !value{throw NSError(domain:name,code:1)}}
    func spin(_ condition:()->Bool)throws{let deadline=Date().addingTimeInterval(12);while !condition() && Date()<deadline{_=RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.005))};if !condition(){throw NSError(domain:"repair-deadline",code:1)}}
    func settle(_ seconds:Double=0.3){let end=Date().addingTimeInterval(seconds);while Date()<end{_=RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.005))}}
    func records()->[[String:Any]]{(try?String(contentsOf:run.appendingPathComponent("calls.jsonl"),encoding:.utf8))?.split(separator:"\n").compactMap{try?JSONSerialization.jsonObject(with:Data($0.utf8))as?[String:Any]} ?? []}
    func game(_ id:Int,healthy:Bool=false,owner:UUID?=nil)->Game {
      var g=Game(id:"steam:\(id)",store:.steam,storeID:String(id),title:healthy ? "Custom Name":"\(id)",artworkURL:healthy ? "https://example.invalid/known.png":nil,variants:healthy ? [GameVariant(id:"windows",platform:.windows)]:[],saveRules:[SaveRule("Personal")]);g.profileIDs=[owner ?? profile]
      g.metadata=["description":.string("Keep cached description")];return g
    }
    let healthy=(900..<905).map{game($0,healthy:true)},hidden=(3000..<3005).map{game($0,owner:other)},missing=(1000..<1080).map{game($0)}
    var state=LibraryState(profiles:[Profile(id:profile,name:"A"),Profile(id:other,name:"B")],activeProfile:profile,games:healthy+hidden+missing)
    let originalCount=state.games.count,session=SteamClientSession(profile:profile,command:[CommandLine.arguments[1],CommandLine.arguments[2],run.path],credentialAccess:.init(load:{_,_ in nil},save:{_,_,_ in throw NSError(domain:"no-credential-save",code:1)}))
    let coordinator=SteamLibraryCoordinator(profile:profile,network:session)
    session.onChange={coordinator.observe($0)};session.start()
    defer{coordinator.stop();session.stop()}
    var prepared=[String](),completed=0,errors=0
    func repair(){coordinator.repairCached(games:state.games,prepare:{ids in prepared += ids;for id in ids{_=SteamLibraryMerge.addArtworkFallback(gameID:id,in:&state)}},event:{id,event in
      completed+=1
      if event["type"]as?String=="error"{errors+=1;return}
      if let raw=event["metadata"],let bytes=try?JSONSerialization.data(withJSONObject:raw),let metadata=try?JSONDecoder().decode([String:JSONValue].self,from:bytes){SteamLibraryMerge.enrich(metadata,gameID:id,in:&state)}
    })}
    repair();try check(prepared.count==64 && Set(prepared).count==64,"repairBudget64MissingOnlyUnique")
    try spin{completed==64}
    let first=records().filter{$0["operation"]as?String=="catalog_metadata"}
    try check(first.count==64 && first.allSatisfy{(1000..<1064).contains(Int($0["gameID"]as?String ?? "") ?? 0)},"healthyAndOtherProfileRowsNeverBulkFetched")
    try check(first.compactMap{$0["active"]as?Int}.max()==2,"metadataQueueHasAtMostTwoConcurrentRequests")
    try check(!records().contains{["connect","authenticate","library","authorize_game"].contains($0["operation"]as?String ?? "")},"publicRepairRunsWithoutCredentialOrOwnedLibraryRequest")
    try check(errors==16 && state.games.count==originalCount && state.games.first{$0.storeID=="1000"}?.title=="1000" && state.games.first{$0.storeID=="1000"}?.metadata?["description"] == .string("Keep cached description"),"unavailablePublicMetadataKeepsEveryCachedOwnedRowAndExistingFields")
    let failed=state.games.first{$0.storeID=="1000"}!
    try check(failed.metadata?["artworkFallbacksUnverified"] == .bool(true) && failed.artworkURL=="https://cdn.akamai.steamstatic.com/steam/apps/1000/library_600x900.jpg" && failed.variants.isEmpty,"fallbackURLsAreCandidatesNotImageOrPlatformProof")
    let repaired=state.games.first{$0.storeID=="1001"}!
    try check(repaired.title=="Official 1001" && repaired.variants.count==2 && repaired.variants.allSatisfy{!$0.installed && $0.architecture == .unknown && $0.executable==nil} && repaired.saveRules==[SaveRule("Personal")],"officialTitleAndAvailableUnknownPlatformsRepairOnlyMissingData")
    repair();settle();try check(completed==64 && prepared.count==64 && records().filter{$0["operation"]as?String=="catalog_metadata"}.count==64,"errorsAndSuccessConsumeOneAttemptNoAutomaticRetryLoop")
    var lazy=0
    for _ in 0..<2{coordinator.metadata(gameID:"901"){event in lazy+=1;if let raw=event["metadata"],let data=try?JSONSerialization.data(withJSONObject:raw),let md=try?JSONDecoder().decode([String:JSONValue].self,from:data){SteamLibraryMerge.enrich(md,gameID:"901",in:&state)}}}
    try spin{lazy==2}
    try check(records().filter{$0["gameID"]as?String=="901"}.count==1 && state.games.first{$0.storeID=="901"}?.title=="Custom Name","lazyDetailCoalescesAndNeverOverwritesCustomTitle")
    var numericCustom=game(888,healthy:true);numericCustom.title="1984";var customState=LibraryState(profiles:state.profiles,activeProfile:profile,games:[numericCustom]);SteamLibraryMerge.enrich(["title":.string("Official replacement"),"contentType":.string("dlc")],gameID:"888",in:&customState)
    try check(customState.games[0].title=="1984" && customState.games[0].metadata?["contentType"] == .string("dlc") && customState.games.count==1,"numericCustomNamesAndDLCRowsArePreserved")
    let scoped=SteamLibraryCoordinator(profile:profile,network:session);session.onChange={scoped.observe($0)}
    var stale=0
    scoped.repairCached(games:(5000..<5004).map{game($0)},prepare:{_ in},event:{_,_ in stale+=1})
    try spin{records().filter{($0["gameID"]as?String).flatMap(Int.init).map{(5000..<5004).contains($0)} ?? false}.count>=2}
    scoped.stop();settle(0.6)
    try check(stale==0 && records().filter{($0["gameID"]as?String).flatMap(Int.init).map{(5000..<5004).contains($0)} ?? false}.count==2,"stopDropsLateResultsAndNeverStartsRemainingQueuedRequests")
    var networkStale=0
    scoped.repairCached(games:(6000..<6004).map{game($0)},prepare:{_ in},event:{_,_ in networkStale+=1})
    try spin{records().filter{($0["gameID"]as?String).flatMap(Int.init).map{(6000..<6004).contains($0)} ?? false}.count>=2}
    session.stop();settle(0.5)
    try check(networkStale==0 && !session.serviceRunning,"networkGenerationStopCancelsRepairWithoutRestartingService")
    checks["allPassed"]=checks.values.allSatisfy{$0}
    print(String(data:try JSONSerialization.data(withJSONObject:checks,options:[.sortedKeys]),encoding:.utf8)!)
  }
}
