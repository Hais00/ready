// SPDX-License-Identifier: GPL-3.0-only
import Foundation
@testable import LauncherCore

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
    var sizeMetadata:[String:JSONValue]=["platformSizes":.object(["windows":.object(["installedBytes":.unsigned(12345),"downloadBytes":.unsigned(6789),"verified":.bool(true),"status":.string("available"),"fingerprint":.string("never-cache-authority"),"selectedDepots":.array([])])])]
    GameStorageDisplayCache.remember(in:&sizeMetadata)
    sizeMetadata["platformSizes"] = .object(["windows":.object(["status":.string("unavailable")])])
    let sizeStart=ProcessInfo.processInfo.systemUptime
    let immediateSize=GameStorageDisplayCache.info(metadata:sizeMetadata,platform:.windows)
    try check(immediateSize.installedBytes==12345 && immediateSize.downloadBytes==6789 && ProcessInfo.processInfo.systemUptime-sizeStart<0.01,"cachedSizeAvailableSynchronouslyWithoutNetworkOrWorker")
    try check(!immediateSize.verified && immediateSize.status=="display_only" && GameStorageDisplayCache.info(metadata:sizeMetadata,platform:.macOS).installedBytes==nil,"cachedDisplayBytesCannotAuthorizeInstallOrLeakAcrossPlatforms")
    let restoredMetadata=try JSONDecoder().decode([String:JSONValue].self,from:encoder.encode(sizeMetadata))
    try check(GameStorageDisplayCache.info(metadata:restoredMetadata,platform:.windows).installedBytes==12345,"displaySizeCachePersistsAcrossSerialization")
    var sizedLocal=local;sizedLocal.metadata=sizeMetadata
    var sizedState=LibraryState(profiles:state.profiles,activeProfile:profile,games:[sizedLocal]);var sizedRemote=local;sizedRemote.metadata=["platformSizes":.object(["windows":.object(["status":.string("unavailable")])])]
    SteamLibraryMerge.apply([sizedRemote],to:&sizedState,profile:profile,account:"fixture")
    try check(GameStorageDisplayCache.info(metadata:sizedState.games[0].metadata ?? [:],platform:.windows).installedBytes==12345,"catalogRefreshCannotEraseKnownDisplaySize")
    sizedRemote.metadata=["platformSizes":.object(["windows":.object(["installedBytes":.unsigned(23456)])])];SteamLibraryMerge.apply([sizedRemote],to:&sizedState,profile:profile,account:"fixture")
    try check(GameStorageDisplayCache.info(metadata:sizedState.games[0].metadata ?? [:],platform:.windows).installedBytes==23456,"newKnownCatalogSizeReplacesSavedDisplayBytes")
    var partialGame=local;partialGame.metadata=["developers":.array([.string("Known developer")]),"publishers":.array([.string("Known publisher")]),"description":.string("Known description"),"libraryKind":.string("game"),"libraryClassificationSource":.string("pics")]
    var partialState=LibraryState(profiles:state.profiles,activeProfile:profile,games:[partialGame])
    SteamLibraryMerge.enrich(["developers":.array([]),"publishers":.array([]),"description":.string(""),"descriptionUnavailable":.bool(true),"contentType":.string("advertising"),"libraryKind":.string("support"),"libraryClassificationSource":.string("public_store"),"achievementsCount":.unsigned(50),"categories":.array([.string("Co-op")])],gameID:partialGame.storeID,in:&partialState)
    let partialMetadata=partialState.games[0].metadata ?? [:]
    try check(partialMetadata["developers"]==partialGame.metadata?["developers"]&&partialMetadata["publishers"]==partialGame.metadata?["publishers"]&&partialMetadata["description"]==partialGame.metadata?["description"]&&partialMetadata["descriptionUnavailable"] == .bool(false),"partialStoreMetadataCannotEraseKnownHumanInformation")
    try check(partialMetadata["achievementsCount"] == .unsigned(50)&&partialMetadata["categories"] == .array([.string("Co-op")])&&partialMetadata["libraryKind"] == .string("game"),"partialStoreFactsRemainAvailableWithoutReclassifyingPICSGame")
    var emptyRich=partialGame;emptyRich.metadata=["metadataComplete":.bool(true),"developers":.array([]),"publishers":.array([]),"description":.string("")]
    var emptyRichState=LibraryState(profiles:state.profiles,activeProfile:profile,games:[emptyRich]);var repairedPICS=partialGame;repairedPICS.metadata=["metadataComplete":.bool(false),"developers":.array([.string("Legacy Developer")]),"publishers":.array([.string("Legacy Publisher")])]
    SteamLibraryMerge.apply([repairedPICS],to:&emptyRichState,profile:profile,account:"fixture")
    try check(emptyRichState.games[0].metadata?["developers"]==repairedPICS.metadata?["developers"]&&emptyRichState.games[0].metadata?["publishers"]==repairedPICS.metadata?["publishers"],"emptyStoreArraysDoNotBlockLaterPICSAssociationRepair")
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
    var classified=rich;classified.metadata?["libraryKind"] = .string("unknown");classified.metadata?["libraryClassificationSource"] = .string("unknown")
    var authority=placeholder;authority.metadata=["metadataComplete":.bool(false),"libraryKind":.string("game"),"libraryClassificationSource":.string("cm_player"),"ownedGameListed":.bool(true),"ownedGameListAvailable":.bool(true)]
    var classifiedState=LibraryState(profiles:state.profiles,activeProfile:profile,games:[classified]);SteamLibraryMerge.apply([authority],to:&classifiedState,profile:profile,account:"fixture-active")
    try check(classifiedState.games[0].metadata?["libraryKind"] == .string("game") && classifiedState.games[0].metadata?["libraryClassificationSource"] == .string("cm_player") && classifiedState.games[0].metadata?["description"] == rich.metadata?["description"] && classifiedState.games[0].metadata?["ownedGameListed"] == .bool(true),"authoritativeCMClassificationUpdatesRichCatalogWithoutErasingDescription")
    SteamLibraryMerge.enrich(["libraryKind":.string("dlc"),"contentType":.string("dlc"),"libraryClassificationSource":.string("public_store"),"ownedGameListed":.bool(false)],gameID:"700",in:&classifiedState)
    try check(classifiedState.games[0].metadata?["libraryKind"] == .string("game") && classifiedState.games[0].metadata?["ownedGameListed"] == .bool(true),"publicConflictCannotOverrideAuthoritativeClassificationOrMembership")
    var publicState=classifiedState;publicState.games[0].metadata?["libraryClassificationSource"] = .string("public_store")
    SteamLibraryMerge.enrich(["libraryKind":.string("demo"),"contentType":.string("demo"),"libraryClassificationSource":.string("public_store")],gameID:"700",in:&publicState)
    try check(publicState.games[0].metadata?["libraryKind"] == .string("demo"),"freshPublicClassificationCanUpdateEarlierPublicClassification")
    var absent=Game(id:"steam:888",store:.steam,storeID:"888",title:"Gioco Steam · informazioni non disponibili");var absentState=LibraryState(profiles:state.profiles,activeProfile:profile,games:[absent])
    SteamLibraryMerge.markPublicMetadataUnavailable(gameID:"888",in:&absentState);SteamLibraryMerge.enrich(["title":.string("Authoritative title"),"metadataComplete":.bool(true),"description":.string("Fresh")],gameID:"888",in:&absentState)
    try check(absentState.games[0].title=="Authoritative title" && absentState.games[0].metadata?["publicMetadataUnavailable"] == .bool(false),"CMGenericPlaceholderAndPersistedNotFoundRepairAfterRefreshSuccess")
    try check(!SteamLibraryMerge.markPublicMetadataUnavailable(gameID:"888",in:&absentState),"notFoundCannotMarkValidCachedPublicDescriptorUnavailable")
    var presentation=local;presentation.metadata=[:]
    try check(!LibraryEntryPresentation.isOtherContent(presentation),"namedLegacyPresentationRetainedUntilAuthoritativeClassification")
    presentation.metadata=["libraryKind":.string("unknown")];try check(LibraryEntryPresentation.isOtherContent(presentation),"explicitUnknownSeparatedEvenWithRealName")
    presentation.metadata=[:];presentation.title="480";try check(LibraryEntryPresentation.isOtherContent(presentation)&&LibraryEntryPresentation.title(presentation)=="Contenuto Steam non identificato","numericFallbackNeverNamedGameCard")
    presentation.title="Gioco Steam · informazioni non disponibili";try check(LibraryEntryPresentation.isOtherContent(presentation),"CMUnnamedGamePlaceholderPresentationFriendly")
    presentation.metadata=["libraryKind":.string("game"),"libraryClassificationSource":.string("cm_player")];try check(!LibraryEntryPresentation.isOtherContent(presentation),"explicitCMGameRemainsGameEvenWhenNameUnavailable")
    for kind in ["dlc","tool","runtime","support"]{presentation.metadata=["libraryKind":.string(kind)];try check(LibraryEntryPresentation.isOtherContent(presentation),"classified"+kind+"LivesInContentSection")}
    let session=SteamClientSession(profile:profile,command:[CommandLine.arguments[1],CommandLine.arguments[2],run.path],credentialAccess:vault.access)
    let coordinator=SteamLibraryCoordinator(profile:profile,network:session)
    coordinator.onAccountChanged={account in SteamLibraryMerge.clearOtherAccountMembership(in:&state,profile:profile,account:account)}
    coordinator.onGames={[weak coordinator]games,account in merges+=1;SteamLibraryMerge.apply(games,to:&state,profile:profile,account:account,retainMissing:coordinator?.lastMembershipComplete==false)}
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
    let beforePartial=Set(state.games.filter{$0.profileIDs?.contains(profile)==true}.map(\.storeID))
    try mode("partial");coordinator.sync();try spin{merges==4}
    try check(beforePartial.isSubset(of:Set(state.games.filter{$0.profileIDs?.contains(profile)==true}.map(\.storeID))),"incompleteLicenseMembershipRetainsMissingCachedMembers")
    try mode("bad-bool");coordinator.sync();try spin{errors==4};try check(merges==4,"membershipCompletenessRequiresBooleanNotNumericZero")
    let beforeAccountSwitch=merges
    vault.replace("fixture_other");try mode("other");session.request("fixture_other"){_ in};try spin{merges==beforeAccountSwitch+1}
    try check(state.games.first{$0.storeID=="482"}?.profileIDs?.contains(profile)==false && state.games.first{$0.storeID=="600"}?.profileIDs==[profile],"accountSwitchCannotLeakOldRemoteCatalog")
    try check(state.games.first{$0.storeID=="480"}?.variants.prefix(2).elementsEqual([installed,planned])==true && state.games.first{$0.storeID=="499"}==remoteOther,"accountSwitchRetainsInstallationBytesAndOtherProfileData")
    try mode("delay");coordinator.sync();coordinator.stop();settle(0.6);try check(merges==beforeAccountSwitch+1,"stoppedCoordinatorRejectsLateLibraryResult")
    let offline=SteamClientSession(profile:UUID(),command:[CommandLine.arguments[1],CommandLine.arguments[2],run.path],credentialAccess:vault.access)
    var wentOnline=false;offline.onChange={if $0.online{wentOnline=true}}
    offline.start();offline.goOffline();settle(0.5)
    try check(!wentOnline && !offline.state.online,"manualOfflineDuringSlowStartupCannotAutoConnectLater");offline.stop()
    try check(vault.callsOnMain==0,"allSessionVaultIOOffMain")
    let persistenceRoot=run.appendingPathComponent("ordered-state"),paths=LauncherPaths(root:persistenceRoot),entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),secondDone=DispatchSemaphore(value:0)
    let slow=LibraryRepository(paths:paths,beforeWrite:{entered.signal();release.wait()});let newer=LibraryRepository(paths:paths)
    var older=LibraryState.initial();older.games=[Game(id:"old",store:.local,storeID:"old",title:"Older async")];var latest=older;latest.games[0].title="New user save"
    var oldDone=false,oldSucceeded=false,onMain=false
    slow.saveAsync(older){result in oldDone=true;onMain=Thread.isMainThread;if case .success=result{oldSucceeded=true}}
    try check(entered.wait(timeout:.now()+2) == .success,"asyncPersistenceStartsOnOwnedWriterQueue")
    DispatchQueue.global().async{try?newer.save(latest);secondDone.signal()}
    try check(secondDone.wait(timeout:.now()+0.05) == .timedOut,"newRepositorySaveWaitsBehindOlderQueuedSnapshot")
    release.signal();var newerFinished=false;try spin{if secondDone.wait(timeout:.now()) == .success{newerFinished=true};return oldDone && newerFinished}
    try check(oldSucceeded && onMain && (try newer.load()).games[0].title=="New user save","sharedRootWriterPreventsOldAsyncOverwritingMaintenanceOrUserSave")
    let fifo=LibraryRepository(paths:LauncherPaths(root:run.appendingPathComponent("fifo-state")));var callbacks=[Int]();var allMain=true
    for value in 1...3{var snapshot=older;snapshot.games[0].title=String(value);fifo.saveAsync(snapshot){result in callbacks.append(value);allMain=allMain && Thread.isMainThread;if case .failure=result{allMain=false}}}
    var synchronous=older;synchronous.games[0].title="4";try fifo.save(synchronous);try spin{callbacks.count==3}
    try check(callbacks==[1,2,3] && allMain && (try fifo.load()).games[0].title=="4","asyncCompletionsFIFOAndSyncSaveOrdersAfterAllSubmittedSnapshots")
    var valueSnapshot=older;fifo.saveAsync(valueSnapshot){_ in};valueSnapshot.games[0].title="Mutated after enqueue"
    try check((try fifo.load()).games[0].title=="Older async","loadWaitsForPriorAsyncAndSnapshotIsIndependentOfLaterMutation")
    let pausedRoot=run.appendingPathComponent("paused-public-maintenance")
    try FileManager.default.createDirectory(at:pausedRoot,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    vault.replace("fixture_account")
    let pausedSession=SteamClientSession(profile:UUID(),command:[CommandLine.arguments[1],CommandLine.arguments[2],pausedRoot.path],credentialAccess:vault.access)
    let paused=SteamLibraryCoordinator(profile:pausedSession.profile,network:pausedSession)
    var pausedMerges=0,pausedDetails=0
    paused.onGames={_,_ in pausedMerges+=1};pausedSession.onChange={paused.observe($0)}
    paused.setMaintenanceSuspended(true);pausedSession.start();try spin{pausedSession.accountReadyForGame()}
    func publicCalls()->Int{(try?String(contentsOf:pausedRoot.appendingPathComponent("public-calls"),encoding:.utf8)).flatMap(Int.init) ?? 0}
    for id in ["810","811","812"]{paused.metadata(gameID:id){if $0["type"]as?String=="result"{pausedDetails+=1}}}
    paused.sync();settle(0.15)
    try check(publicCalls()==0 && pausedSession.accountReadyForGame(),"publicMaintenancePauseDefersLibraryAndMetadataWithoutStoppingAuthenticatedService")
    paused.setMaintenanceSuspended(false);paused.setMaintenanceSuspended(true);settle(0.45)
    try check(publicCalls()==3 && pausedDetails==2 && pausedMerges==0,"pauseAllowsTwoActiveMetadataRepliesButDoesNotPumpQueuedWorkOrCommitCancelledLibrary")
    paused.metadata(gameID:"813"){if $0["type"]as?String=="result"{pausedDetails+=1}}
    paused.sync();paused.observe(pausedSession.state);settle(0.1)
    try check(publicCalls()==3 && pausedSession.accountReadyForGame(),"lateRepliesAndOnlineSnapshotsCannotRestartPublicMaintenanceWhilePaused")
    paused.setMaintenanceSuspended(false);try spin{pausedDetails==4 && pausedMerges==1}
    try check(publicCalls()==6,"resumePublishesFreshLibraryAndDrainsOnlyDeferredMetadata")
    paused.stop();pausedSession.stop()
    checks["allPassed"]=checks.values.allSatisfy{$0}
    print(String(data:try JSONSerialization.data(withJSONObject:checks,options:[.sortedKeys]),encoding:.utf8)!)
  }
}
