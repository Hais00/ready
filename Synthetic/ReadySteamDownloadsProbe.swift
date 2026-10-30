// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherCore
@main struct ReadySteamDownloadsProbe {
  @MainActor static func main()throws{
    let root=URL(fileURLWithPath:CommandLine.arguments[1])
    let credentials=try JSONSerialization.data(withJSONObject:["username":"fixture_account","refresh_token":"fixture_secret"])
    let access=StoreClient.CredentialAccess(load:{_,_ in credentials},save:{_,_,_ in})
    let client=StoreClient(project:root.appendingPathComponent("project"),stateRoot:root.appendingPathComponent("data"),credentialAccess:access)
    var checks=[String:Bool]()
    func spin(_ name:String,_ condition:()->Bool)throws{let end=Date().addingTimeInterval(12);while !condition()&&Date()<end{_=RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.01))};if !condition(){throw NSError(domain:name,code:1)}}
    func settle(_ seconds:Double=0.25){let end=Date().addingTimeInterval(seconds);while Date()<end{_=RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.01))}}
    func check(_ name:String,_ condition:Bool)throws{checks[name]=condition;if !condition{throw NSError(domain:name,code:1)}}
    func records(_ name:String)throws->Any{try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("data/"+name)))}
    func jobs()throws->[String:[String:Any]]{try records("fixture-jobs.json")as![String:[String:Any]]}
    func row(_ id:String)throws->[String:Any]{try jobs()[id]!}
    func calls()throws->[[String:Any]]{try records("fixture-calls.json")as![[String:Any]]}
    func runs(_ id:String)throws->Int{try row(id)["runs"]as!Int}
    let variant=GameVariant(id:"windows",platform:.windows)
    func game(_ id:String,metadata:[String:JSONValue]?=nil)->Game{var value=Game(id:"steam:"+id,store:.steam,storeID:id,title:"Download fixture",variants:[variant]);value.metadata=metadata;return value}

    // Seed a genuine fake-service durable queued job without ever admitting it.
    let profile=UUID(),reservation=UUID(),seed=SteamDownloads(profile:profile,client:client)
    var seedReady:((Error?)->Void)?,seedJob:SteamDownloadJob?
    seed.registerPrepared={job,done in seedJob=job;seedReady=done}
    seed.enqueue(game:game("123"),variant:variant,installation:root.appendingPathComponent("install"),reservationID:reservation)
    try spin("seed_registered"){seedReady != nil};let id=seedJob!.id;seed.stop()
    let queue=SteamDownloads(profile:profile,client:client);var installed=0
    queue.onInstalled={_ in installed+=1};var restores=[()->Void]()
    queue.reconcileRestored={_,done in restores.append(done)}
    queue.restore();try spin("restoration_held"){restores.count==1 && queue.snapshot.count==1}
    seedReady?(nil);settle()
    try check("heldRestoreCannotStartDownload",try runs(id)==0)
    try check("restoredReservationDTOIsPreserved",UUID(uuidString:queue.snapshot[0].raw["storageReservationID"]as?String ?? "")==reservation)
    queue.restore();try spin("second_restoration_held"){restores.count==2}
    restores[0]();settle();try check("staleRestoreCompletionCannotReleaseNewRestoreGate",try runs(id)==0)
    restores[1]();try spin("running"){queue.snapshot.first?.state=="running"}
    queue.control(id,action:"pause");try spin("paused"){queue.snapshot.first?.state=="paused"}
    let pausedBytes=queue.snapshot[0].completed ?? 0
    queue.control(id,action:"resume");try spin("completed"){queue.snapshot.first?.state=="completed"};try spin("installed_callback"){installed==1}
    queue.restore();try spin("completed_restore_reconcile"){restores.count==3};restores[2]();settle()
    try check("pauseAndResumeSameRestoredJob",pausedBytes<1000 && (try runs(id))==2)
    try check("verifiedCompletionDeliveredOnceAcrossRestore",installed==1)
    try check("completedFilesRetained",FileManager.default.fileExists(atPath:root.appendingPathComponent("install/game.exe").path))
    let broken=game("999");queue.enqueue(game:broken,variant:variant,installation:root.appendingPathComponent("broken"))
    try spin("terminal_without_dto"){queue.snapshot.contains{$0.gameID=="999"&&$0.state=="failed"}};settle(0.4)
    let failed=try jobs().values.first{$0["gameID"]as?String=="999"}!
    try check("terminalErrorWithoutDTOCannotLoop",failed["runs"]as?Int==1);queue.stop()

    // Restore sees a queued job while its registration callback is still held.
    // The preparing-key gate must prevent .next from racing that attachment.
    let preparing=SteamDownloads(profile:UUID(),client:client),reservation2=UUID();var prepared:SteamDownloadJob?,ready:((Error?)->Void)?
    var prepareCallbacks=0,prepareInstalled=0
    preparing.onInstalled={_ in prepareInstalled+=1};preparing.registerPrepared={job,done in prepared=job;ready=done}
    let high=UInt64.max-2
    let metadata:[String:JSONValue]=["platformSizes":.object(["windows":.object(["selectedDepots":.array([.object(["depotID":.integer(10),"manifestID":.unsigned(high)])]),"verified":.bool(true)])])]
    preparing.enqueue(game:game("456",metadata:metadata),variant:variant,installation:root.appendingPathComponent("prepared"),reservationID:reservation2){_ in prepareCallbacks+=1}
    try spin("prepare_registration_held"){ready != nil}
    let preparedID=prepared!.id;var listReconciled=false
    preparing.reconcileRestored={_,done in listReconciled=true;done()};preparing.restore()
    try spin("list_returned_while_preparing"){listReconciled && preparing.snapshot.contains{$0.id==preparedID}}
    settle();try check("heldPreparedRegistrationBlocksRestoredQueuedJob",try runs(preparedID)==0)
    try check("preparingCompletionNotDeliveredBeforeRegistration",prepareCallbacks==0)
    let prepareCall=try calls().first{call in call["operation"]as?String=="download_prepare" && (call["options"]as?[String:Any])?["gameID"]as?String=="456"}!
    let options=prepareCall["options"]as![String:Any],plan=options["expectedInstallPlan"]as![String:Any],depots=plan["selectedDepots"]as![[String:Any]],manifest=depots[0]["manifestID"]as!NSNumber
    let rawMetadata=options["metadata"]as![String:Any],sizes=rawMetadata["platformSizes"]as![String:Any],metadataPlan=sizes["windows"]as![String:Any]
    try check("rawPlanHighUInt64ManifestForwardedWithoutRounding",manifest.uint64Value==high && !["d","f"].contains(String(cString:manifest.objCType)))
    try check("rawMetadataAndExpectedInstallPlanBothForwarded",(metadataPlan["selectedDepots"]as![[String:Any]])[0]["manifestID"]as?NSNumber==manifest)
    try check("reservationIDPassedToPrepareAndDTO",UUID(uuidString:options["storageReservationID"]as?String ?? "")==reservation2 && UUID(uuidString:prepared!.raw["storageReservationID"]as?String ?? "")==reservation2)
    ready?(nil);try spin("prepared_complete"){preparing.snapshot.first?.state=="completed"};settle()
    try check("successfulRegistrationAdmitsExactlyOneWorker",try runs(preparedID)==1)
    try check("successfulRegistrationCompletesAndInstallsExactlyOnce",prepareCallbacks==1 && prepareInstalled==1);preparing.stop()

    let rejected=SteamDownloads(profile:UUID(),client:client);var rejectReady:((Error?)->Void)?,rejectedID:String?,rejectedCompletions=0,rejectedInstalled=0
    rejected.onInstalled={_ in rejectedInstalled+=1};rejected.registerPrepared={job,done in rejectedID=job.id;rejectReady=done}
    rejected.enqueue(game:game("457"),variant:variant,installation:root.appendingPathComponent("rejected"),reservationID:UUID()){result in if case .failure=result{rejectedCompletions+=1}}
    try spin("reject_registration_held"){rejectReady != nil};rejectReady?(NSError(domain:"fixture_storage_rejected",code:1))
    try spin("backend_cancelled"){(try? row(rejectedID!)["state"]as?String)=="cancelled"}
    try check("registrationRejectionCancelsBackendWithoutRunning",try runs(rejectedID!)==0)
    try check("registrationRejectionCannotPublishInstallation",rejectedInstalled==0 && rejectedCompletions==1 && !FileManager.default.fileExists(atPath:root.appendingPathComponent("rejected/game.exe").path));rejected.stop()

    let stopped=SteamDownloads(profile:UUID(),client:client);var lateReady:((Error?)->Void)?,lateID:String?,lateCallbacks=0
    stopped.registerPrepared={job,done in lateID=job.id;lateReady=done};stopped.enqueue(game:game("458"),variant:variant,installation:root.appendingPathComponent("stopped"),reservationID:UUID()){_ in lateCallbacks+=1}
    try spin("late_registration_held"){lateReady != nil};stopped.stop()
    let newProfile=SteamDownloads(profile:UUID(),client:client);var newResume:(()->Void)?
    newProfile.reconcileRestored={_,done in newResume=done};newProfile.restore();try spin("new_profile_restore"){newResume != nil}
    lateReady?(nil);settle();try check("stoppedOldProfileRegistrationCannotStartWorker",try runs(lateID!)==0 && lateCallbacks==0)
    newProfile.stop();newResume?();settle()
    let newRuns=try calls().filter{call in call["operation"]as?String=="download_run" && UUID(uuidString:call["profileID"]as?String ?? "")==newProfile.profile}
    try check("stoppedRestoreCallbackCannotStartWorker",newRuns.isEmpty)
    client.cancelAll()
    print(String(data:try JSONSerialization.data(withJSONObject:["passed":checks.values.allSatisfy{$0},"count":checks.count,"checks":checks],options:.sortedKeys),encoding:.utf8)!)
  }
}
