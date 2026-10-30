// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// Metadata only: never uninstalls, moves, chmods or takes ownership of a chosen
/// library. File creation is confined to an explicitly reserved managed path.
public final class StorageLibraryRepository {
  private let paths:LauncherPaths
  public init(paths:LauncherPaths){self.paths=paths}
  public func load()throws->StorageLibraryRegistry{try transaction(write:false){$0}}
  public func list()throws->[StorageLibraryStatus]{
    try transaction(write:false){state in state.libraries.filter{!$0.isRemoved}.map{record in
      do{
        let info=try Self.inspect(URL(fileURLWithPath:record.rootPath));let same=Self.matches(record,info)
        return StorageLibraryStatus(library:record,availability:!same ? .changedVolume:info.writable ? .online:.readOnly,
          freeBytes:info.free,totalBytes:info.total,reservedBytes:Self.reserved(state,library:record),isDefault:state.defaultLibraryID==record.id,unplannedReservations:Self.unplanned(state,library:record))
      }catch{
        let missing=access(record.rootPath,F_OK) != 0 && (errno==ENOENT || errno==ENXIO || errno==ENODEV)
        return StorageLibraryStatus(library:record,availability:missing ? .offline:.unavailable,freeBytes:0,totalBytes:0,
          reservedBytes:Self.reserved(state,library:record),isDefault:state.defaultLibraryID==record.id,unplannedReservations:Self.unplanned(state,library:record))
      }
    }}
  }
  @discardableResult public func add(root:URL,name:String?=nil,makeDefault:Bool=false)throws->StorageLibraryRecord{
    let info=try Self.inspect(root),label=try Self.label(name ?? URL(fileURLWithPath:info.path).lastPathComponent)
    return try transaction{state in
      guard !state.libraries.contains(where:{!$0.isRemoved && (Self.overlaps($0.rootPath,info.path) || ($0.deviceID==info.device && $0.rootFileID==info.inode))})else{throw StorageLibraryFailure.overlap}
      let record:StorageLibraryRecord
      if let index=state.libraries.firstIndex(where:{$0.isRemoved && Self.matches($0,info) && $0.rootPath==info.path}){
        state.libraries[index].isRemoved=false;state.libraries[index].name=label;record=state.libraries[index]
      }else{
        record=StorageLibraryRecord(id:UUID(),name:label,rootPath:info.path,volumeUUID:info.volumeUUID,deviceID:info.device,rootFileID:info.inode,createdAt:Date(),isRemoved:false)
        state.libraries.append(record)
      }
      if makeDefault || state.defaultLibraryID==nil{state.defaultLibraryID=record.id};return record
    }
  }
  public func rename(id:UUID,name:String)throws{let value=try Self.label(name);try transaction{state in guard let i=state.libraries.firstIndex(where:{$0.id==id && !$0.isRemoved})else{throw StorageLibraryFailure.notFound};state.libraries[i].name=value}}
  public func setDefault(id:UUID)throws{try transaction{state in guard state.libraries.contains(where:{$0.id==id && !$0.isRemoved})else{throw StorageLibraryFailure.notFound};state.defaultLibraryID=id}}
  /// Removes the selection, preserving every installation record and game file.
  public func remove(id:UUID)throws{try transaction{state in
    guard let i=state.libraries.firstIndex(where:{$0.id==id && !$0.isRemoved})else{throw StorageLibraryFailure.notFound}
    guard !state.reservations.contains(where:{$0.libraryID==id})else{throw StorageLibraryFailure.busy}
    state.libraries[i].isRemoved=true
    if state.defaultLibraryID==id{state.defaultLibraryID=state.libraries.first{!$0.isRemoved}?.id}
  }}
  @discardableResult public func reserve(libraryID:UUID?=nil,store:Store,gameID:String,platform:GamePlatform,bytes:UInt64?,profileID:UUID?=nil)throws->StorageReservation{
    guard !gameID.isEmpty,gameID.utf8.count<=512 else{throw StorageLibraryFailure.unsafePath}
    return try transaction{state in
      guard let id=libraryID ?? state.defaultLibraryID,let record=state.libraries.first(where:{$0.id==id && !$0.isRemoved})else{throw StorageLibraryFailure.notFound}
      let info=try Self.available(record)
      let reserved=Self.reserved(state,library:record)
      if let bytes{guard reserved<=info.free,bytes<=info.free-reserved else{throw StorageLibraryFailure.insufficientSpace}}
      let install:StorageInstallationRecord
      if let old=state.installations.first(where:{$0.libraryID==id && $0.store==store && $0.gameID==gameID && $0.platform==platform}){
        guard !state.reservations.contains(where:{$0.installationID==old.id})else{throw StorageLibraryFailure.busy};install=old
      }else{
        let relative=store.rawValue+"/"+SafePath.key(gameID)+"/"+platform.rawValue
        try Self.validateRelative(relative)
        guard !Self.exists(record.rootPath,relative)else{throw StorageLibraryFailure.conflict}
        install=StorageInstallationRecord(id:UUID(),libraryID:id,store:store,gameID:gameID,platform:platform,relativePath:relative,adopted:false,state:.reserved,createdAt:Date())
        state.installations.append(install)
      }
      let reservation=StorageReservation(id:UUID(),installationID:install.id,libraryID:id,requestedBytes:bytes,remainingBytes:bytes,jobID:nil,ownerProfileID:profileID,createdAt:Date())
      if let i=state.installations.firstIndex(where:{$0.id==install.id}){state.installations[i].state = .reserved}
      state.reservations.append(reservation);return reservation
    }
  }
  /// The caller shrinks remaining bytes as it writes, avoiding counting those
  /// already-written bytes both in filesystem usage and in the reservation.
  public func updateReservation(id:UUID,remainingBytes:UInt64)throws{try transaction{state in
    guard let i=state.reservations.firstIndex(where:{$0.id==id}),let library=state.libraries.first(where:{$0.id==state.reservations[i].libraryID})else{throw StorageLibraryFailure.notFound}
    if let planned=state.reservations[i].requestedBytes{guard remainingBytes<=planned else{throw StorageLibraryFailure.insufficientSpace}}
    let info=try Self.available(library),other=Self.reserved(state,library:library,excluding:id)
    guard other<=info.free,remainingBytes<=info.free-other else{throw StorageLibraryFailure.insufficientSpace}
    if state.reservations[i].requestedBytes==nil{state.reservations[i].requestedBytes=remainingBytes}
    state.reservations[i].remainingBytes=remainingBytes
  }}
  public func attachJob(reservationID:UUID,jobID:String)throws{try transaction{state in
    guard !jobID.isEmpty,jobID.utf8.count<=128,!jobID.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),
      let i=state.reservations.firstIndex(where:{$0.id==reservationID})else{throw StorageLibraryFailure.notFound}
    guard state.reservations[i].jobID==nil || state.reservations[i].jobID==jobID else{throw StorageLibraryFailure.busy}
    state.reservations[i].jobID=jobID
  }}
  /// Call only after restoring the authoritative download queue. Unattached
  /// planning reservations are retained unless the caller explicitly reconciles
  /// an interrupted startup. No files are ever removed by reconciliation.
  public func reconcile(activeJobIDs:Set<String>,releaseUnattached:Bool=false,profileID:UUID?=nil)throws{try transaction{state in
    let stale=state.reservations.filter{r in
      guard profileID==nil || r.ownerProfileID==profileID else{return false}
      return r.jobID.map{!activeJobIDs.contains($0)} ?? releaseUnattached
    }
    let ids=Set(stale.map(\.installationID));state.reservations.removeAll{r in stale.contains{$0.id==r.id}}
    for i in state.installations.indices where ids.contains(state.installations[i].id){state.installations[i].state = .incomplete}
  }}
  public func installationURL(for reservation:StorageReservation,create:Bool=true)throws->URL{
    try transaction(write:false){state in
      guard let stored=state.reservations.first(where:{$0.id==reservation.id && $0.installationID==reservation.installationID && $0.libraryID==reservation.libraryID}),
        let install=state.installations.first(where:{$0.id==reservation.installationID}),
        let library=state.libraries.first(where:{$0.id==reservation.libraryID && !$0.isRemoved})else{throw StorageLibraryFailure.notFound}
      _=try Self.available(library)
      if create,stored.requiresPlanning{throw StorageLibraryFailure.planningRequired}
      return try Self.installPath(library,relative:install.relativePath,create:create)
    }
  }
  public func markInstalled(reservationID:UUID)throws{try finish(reservationID,installed:true)}
  public func release(reservationID:UUID)throws{try finish(reservationID,installed:false)}
  private func finish(_ id:UUID,installed:Bool)throws{try transaction{state in
    guard let i=state.reservations.firstIndex(where:{$0.id==id})else{return}
    if let j=state.installations.firstIndex(where:{$0.id==state.reservations[i].installationID}){state.installations[j].state=installed ? .installed:.incomplete}
    state.reservations.remove(at:i)
  }}
  @discardableResult public func adopt(libraryID:UUID,store:Store,gameID:String,platform:GamePlatform,directory:URL)throws->StorageInstallationRecord{
    guard !gameID.isEmpty,gameID.utf8.count<=512 else{throw StorageLibraryFailure.unsafePath}
    let selected=try Self.inspect(directory)
    return try transaction{state in
      guard let library=state.libraries.first(where:{$0.id==libraryID && !$0.isRemoved})else{throw StorageLibraryFailure.notFound}
      _=try Self.available(library,requireWritable:false)
      guard selected.path.hasPrefix(library.rootPath+"/")else{throw StorageLibraryFailure.unsafePath}
      let relative=String(selected.path.dropFirst(library.rootPath.count+1));try Self.validateRelative(relative)
      if let existing=state.installations.first(where:{$0.libraryID==libraryID && $0.store==store && $0.gameID==gameID && $0.platform==platform}){
        guard existing.relativePath==relative else{throw StorageLibraryFailure.conflict};return existing
      }
      guard !state.installations.contains(where:{$0.libraryID==libraryID && Self.overlaps($0.relativePath,relative)})else{throw StorageLibraryFailure.conflict}
      let record=StorageInstallationRecord(id:UUID(),libraryID:libraryID,store:store,gameID:gameID,platform:platform,relativePath:relative,adopted:true,state:.installed,createdAt:Date());state.installations.append(record);return record
    }
  }
  private struct Info {let path:String,volumeUUID:String?;let device:UInt64,inode:UInt64,free:UInt64,total:UInt64;let writable:Bool}
  private static func inspect(_ root:URL)throws->Info{
    let fd=try openDirectory(root);defer{close(fd)};var s=stat(),fs=statfs()
    guard fstat(fd,&s)==0,fstatfs(fd,&fs)==0 else{throw StorageLibraryFailure.offline}
    let path=try descriptorPath(fd),volume=(try?URL(fileURLWithPath:path).resourceValues(forKeys:[.volumeUUIDStringKey]))?.volumeUUIDString
    let block=UInt64(fs.f_bsize),free=UInt64(fs.f_bavail).multipliedReportingOverflow(by:block),total=UInt64(fs.f_blocks).multipliedReportingOverflow(by:block)
    return Info(path:path,volumeUUID:volume,device:UInt64(s.st_dev),inode:UInt64(s.st_ino),free:free.overflow ? 0:free.partialValue,total:total.overflow ? 0:total.partialValue,
      writable:fs.f_flags&UInt32(MNT_RDONLY)==0 && faccessat(fd,".",W_OK,0)==0)
  }
  private static func matches(_ library:StorageLibraryRecord,_ info:Info)->Bool{
    let volume=library.volumeUUID.map{$0==info.volumeUUID} ?? (library.deviceID==info.device)
    return volume && library.rootFileID==info.inode
  }
  private static func available(_ library:StorageLibraryRecord,requireWritable:Bool=true)throws->Info{
    guard let info=try?inspect(URL(fileURLWithPath:library.rootPath))else{throw StorageLibraryFailure.offline}
    guard matches(library,info)else{throw StorageLibraryFailure.changedVolume}
    guard !requireWritable || info.writable else{throw StorageLibraryFailure.readOnly};return info
  }
  private static func volumeLibraryIDs(_ state:StorageLibraryRegistry,_ library:StorageLibraryRecord)->Set<UUID>{
    Set(state.libraries.filter{other in if let uuid=library.volumeUUID,let candidate=other.volumeUUID{return uuid==candidate};return library.deviceID==other.deviceID}.map(\.id))
  }
  private static func unplanned(_ state:StorageLibraryRegistry,library:StorageLibraryRecord)->Int{let ids=volumeLibraryIDs(state,library);return state.reservations.filter{ids.contains($0.libraryID) && $0.requiresPlanning}.count}
  private static func reserved(_ state:StorageLibraryRegistry,library:StorageLibraryRecord,excluding:UUID?=nil)->UInt64{
    let ids=volumeLibraryIDs(state,library)
    return state.reservations.filter{ids.contains($0.libraryID) && $0.id != excluding}.reduce(UInt64(0)){sum,item in let n=sum.addingReportingOverflow(item.remainingBytes ?? 0);return n.overflow ? .max:n.partialValue}
  }
  private static func label(_ raw:String)throws->String{let n=raw.trimmingCharacters(in:.whitespacesAndNewlines);guard !n.isEmpty,n.count<=100,!n.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains)else{throw StorageLibraryFailure.invalidName};return n}
  private static func overlaps(_ a:String,_ b:String)->Bool{a==b || a.hasPrefix(b+"/") || b.hasPrefix(a+"/")}
  private static func validateRelative(_ value:String)throws{guard !value.isEmpty,!value.hasPrefix("/"),!value.utf8.contains(0),!value.contains("\\"),value.split(separator:"/",omittingEmptySubsequences:false).allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".."})else{throw StorageLibraryFailure.unsafePath}}
  private static func exists(_ root:String,_ relative:String)->Bool{var s=stat();return lstat(root+"/"+relative,&s)==0}
  private static func installPath(_ library:StorageLibraryRecord,relative:String,create:Bool)throws->URL{
    try validateRelative(relative)
    let expected=try available(library,requireWritable:create)
    var fd=try openDirectory(URL(fileURLWithPath:library.rootPath));defer{close(fd)}
    var selected=stat();guard fstat(fd,&selected)==0,UInt64(selected.st_dev)==expected.device,UInt64(selected.st_ino)==expected.inode else{throw StorageLibraryFailure.changedVolume}
    let parts=relative.split(separator:"/").map(String.init)
    for (offset,name) in parts.enumerated(){
      if create,mkdirat(fd,name,0o700) != 0,errno != EEXIST{throw StorageLibraryFailure.io}
      let child=openat(fd,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
      if child<0,!create,errno==ENOENT{
        let parent=try descriptorPath(fd)
        guard parent==library.rootPath || parent.hasPrefix(library.rootPath+"/")else{throw StorageLibraryFailure.unsafePath}
        return URL(fileURLWithPath:parent+"/"+parts[offset...].joined(separator:"/"),isDirectory:true)
      }
      guard child>=0 else{throw StorageLibraryFailure.unsafePath}
      close(fd);fd=child;var s=stat();guard fstat(fd,&s)==0,s.st_uid==getuid(),!create || faccessat(fd,".",W_OK,0)==0 else{throw StorageLibraryFailure.unsafePath}
    }
    let path=try descriptorPath(fd);guard path.hasPrefix(library.rootPath+"/")else{throw StorageLibraryFailure.unsafePath};return URL(fileURLWithPath:path,isDirectory:true)
  }
  private static func openDirectory(_ url:URL,create:Bool=false,privateRoot:Bool=false)throws->Int32{
    guard url.isFileURL,url.path.hasPrefix("/"),url.path != "/",!url.path.utf8.contains(0)else{throw StorageLibraryFailure.unsafePath}
    var path=url.path
    if path.hasPrefix("/var/"){path="/private/var/"+path.dropFirst(5)}
    else if path.hasPrefix("/tmp/"){path="/private/tmp/"+path.dropFirst(5)}
    let parts=path.split(separator:"/",omittingEmptySubsequences:false).dropFirst()
    guard parts.allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".."})else{throw StorageLibraryFailure.unsafePath}
    var fd=Darwin.open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC);guard fd>=0 else{throw StorageLibraryFailure.io}
    do{
      for name in parts{
        if create,mkdirat(fd,String(name),0o700) != 0,errno != EEXIST{throw StorageLibraryFailure.io}
        let next=openat(fd,String(name),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard next>=0 else{throw StorageLibraryFailure.unsafePath};close(fd);fd=next
      }
      if privateRoot{var s=stat();guard fstat(fd,&s)==0,s.st_uid==getuid(),s.st_mode&0o7777==0o700 else{throw StorageLibraryFailure.unsafePath}}
      return fd
    }catch{close(fd);throw error}
  }
  private static func descriptorPath(_ fd:Int32)throws->String{var bytes=[CChar](repeating:0,count:Int(PATH_MAX)+1);guard fcntl(fd,F_GETPATH,&bytes)==0,let path=String(validatingUTF8:bytes)else{throw StorageLibraryFailure.io};return path}
  private func transaction<T>(write:Bool=true,_ action:(inout StorageLibraryRegistry)throws->T)throws->T{
    let root=try Self.openDirectory(paths.root,create:true,privateRoot:true);defer{close(root)}
    if mkdirat(root,"Storage",0o700) != 0,errno != EEXIST{throw StorageLibraryFailure.io}
    let directory=openat(root,"Storage",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard directory>=0 else{throw StorageLibraryFailure.unsafePath};defer{close(directory)}
    var d=stat();guard fstat(directory,&d)==0,d.st_uid==getuid(),d.st_mode&0o7777==0o700 else{throw StorageLibraryFailure.unsafePath}
    let lock=openat(directory,"registry.lock",O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0o600);guard lock>=0 else{throw StorageLibraryFailure.io};defer{close(lock)}
    var s=stat();guard fstat(lock,&s)==0,s.st_mode&S_IFMT==S_IFREG,s.st_uid==getuid(),s.st_mode&0o7777==0o600,flock(lock,LOCK_EX)==0 else{throw StorageLibraryFailure.unsafePath};defer{flock(lock,LOCK_UN)}
    var state=StorageLibraryRegistry()
    let input=openat(directory,"libraries.json",O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
    if input>=0{
      let stream=FileHandle(fileDescriptor:input,closeOnDealloc:true)
      guard fstat(input,&s)==0,s.st_mode&S_IFMT==S_IFREG,s.st_uid==getuid(),s.st_mode&0o7777==0o600,s.st_size<=16*1024*1024,
        let data=try stream.readToEnd(),let decoded=try?JSONDecoder().decode(StorageLibraryRegistry.self,from:data)else{throw StorageLibraryFailure.invalidRegistry}
      state=decoded
    }else if errno != ENOENT{throw StorageLibraryFailure.unsafePath}
    try Self.validate(state)
    let result=try action(&state)
    if write{
      try Self.validate(state);let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];let data=try encoder.encode(state),name=".registry-"+UUID().uuidString
      let output=openat(directory,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600);guard output>=0 else{throw StorageLibraryFailure.io}
      defer{close(output);unlinkat(directory,name,0)}
      try data.withUnsafeBytes{buffer in var offset=0;while offset<buffer.count{let n=Darwin.write(output,buffer.baseAddress!.advanced(by:offset),buffer.count-offset);if n<0 && errno==EINTR{continue};guard n>0 else{throw StorageLibraryFailure.io};offset+=n}}
      guard fsync(output)==0,renameat(directory,name,directory,"libraries.json")==0,fsync(directory)==0 else{throw StorageLibraryFailure.io}
    }
    return result
  }
  private static func validate(_ state:StorageLibraryRegistry)throws{
    let libraryIDs=Set(state.libraries.map(\.id)),installationIDs=Set(state.installations.map(\.id))
    guard state.schema==1,state.kind=="ready-game-storage-v1",libraryIDs.count==state.libraries.count,installationIDs.count==state.installations.count,
      state.libraries.count<=1000,state.installations.count<=100000,state.reservations.count<=10000,
      Set(state.reservations.map(\.id)).count==state.reservations.count,Set(state.reservations.map(\.installationID)).count==state.reservations.count,
      state.defaultLibraryID.map({id in state.libraries.contains{$0.id==id && !$0.isRemoved}}) ?? true,
      state.installations.allSatisfy({libraryIDs.contains($0.libraryID)}),state.reservations.allSatisfy({r in libraryIDs.contains(r.libraryID) && installationIDs.contains(r.installationID) && ((r.requestedBytes==nil && r.remainingBytes==nil) || (r.remainingBytes != nil && r.requestedBytes != nil && r.remainingBytes!<=r.requestedBytes!))})else{throw StorageLibraryFailure.invalidRegistry}
    for record in state.libraries{guard record.rootPath.hasPrefix("/"),record.rootPath != "/",!record.rootPath.utf8.contains(0),!record.name.isEmpty,
      record.rootPath.split(separator:"/",omittingEmptySubsequences:false).dropFirst().allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".."})else{throw StorageLibraryFailure.invalidRegistry}}
    for reservation in state.reservations{guard state.installations.contains(where:{$0.id==reservation.installationID && $0.libraryID==reservation.libraryID})else{throw StorageLibraryFailure.invalidRegistry}}
    for install in state.installations{try validateRelative(install.relativePath)}
  }
}
