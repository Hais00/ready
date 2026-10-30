// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AppKit
import LauncherCore

extension AppDelegate {
  @MainActor func bootstrapGameStorage(){
    let repository=storageLibraries,installed=state.games
    storageWork.async{
      do{
        var current=try repository.load()
        if current.libraries.isEmpty{
          let volume=URL(fileURLWithPath:"/Volumes/Dati APFS",isDirectory:true)
          if (try?volume.resourceValues(forKeys:[.volumeURLKey]))?.volume==volume {
            let preferred=volume.appendingPathComponent("Ready Games",isDirectory:true)
            if !FileManager.default.fileExists(atPath:preferred.path){try FileManager.default.createDirectory(at:preferred,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}
            _=try repository.add(root:preferred,name:"Dati APFS · Ready",makeDefault:true)
          }
          for game in installed{for variant in game.variants where variant.installed{
            guard let root=try?variant.installationDirectory(),root.deletingLastPathComponent().lastPathComponent=="common",root.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent=="steamapps"else{continue}
            let library=root.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            current=try repository.load()
            let record=current.libraries.first{$0.rootPath==library.path} ?? (try?repository.add(root:library,name:"Steam · "+library.lastPathComponent))
            if let record{_=try?repository.adopt(libraryID:record.id,store:game.store,gameID:game.storeID,platform:variant.platform,directory:root)}
          }}
        }
      }catch{DispatchQueue.main.async{[weak self]in self?.canvas?.message="Archiviazione da verificare nelle impostazioni: "+error.localizedDescription}}
    }
  }
  @MainActor func configureStorageDownloads(_ downloads:SteamDownloads){
    let repository=storageLibraries,profile=downloads.profile
    downloads.registerPrepared={ [weak self]job,done in
      guard let self else{done(LauncherError.failed("Installazione annullata."));return}
      self.storageWork.async{
        let result=Result{try Self.bindStorageJob(job,profile:profile,repository:repository)}
        DispatchQueue.main.async{switch result{case .success:done(nil);case .failure(let error):done(error)}}
      }
    }
    downloads.reconcileRestored={ [weak self,weak downloads]jobs,done in
      guard let self else{done();return}
      let otherJobs=self.activeOtherStorageJobs
      self.storageWork.async{
        var rejected=[String]()
        for job in jobs where job.raw["storageReservationID"] != nil{
          do{try Self.bindStorageJob(job,profile:profile,repository:repository)}catch{if !["completed","cancelled"].contains(job.state){rejected.append(job.id)}}
        }
        let active=Set(jobs.filter{!["completed","cancelled"].contains($0.state)}.map(\.id)).union(otherJobs)
        try?repository.reconcile(activeJobIDs:active,releaseUnattached:true,profileID:profile)
        DispatchQueue.main.async{
          MainActor.assumeIsolated{
            if let downloads{downloads.blockForStorage(rejected);for id in rejected{downloads.control(id,action:"pause")}}
            done()
          }
        }
      }
    }
  }
  private static func bindStorageJob(_ job:SteamDownloadJob,profile:UUID,repository:StorageLibraryRepository)throws{
    guard let raw=job.raw["storageReservationID"]as?String else{return} // Legacy queue files are retained.
    guard let id=UUID(uuidString:raw),UUID(uuidString:job.raw["profileID"]as?String ?? "")==profile else{throw StorageLibraryFailure.conflict}
    let registry=try repository.load()
    if ["completed","cancelled"].contains(job.state){if job.state=="completed"{try repository.markInstalled(reservationID:id)}else{try repository.release(reservationID:id)};return}
    guard let reservation=registry.reservations.first(where:{$0.id==id && $0.ownerProfileID==profile}),
      let installation=registry.installations.first(where:{$0.id==reservation.installationID && $0.store == .steam && $0.gameID==job.gameID && $0.platform.rawValue==job.platform}),
      let supplied=job.raw["installDir"]as?String,try repository.installationURL(for:reservation,create:false).path==URL(fileURLWithPath:supplied).standardizedFileURL.path else{throw StorageLibraryFailure.conflict}
    _=installation
    try repository.attachJob(reservationID:id,jobID:job.id)
  }
  @MainActor func handleStorageDownloadProgress(_ jobs:[SteamDownloadJob],profile:UUID){
    let repository=storageLibraries
    storageWork.async{
      guard let registry=try?repository.load()else{return}
      for job in jobs{
        guard let raw=job.raw["storageReservationID"]as?String,let id=UUID(uuidString:raw),let reservation=registry.reservations.first(where:{$0.id==id && $0.ownerProfileID==profile})else{continue}
        if job.state=="completed"{try?repository.markInstalled(reservationID:id)}
        else if job.state=="cancelled"{try?repository.release(reservationID:id)}
        else if let planned=reservation.requestedBytes,let done=job.completed,done>=0{
          let remaining=planned>UInt64(done) ? planned-UInt64(done):0
          if reservation.remainingBytes != remaining{try?repository.updateReservation(id:id,remainingBytes:remaining)}
        }
      }
    }
  }
}
