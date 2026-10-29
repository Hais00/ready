// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherCore

private final class LibraryVault {
  private let lock=NSLock();private var value:Data?
  private var mainCalls=0
  init(){value=Self.data("fixture_account")}
  static func data(_ account:String)->Data{try!JSONSerialization.data(withJSONObject:["username":account,"refresh_token":"fixture_only_secret"])}
  func replace(_ account:String){lock.lock();value=Self.data(account);lock.unlock()}
  var callsOnMain:Int{lock.lock();defer{lock.unlock()};return mainCalls}
  var access:StoreClient.CredentialAccess{.init(load:{[self] _,_ in
    lock.lock();if Thread.isMainThread{mainCalls+=1};let result=value;lock.unlock()
    Thread.sleep(forTimeInterval:0.12);return result
  },save:{[self] data,_,_ in lock.lock();if Thread.isMainThread{mainCalls+=1};value=data;lock.unlock()},remove:{[self] _,_ in lock.lock();if Thread.isMainThread{mainCalls+=1};value=nil;lock.unlock()})}
}
@main struct ReadySteamLibraryProbe {
  @MainActor static func main()throws {
    let run=URL(fileURLWithPath:CommandLine.arguments[3]),profile=UUID(),other=UUID(),vault=LibraryVault()
    var checks=[String:Bool](),merges=0,errors=0,heartbeat=false
    func check(_ value:Bool,_ name:String)throws{checks[name]=value;if !value{throw NSError(domain:name,code:1)}}
    func spin(_ condition:()->Bool)throws{let end=Date().addingTimeInterval(8);while !condition() && Date()<end{_=RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.005))};if !condition(){throw NSError(domain:"deadline",code:1)}}
    func settle(_ delay:Double=0.35){let end=Date().addingTimeInterval(delay);while Date()<end{_=RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.005))}}
    func mode(_ name:String)throws{try name.write(to:run.appendingPathComponent("mode"),atomically:true,encoding:.utf8)}
    let installed=GameVariant(id:"own-native",platform:.macOS,architecture:.arm64,executable:"/fixture/unchanged.app",workingDirectory:"/fixture",installationRoot:"/fixture",arguments:["personal"],installed:true,verification:"local")
    let planned=GameVariant(id:"own-windows",platform:.windows,architecture:.x86_64,arguments:["keep"],verification:"personal plan")
    var local=Game(id:"local480",store:.steam,storeID:"480",title:"Local",variants:[installed,planned],selectedVariant:planned.id,engine:.dxmtMetal,lastPlayed:Date(timeIntervalSince1970:1234),saveRules:[SaveRule("ExtraSaves")]);local.profileIDs=[profile];local.metadata=["personal":.string("keep")]
    var remoteOther=Game(id:"other499",store:.steam,storeID:"499",title:"Other profile",variants:[]);remoteOther.profileIDs=[other];remoteOther.metadata=[SteamLibraryMerge.ownersKey:.object([other.uuidString:.string("other-account")])]
    var state=LibraryState(profiles:[Profile(id:profile,name:"A"),Profile(id:other,name:"B")],activeProfile:profile,games:[local,remoteOther])
    state.gamePreferences=[GamePreferences.key(profile:profile,gameID:local.id):GamePreferences(engine:.vulkanKosmic,selectedVariant:planned.id,variants:[planned])]
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
    let preferences=try encoder.encode(state.gamePreferences)
    var nativeOnly=local;nativeOnly.id="local700";nativeOnly.storeID="700";nativeOnly.variants=[installed];nativeOnly.selectedVariant=installed.id
    let localWindows=GameVariant(id:"local-windows",platform:.windows,architecture:.x86_64,executable:"/fixture/game.exe",workingDirectory:"/fixture",installationRoot:"/fixture",arguments:["keep"],installed:true)
    var windowsOnly=Game(id:"local701",store:.steam,storeID:"701",title:"Owned fixture",variants:[localWindows],selectedVariant:localWindows.id,engine:.dxmtMetal,saveRules:[SaveRule("PersonalSaves")]);windowsOnly.profileIDs=[profile]
    var availability=LibraryState(profiles:state.profiles,activeProfile:profile,games:[nativeOnly,windowsOnly]);availability.gamePreferences=state.gamePreferences
    let offerings:[String:JSONValue]=["downloadableVariants":.array([.string("windows"),.string("macOS"),.string("windows"),.string("linux"),.string("MAC"),.integer(1)])]
    SteamLibraryMerge.enrich(offerings,gameID:"700",in:&availability);SteamLibraryMerge.enrich(offerings,gameID:"700",in:&availability)
    let mac=availability.games[0],windows=mac.variants.first{$0.platform == .windows}
    try check(mac.variants.first==installed && mac.variants.count==2 && Set(mac.variants.map(\.id)).count==2 && windows?.id=="windows" && windows?.installed==false && windows?.architecture == .unknown && windows?.executable==nil && windows?.workingDirectory==nil && windows?.installationRoot==nil && windows?.arguments.isEmpty==true && mac.selectedVariant==installed.id && mac.saveRules==nativeOnly.saveRules && mac.profileIDs==nativeOnly.profileIDs && mac.metadata?[SteamLibraryMerge.ownersKey]==nil,"catalogBothPlatformsAddsOnlyMissingUninstalledWindowsPreservingLocalNativeAndScope")
    SteamLibraryMerge.enrich(offerings,gameID:"701",in:&availability)
    let win=availability.games[1],newMac=win.variants.first{$0.platform == .macOS}
    try check(win.variants.first==localWindows && win.variants.count==2 && newMac?.id=="macOS" && newMac?.architecture == .unknown && newMac?.installed==false && newMac?.executable==nil && newMac?.workingDirectory==nil && newMac?.installationRoot==nil && newMac?.arguments.isEmpty==true && win.selectedVariant==windowsOnly.selectedVariant && win.saveRules==windowsOnly.saveRules && (try encoder.encode(availability.gamePreferences))==preferences,"catalogMacAvailabilityRemainsUnknownAndCannotReplaceLocalWindowsOrPreferences")
    var cached=nativeOnly;cached.metadata=offerings;cached.metadata?["metadataComplete"] = .bool(true)
    cached.metadata?[SteamLibraryMerge.ownersKey] = .object([profile.uuidString:.string("fixture-owner")])
    var nonSteam=windowsOnly;nonSteam.store = .local;nonSteam.metadata=offerings
    var cachedState=LibraryState(profiles:state.profiles,activeProfile:profile,games:[cached,nonSteam]);cachedState.gamePreferences=state.gamePreferences
    let projected=SteamLibraryMerge.projectCachedAvailability(in:&cachedState)
    let unchangedSecondProjection = !SteamLibraryMerge.projectCachedAvailability(in:&cachedState)
    try check(projected && unchangedSecondProjection && cachedState.games[0].variants.first==installed && cachedState.games[0].variants.contains{$0.id=="windows" && !$0.installed && $0.architecture == .unknown && $0.executable==nil} && cachedState.games[0].metadata==cached.metadata && cachedState.games[0].profileIDs==cached.profileIDs && cachedState.games[0].saveRules==cached.saveRules && cachedState.games[1]==nonSteam && (try encoder.encode(cachedState.gamePreferences))==preferences,"cachedMetadataProjectionWorksBeforeAuthAndIsIdempotentWithoutChangingOwnershipOrOtherStores")
    var rich=nativeOnly;rich.artworkURL="https://example.invalid/public-capsule.png"
    rich.metadata=["metadataComplete":.bool(true),"description":.string("Known public description"),"bannerURL":.string("https://example.invalid/public-banner.png"),"capsuleURL":.string(rich.artworkURL!),"heroURL":.string("https://example.invalid/public-hero.png"),"launch":.string("old"),SteamLibraryMerge.ownersKey:.object([profile.uuidString:.string("fixture-old")])]
    var placeholder=Game(id:"steam:700",store:.steam,storeID:"700",title:"PICS",artworkURL:"https://example.invalid/pics-icon.png",variants:[GameVariant(id:"windows",platform:.windows)])
    placeholder.metadata=["metadataComplete":.bool(false),"description":.string(""),"bannerURL":.string(""),"capsuleURL":.string(""),"launch":.string("updated"),"picsOnly":.string("fresh")]
    var refreshed=LibraryState(profiles:state.profiles,activeProfile:profile,games:[rich]);refreshed.gamePreferences=state.gamePreferences
    SteamLibraryMerge.apply([placeholder],to:&refreshed,profile:profile,account:"fixture-active")
    let retained=refreshed.games[0]
    try check(retained.metadata?["metadataComplete"] == .bool(true) && retained.metadata?["description"] == rich.metadata?["description"] && retained.metadata?["bannerURL"] == rich.metadata?["bannerURL"] && retained.metadata?["capsuleURL"] == rich.metadata?["capsuleURL"] && retained.metadata?["heroURL"] == rich.metadata?["heroURL"] && retained.artworkURL==rich.artworkURL && retained.metadata?["launch"] == .string("updated") && retained.metadata?["picsOnly"] == .string("fresh") && retained.metadata?[SteamLibraryMerge.ownersKey] == .object([profile.uuidString:.string("fixture-active")]) && retained.variants.first==installed && retained.variants.contains{$0.id=="windows" && !$0.installed} && retained.saveRules==rich.saveRules && retained.selectedVariant==rich.selectedVariant && (try encoder.encode(refreshed.gamePreferences))==preferences,"incompleteOwnedPICSRefreshPreservesKnownRichPublicCatalogAndUpdatesLaunchOwnershipAndAvailability")
    var customNative=installed;customNative.id="mac:Cyberpunk2077.app"
    var customGame=nativeOnly;customGame.variants=[customNative];customGame.selectedVariant=customNative.id
    var customState=LibraryState(profiles:state.profiles,activeProfile:profile,games:[customGame]);customState.gamePreferences=state.gamePreferences
    let picsGame=Game(id:"steam:700",store:.steam,storeID:"700",title:"PICS",variants:[GameVariant(id:"macOS",platform:.macOS),GameVariant(id:"windows",platform:.windows)])
    SteamLibraryMerge.apply([picsGame],to:&customState,profile:profile,account:"fixture-active")
    SteamLibraryMerge.apply([picsGame],to:&customState,profile:profile,account:"fixture-active")
    let deduplicated=customState.games[0]
    try check(deduplicated.variants.first==customNative && deduplicated.variants.filter{$0.platform == .macOS}.count==1 && deduplicated.variants.count==2 && deduplicated.variants.contains{$0.id=="windows" && $0.platform == .windows && $0.architecture == .unknown && !$0.installed && $0.executable==nil} && deduplicated.selectedVariant==customNative.id && deduplicated.saveRules==customGame.saveRules && (try encoder.encode(customState.gamePreferences))==preferences,"customInstalledNativeIDSuppressesRedundantPICSUnknownPlatformWithoutLosingWindowsAvailability")
    let session=SteamClientSession(profile:profile,command:[CommandLine.arguments[1],CommandLine.arguments[2],run.path],credentialAccess:vault.access)
    let coordinator=SteamLibraryCoordinator(profile:profile,network:session)
    coordinator.onAccountChanged={account in SteamLibraryMerge.clearOtherAccountMembership(in:&state,profile:profile,account:account)}
    coordinator.onGames={games,account in merges+=1;SteamLibraryMerge.apply(games,to:&state,profile:profile,account:account)}
    coordinator.onError={_ in errors+=1}
    session.onChange={coordinator.observe($0)}
    defer{coordinator.stop();session.stop()}
    DispatchQueue.main.asyncAfter(deadline:.now()+0.03){heartbeat=true}
    let start=Date();session.start();try check(Date().timeIntervalSince(start)<0.1,"startupReturnsBeforeSlowVault")
    try spin{heartbeat};try check(!session.accountReadyForGame(),"mainRunLoopResponsiveWhileVaultPending")
    try spin{FileManager.default.fileExists(atPath:run.appendingPathComponent("first-page").path)}
    try check(merges==0,"partialPagesNeverCommit")
    try spin{merges==1}
    let merged=state.games.first{$0.storeID=="480"}!
    try check(merged.id==local.id && merged.variants.prefix(2).elementsEqual([installed,planned]),"installedAndPlannedNativeWindowsVariantsPreserved")
    try check(merged.saveRules==local.saveRules && merged.engine==local.engine && merged.selectedVariant==local.selectedVariant && merged.lastPlayed==local.lastPlayed,"saveRulesPreferencesAndHistoryPreserved")
    try check(try encoder.encode(state.gamePreferences)==preferences,"profileScopedPreferencesUntouched")
    try check(merged.metadata?["personal"] == .string("keep"),"localMetadataPreserved")
    let remote=state.games.first{$0.storeID=="482"}!
    try check(remote.profileIDs==[profile] && remote.variants.allSatisfy{!$0.installed && $0.executable==nil && $0.installationRoot==nil},"remoteCatalogCannotGrantInstalledPathsOrOtherProfileMembership")
    try check(state.games.first{$0.storeID=="499"}==remoteOther,"otherProfileCatalogUnchanged")
    session.request("snapshot"){_ in};settle();try check(merges==1,"onlineNotificationsDoNotDuplicateSync")
    session.goOffline();try spin{!session.state.online};session.reconnect();try spin{merges==2};try check(true,"reconnectAutomaticallyResyncs")
    try mode("duplicate");coordinator.sync();try spin{errors==1};try check(merges==2 && state.games.first{$0.storeID=="480"}?.variants.prefix(2).elementsEqual([installed,planned])==true,"duplicatePageFailsAtomicallyPreservingCachedLibrary")
    try mode("count");coordinator.sync();try spin{errors==2};try check(merges==2,"terminalCountMismatchNeverCommits")
    try mode("error");coordinator.sync();try spin{errors==3};try check(merges==2,"networkErrorKeepsPreviousCatalog")
    try mode("normal")
    var detailReplies=0
    coordinator.metadata(gameID:"480"){event in if event["type"] as? String == "result"{detailReplies+=1}}
    coordinator.metadata(gameID:"480"){event in if event["type"] as? String == "result"{detailReplies+=1}}
    try spin{detailReplies==2}
    let calls=try String(contentsOf:run.appendingPathComponent("metadata-calls"),encoding:.utf8)
    try check(calls=="1","lazyDetailsCoalesce")
    coordinator.metadata(gameID:"480"){_ in detailReplies+=1};try check(detailReplies==3,"lazyMetadataCacheAvoidsRepeatedServiceRequest")
    SteamLibraryMerge.enrich([SteamLibraryMerge.ownersKey:.object([other.uuidString:.string("injected")]),"shortDescription":.string("Details"),"capsuleURL":.string("https://example.invalid/fixture.png")],gameID:"480",in:&state)
    try check(state.games.first{$0.storeID=="480"}?.variants.prefix(2).elementsEqual([installed,planned])==true && state.games.first{$0.storeID=="480"}?.artworkURL=="https://example.invalid/fixture.png","lazyMetadataPreservesInstallationAndCannotReplaceOwnership")
    try mode("large");coordinator.sync();try spin{merges==3}
    let largeBytes=Int(try String(contentsOf:run.appendingPathComponent("large-bytes"),encoding:.utf8)) ?? 0
    try check(largeBytes>4*1024*1024 && state.games.filter{$0.profileIDs?.contains(profile)==true}.count==1200,"ownedLibraryOverFourMiBStreamsAndCommitsAtomically")
    vault.replace("fixture_other");try mode("other");session.request("fixture_other"){_ in};try spin{merges==4}
    try check(state.games.first{$0.storeID=="482"}?.profileIDs?.contains(profile)==false && state.games.first{$0.storeID=="600"}?.profileIDs==[profile],"accountSwitchCannotLeakOldRemoteCatalog")
    try check(state.games.first{$0.storeID=="480"}?.variants.prefix(2).elementsEqual([installed,planned])==true && state.games.first{$0.storeID=="499"}==remoteOther,"accountSwitchRetainsInstallationBytesAndOtherProfileData")
    try mode("delay");coordinator.sync();coordinator.stop();settle(0.6);try check(merges==4,"stoppedCoordinatorRejectsLateLibraryResult")
    let offline=SteamClientSession(profile:UUID(),command:[CommandLine.arguments[1],CommandLine.arguments[2],run.path],credentialAccess:vault.access)
    var wentOnline=false;offline.onChange={if $0.online{wentOnline=true}}
    offline.start();offline.goOffline();settle(0.5)
    try check(!wentOnline && !offline.state.online,"manualOfflineDuringSlowStartupCannotAutoConnectLater");offline.stop()
    try check(vault.callsOnMain==0,"allSessionVaultIOOffMain")
    checks["allPassed"]=checks.values.allSatisfy{$0}
    print(String(data:try JSONSerialization.data(withJSONObject:checks,options:[.sortedKeys]),encoding:.utf8)!)
  }
}
