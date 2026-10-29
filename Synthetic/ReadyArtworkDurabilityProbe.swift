// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import Darwin

private enum DurableCheck:Error{case failed(String)}
@main struct ReadyArtworkDurabilityProbe {
  static func main()throws {
    let run=URL(fileURLWithPath:CommandLine.arguments[1]),a=Data("own-image-A".utf8),b=Data("own-image-B".utf8),address="https://artwork.invalid/image.png"
    let ah=ArtworkIndexStore.hash(a),bh=ArtworkIndexStore.hash(b)
    if CommandLine.arguments.count>2 {
      let directory=run.appendingPathComponent("crash-"+CommandLine.arguments[2])
      let phase=CommandLine.arguments[2],marker=directory.appendingPathComponent("paused")
      let target=phase=="blob" ? bh+".asset":"url-"+ArtworkIndexStore.hash(Data(address.utf8))+".receipt.json"
      let store=ArtworkIndexStore(directory,beforeWrite:{name in
        if name==target{try?Data("own-paused".utf8).write(to:marker);while true{Thread.sleep(forTimeInterval:1)}}
        return true
      })
      _=store.saveURLObject(b,hash:bh,address:address,etag:"B");exit(31)
    }
    var checks=[String:Bool]()
    func check(_ value:Bool,_ name:String)throws{checks[name]=value;if !value{throw DurableCheck.failed(name)}}
    func index(_ url:String,_ hash:String)->ArtworkDiskIndex{var i=ArtworkDiskIndex();i.urls[url]=ArtworkURLRecord(hash:hash,etag:"A");i.roles["own\u{1f}banner"]=ArtworkRoleRecord(gameID:"own",role:.banner,candidates:[url],preferredURL:url,hash:hash);return i}
    let directory=run.appendingPathComponent("base"),store=ArtworkIndexStore(directory)
    try check(store.saveURLObject(a,hash:ah,address:address,etag:"A",lastModified:"date"),"URLObjectAndReceiptCommitDurably")
    try check(store.urlRecord(for:address)?.hash==ah && store.urlRecord(for:address)?.etag=="A","exactURLLookupRecoversHashAndValidators")
    var initial=index(address,ah);initial.urls[address]=store.urlRecord(for:address)
    try check(store.save(initial),"saveReturnsExplicitPublicationSuccess")
    let before=try Data(contentsOf:directory.appendingPathComponent("index.json"))
    let failing=ArtworkIndexStore(directory,beforeWrite:{$0 != "index.json"})
    let second="https://artwork.invalid/second.png"
    try check(failing.saveURLObject(b,hash:bh,address:second,etag:"B"),"blobReceiptSurvivesIndependentIndexCommitFailure")
    var expanded=initial;expanded.urls[second]=ArtworkURLRecord(hash:bh,etag:"B")
    try check(!failing.save(expanded) && (try Data(contentsOf:directory.appendingPathComponent("index.json")))==before,"failedIndexPublicationIsReportedAndOldPrimaryPreserved")
    let oldValid=ArtworkIndexStore(directory).load()
    try check(oldValid.urls[second]?.hash==bh && ArtworkIndexStore(directory).urlRecord(for:second)?.hash==bh,"dirtyMarkerRecoversNewURLDespiteValidOlderPrimary")
    try check(failing.saveURLObject(b,hash:bh,address:address,etag:"B"),"sameURLNewObjectReceiptDurableBeforeIndexPublication")
    let sameURL=ArtworkIndexStore(directory).load()
    try check(sameURL.urls[address]?.hash==bh && sameURL.roles["own\u{1f}banner"]?.hash==bh,"dirtyValidOldIndexRecoversNewerSameURLBlobAndPreferredRole")
    try FileManager.default.removeItem(at:directory.appendingPathComponent("index.json"))
    let recovered=ArtworkIndexStore(directory).load()
    try check(recovered.urls[address]?.hash==bh && recovered.urls[second]?.hash==bh && recovered.roles["own\u{1f}banner"]?.hash==bh,"missingPrimaryRecoversSnapshotRolesAndNewURLReceipts")
    try Data("corrupt owned index".utf8).write(to:directory.appendingPathComponent("index.json"));_=chmod(directory.appendingPathComponent("index.json").path,0o600)
    try check(ArtworkIndexStore(directory).load().urls[second]?.hash==bh,"corruptPrimaryRecoversWithoutNetworkOrDeletingAssets")
    try check(store.object(ah)==a && store.object(bh)==b,"recoveryPreservesAllPreviousGoodObjectBytes")
    let lagDir=run.appendingPathComponent("stale-main-snapshot"),lagged=ArtworkIndexStore(lagDir)
    guard lagged.saveURLObject(a,hash:ah,address:address,etag:"A"),lagged.save(index(address,ah)),lagged.saveURLObject(b,hash:bh,address:address,etag:"A")else{throw DurableCheck.failed("stale-setup")}
    let staleSave=lagged.save(index(address,ah)),afterStale=ArtworkIndexStore(lagDir).load()
    try check(!staleSave && afterStale.urls[address]?.hash==bh,"olderQueuedSnapshotCannotClearNewerDirtyObjectReceipt")
    try check(lagged.save(index(address,bh)),"latestCoveringSnapshotClearsDirtyMarkerAfterDurableCommit")
    let lost=run.appendingPathComponent("repair-once"),lostWriter=ArtworkIndexStore(lost)
    guard lostWriter.saveURLObject(a,hash:ah,address:address,etag:"A")else{throw DurableCheck.failed("repair-once-setup")}
    let recoveryReader=ArtworkIndexStore(lost),recoveryValue=recoveryReader.load()
    try check(recoveryReader.repairNeeded && recoveryReader.recoveryScanCount==1 && ArtworkIndexStore(lost).save(recoveryValue),"recoveredIndexExplicitlyPublishesOnceAndClearsDirty")
    let nextReader=ArtworkIndexStore(lost),nextValue=nextReader.load()
    try check(!nextReader.repairNeeded && nextReader.recoveryScanCount==0 && nextValue.urls[address]?.hash==ah,"healthySecondStartupDoesNotScanReceiptDirectory")
    let empty=run.appendingPathComponent("brand-new-empty"),emptyReader=ArtworkIndexStore(empty)
    _=emptyReader.load()
    try check(!emptyReader.repairNeeded && !FileManager.default.fileExists(atPath:empty.path),"emptyStartupDoesNotCreateIndexOrDirectory")
    let negative="https://artwork.invalid/missing.png"
    try check(store.saveURLRecord(ArtworkURLRecord(negativeStatus:404),address:negative) && ArtworkIndexStore(directory).urlRecord(for:negative)?.negativeStatus==404,"negativeReceiptPreservesNoRetryDecisionAfterIndexLoss")
    let existing=run.appendingPathComponent("old-no-receipts"),old=ArtworkIndexStore(existing)
    _=old.saveObject(a,hash:ah);var legacy=ArtworkDiskIndex()
    for n in 0..<1743{legacy.urls["https://artwork.invalid/old/\(n).png"]=ArtworkURLRecord(hash:ah)}
    var snapshotWrites=0
    let migration=ArtworkIndexStore(existing,beforeWrite:{name in if name=="index-recovery.json"{snapshotWrites+=1};return true})
    try check(migration.ensureRecoverySnapshot(legacy) && migration.ensureRecoverySnapshot(legacy) && snapshotWrites==1,"existing1743URLIndexGetsOneSnapshotInsteadOfPerObjectMigration")
    try check(ArtworkIndexStore(existing).load().urls.count==1743,"indexlessPreReceiptObjectsRemainMappedThroughRecoverySnapshot")
    let thumb=Data("owned-thumbnail".utf8);store.saveThumbnail(thumb,hash:ah,size:128)
    let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),finished=DispatchSemaphore(value:0)
    let blocked=ArtworkIndexStore(directory,beforeWrite:{name in if name=="index.json"{entered.signal();_=release.wait(timeout:.now()+3)};return true})
    DispatchQueue.global().async{_=blocked.save(expanded);finished.signal()}
    guard entered.wait(timeout:.now()+3) == .success else{throw DurableCheck.failed("writer-not-blocked")}
    let read=ArtworkIndexStore(directory),start=Date(),value=read.thumbnail(ah,size:128)
    let fast=Date().timeIntervalSince(start)<0.15
    release.signal();_=finished.wait(timeout:.now()+3)
    try check(value==thumb && fast,"independentThumbnailReaderDoesNotWaitForBlockedIndexWriter")
    for phase in ["blob","commit"] {
      let dir=run.appendingPathComponent("crash-"+phase),s=ArtworkIndexStore(dir)
      guard s.saveURLObject(a,hash:ah,address:address,etag:"A"),s.save(index(address,ah))else{throw DurableCheck.failed("setup-crash")}
      let child=Process();child.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);child.arguments=[run.path,phase];child.standardOutput=FileHandle.nullDevice;child.standardError=FileHandle.nullDevice;try child.run()
      let marker=dir.appendingPathComponent("paused"),end=Date().addingTimeInterval(5)
      while !FileManager.default.fileExists(atPath:marker.path),child.isRunning,Date()<end{Thread.sleep(forTimeInterval:0.005)}
      guard FileManager.default.fileExists(atPath:marker.path)else{child.terminate();throw DurableCheck.failed("pause-marker")}
      _=kill(child.processIdentifier,SIGKILL);child.waitUntilExit()
      try FileManager.default.removeItem(at:dir.appendingPathComponent("index.json"))
      let result=ArtworkIndexStore(dir).load(),expected=phase=="blob" ? ah:bh
      try check(result.urls[address]?.hash==expected && s.object(ah)==a && (phase=="blob" || s.object(bh)==b),phase=="blob" ? "SIGKILLBeforeBlobKeepsOldCommittedReceipt":"SIGKILLAfterBlobRecoversPendingURLReceipt")
    }
    let unsafe=run.appendingPathComponent("unsafe"),outside=run.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);try FileManager.default.createSymbolicLink(at:unsafe,withDestinationURL:outside)
    try check(!ArtworkIndexStore(unsafe).save(initial) && !FileManager.default.fileExists(atPath:outside.appendingPathComponent("index.json").path),"aliasRootCannotReceiveRecoveryOrIndexWrites")
    let immutable=directory.appendingPathComponent("unrelated");try Data("keep".utf8).write(to:immutable)
    try check((try Data(contentsOf:immutable))==Data("keep".utf8) && ArtworkIndexStore(directory).load().urls.count>0,"recoveryNeverPurgesUnrelatedDiskEntries")
    let report:[String:Any]=["passed":checks.values.allSatisfy{$0},"count":checks.count,"checks":checks,"fixtureOnly":true,"actualSIGKILLCases":2,"realNetworkAccountKeychainGameOrLiveCacheUsed":false]
    print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self))
  }
}
