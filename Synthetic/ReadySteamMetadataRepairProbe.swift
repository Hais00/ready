// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherCore
@main struct ReadySteamMetadataRepairProbe {
 @MainActor static func main()throws{
  let run=URL(fileURLWithPath:CommandLine.arguments[3]),profile=UUID(),other=UUID();var checks=[String:Bool]()
  func check(_ value:Bool,_ name:String)throws{checks[name]=value;if !value{throw NSError(domain:name,code:1)}}
  func spin(_ condition:()->Bool)throws{let end=Date().addingTimeInterval(12);while !condition() && Date()<end{_=RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.005))};if !condition(){throw NSError(domain:"repair-deadline",code:1)}}
  func settle(_ delay:Double=0.4){let end=Date().addingTimeInterval(delay);while Date()<end{_=RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.005))}}
  func records()->[[String:Any]]{(try?String(contentsOf:run.appendingPathComponent("calls.jsonl"),encoding:.utf8))?.split(separator:"\n").compactMap{try?JSONSerialization.jsonObject(with:Data($0.utf8))as?[String:Any]} ?? []}
  func calls(_ app:String)->[[String:Any]]{records().filter{$0["gameID"]as?String==app}}
  func game(_ id:Int,healthy:Bool=false,owner:UUID?=nil)->Game{
   var g=Game(id:"steam:\(id)",store:.steam,storeID:String(id),title:healthy ? "Custom Name":"\(id)",artworkURL:healthy ? "https://example.invalid/known.png":nil,variants:healthy ? [GameVariant(id:"windows",platform:.windows)]:[],saveRules:[SaveRule("Personal")]);g.profileIDs=[owner ?? profile]
   g.metadata=["description":.string("Keep cached description")];if healthy{g.metadata?["metadataComplete"] = .bool(true)};return g
  }
  let healthy=(900..<905).map{game($0,healthy:true)},hidden=(3000..<3005).map{game($0,owner:other)},missing=(1000..<1080).map{game($0)}
  var state=LibraryState(profiles:[Profile(id:profile,name:"A"),Profile(id:other,name:"B")],activeProfile:profile,games:healthy+hidden+missing)
  let originalCount=state.games.count,session=SteamClientSession(profile:profile,command:[CommandLine.arguments[1],CommandLine.arguments[2],run.path],credentialAccess:.init(load:{_,_ in nil},save:{_,_,_ in throw NSError(domain:"no-save",code:1)}))
  let coordinator=SteamLibraryCoordinator(profile:profile,network:session);session.onChange={coordinator.observe($0)};session.start();defer{coordinator.stop();session.stop()}
  var prepared=[String](),completed=0,errors=0
  func repair(){coordinator.repairCached(games:state.games,prepare:{ids in prepared += ids;for id in ids{_=SteamLibraryMerge.addArtworkFallback(gameID:id,in:&state)}},event:{id,event in
   completed+=1
   if event["type"]as?String=="error"{errors+=1;if event["code"]as?String=="metadata_not_found"{SteamLibraryMerge.markPublicMetadataUnavailable(gameID:id,in:&state)};return}
   if let raw=event["metadata"],let bytes=try?JSONSerialization.data(withJSONObject:raw),let metadata=try?JSONDecoder().decode([String:JSONValue].self,from:bytes){SteamLibraryMerge.enrich(metadata,gameID:id,in:&state)}
  })}
  repair();try check(prepared.count==80&&Set(prepared).count==80,"allIncompleteVisibleRecordsWarmBeyondOld64Limit");try spin{completed==80}
  let first=records().filter{$0["operation"]as?String=="catalog_metadata"}
  try check(first.count==80&&first.allSatisfy{(1000..<1080).contains(Int($0["gameID"]as?String ?? "") ?? 0)},"validDescriptorsAndOtherProfileNeverBulkFetched")
  try check(first.compactMap{$0["active"]as?Int}.max()==2,"allRecordWarmupAtMostTwoConcurrent")
  try check(!records().contains{["connect","authenticate","library","authorize_game"].contains($0["operation"]as?String ?? "")},"publicWarmupNeedsNoCredentialOrOwnershipRequest")
  try check(errors==20&&state.games.count==originalCount&&state.games.first{$0.storeID=="1000"}?.metadata?["description"] == .string("Keep cached description"),"negativeAndTransientKeepEveryRecordAndCachedFields")
  try check(state.games.first{$0.storeID=="1000"}?.metadata?["publicMetadataUnavailable"] == .bool(true)&&state.games.first{$0.storeID=="1004"}?.metadata?["publicMetadataUnavailable"] != .bool(true),"onlyOfficialNotFoundPersistsNegativeFlag")
  let repository=LibraryRepository(paths:LauncherPaths(root:run.appendingPathComponent("state")));try repository.save(state);let reloaded=try repository.load()
  try check(!SteamLibraryMerge.needsPublicRepair(reloaded.games.first{$0.storeID=="1000"}!),"notFoundPersistsAcrossRepositoryReloadWithoutRetry")
  let repaired=state.games.first{$0.storeID=="1001"}!
  try check(repaired.title=="Official 1001"&&repaired.variants.count==2&&repaired.variants.allSatisfy{!$0.installed&&$0.architecture == .unknown&&$0.executable==nil}&&repaired.saveRules==[SaveRule("Personal")],"officialDescriptorRepairsOnlyMissingFields")
  repair();settle();try check(completed==80&&prepared.count==80&&records().filter{$0["operation"]as?String=="catalog_metadata"}.count==80,"oneWarmAttemptPerScopeNoAutomaticRetry")
  var legacy=game(920,healthy:true);legacy.metadata=["metadataComplete":.bool(true)]
  try check(SteamLibraryMerge.needsPublicRepair(legacy),"legacyCompleteWithoutDescriptionStillWarms")
  legacy.metadata?["descriptionUnavailable"] = .bool(true);try check(!SteamLibraryMerge.needsPublicRepair(legacy),"explicitFinalUnavailableDescriptionIsValidNoWarmRetry")
  var lazy=0;for _ in 0..<2{coordinator.metadata(gameID:"901"){_ in lazy+=1}};try spin{lazy==2};try check(calls("901").count==1,"lazyDetailsCoalesce")
  var activeOld="",forced="";coordinator.metadata(gameID:"5001"){activeOld=$0["code"]as?String ?? "result"};try spin{calls("5001").count==1}
  coordinator.metadata(gameID:"5001",refresh:true,priority:true){forced=($0["metadata"]as?[String:Any])?["title"]as?String ?? "error"};try spin{!forced.isEmpty};settle()
  try check(forced=="Fresh 5001"&&activeOld=="superseded","activeNormalCannotOverrideForcedRefresh")
  var cached="";coordinator.metadata(gameID:"5001"){cached=($0["metadata"]as?[String:Any])?["title"]as?String ?? "error"};try check(cached=="Fresh 5001"&&calls("5001").count==2,"forcedResultRemainsCachedAfterLateOldResponse")
  var blockers=0;coordinator.metadata(gameID:"5101"){_ in blockers+=1};coordinator.metadata(gameID:"5102"){_ in blockers+=1};try spin{calls("5101").count==1&&calls("5102").count==1}
  var queuedOld="",queuedFresh="";coordinator.metadata(gameID:"5103"){queuedOld=$0["code"]as?String ?? "result"};coordinator.metadata(gameID:"5103",refresh:true,priority:true){queuedFresh=($0["metadata"]as?[String:Any])?["title"]as?String ?? "error"};try spin{blockers==2 && !queuedOld.isEmpty && !queuedFresh.isEmpty}
  try check(queuedOld=="superseded"&&queuedFresh=="Fresh 5103"&&calls("5103").count==1&&calls("5103")[0]["refresh"]as?Bool==true,"queuedNormalKeepsOwnRevisionAndIsNeverSentAfterForce")
  var joined=[String]();coordinator.metadata(gameID:"5201",refresh:true){joined.append(($0["metadata"]as?[String:Any])?["title"]as?String ?? "error")};coordinator.metadata(gameID:"5201"){joined.append(($0["metadata"]as?[String:Any])?["title"]as?String ?? "error")};try spin{joined.count==2}
  try check(joined==["Fresh 5201","Fresh 5201"]&&calls("5201").count==1,"normalDuringForcedJoinsAndCannotInvalidateForceRevision")
  var rateDone=0;for id in ["7001","7002","7003"]{coordinator.metadata(gameID:id){_ in rateDone+=1}};try spin{rateDone==3}
  let startRate=calls("7001")[0]["time"]as!Double,startQueued=calls("7003")[0]["time"]as!Double
  try check(startQueued-startRate>=1.9,"rateLimitedBackendCodeHonorsLongestGlobalCooldown")
  try check(calls("7001").count==1&&calls("7002").count==1,"rateLimitedJobsAreNotAutomaticallyRetried")
  try check(records().compactMap{$0["active"]as?Int}.max()==2,"globalTwoLimitIncludesRefreshAndCooldown")
  var oldScope=0;coordinator.repairCached(games:(6000..<6004).map{game($0)},prepare:{_ in},event:{_,_ in oldScope+=1});try spin{calls("6000").count==1&&calls("6001").count==1};coordinator.stop();settle(0.6)
  try check(oldScope==0&&calls("6002").isEmpty&&calls("6003").isEmpty,"stopDropsLateAndQueuedMetadata")
  var loads=0;let invalidSession=SteamClientSession(profile:UUID(),command:[CommandLine.arguments[1],CommandLine.arguments[2],run.path],credentialAccess:.init(load:{_,_ in loads+=1;return nil},save:{_,_,_ in throw NSError(domain:"no-save",code:1)}));let invalidCoordinator=SteamLibraryCoordinator(profile:UUID(),network:invalidSession);var invalid=false
  invalidCoordinator.metadata(gameID:"bad"){invalid=$0["code"]as?String=="invalid_game_id"};try check(invalid&&loads==0 && !invalidSession.serviceRunning,"invalidAppNeverStartsServiceOrVault")
  checks["allPassed"]=checks.values.allSatisfy{$0};print(String(data:try JSONSerialization.data(withJSONObject:checks,options:[.sortedKeys]),encoding:.utf8)!)
 }
}
