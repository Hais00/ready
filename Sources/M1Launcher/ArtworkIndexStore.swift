// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import Darwin

struct ArtworkURLRecord:Codable,Equatable {
  var hash:String?,file:String?,etag:String?,lastModified:String?,negativeStatus:Int?
  init(hash:String?=nil,etag:String?=nil,lastModified:String?=nil,negativeStatus:Int?=nil){
    self.hash=hash;file=hash.map{$0+".asset"};self.etag=etag;self.lastModified=lastModified;self.negativeStatus=negativeStatus
  }
}
struct ArtworkRoleRecord:Codable {
  let gameID:String
  let role:GameArtwork.Role
  var candidates:[String]
  var preferredURL:String?
  var hash:String?
}
struct ArtworkDiskIndex:Codable {
  var schema=1
  var kind="ready-artwork-index-v1"
  var urls=[String:ArtworkURLRecord]()
  var roles=[String:ArtworkRoleRecord]()
}
private struct ArtworkObjectReceipt:Codable {
  var schema=1
  var kind="ready-artwork-url-object-v1"
  let address:String
  let sequence:UInt64
  let record:ArtworkURLRecord
}
/// Direct readers do not share a mutable writer state or acquire an index lock.
/// A failed index can be rebuilt once at startup; exact-URL receipt lookup also
/// recovers a newer object absent from an otherwise valid older index.
final class ArtworkIndexStore {
  private let directory:URL?
  private let beforeWrite:((String)->Bool)?
  private let recoveryLock=NSLock()
  private var recovered:ArtworkDiskIndex?
  private(set) var repairNeeded=false
  private(set) var recoveryScanCount=0
  // Writer-queue only. Do not clear a dirty receipt merely because an older
  // Main snapshot happened to be queued behind the receipt write.
  private var pendingRecords=[String:ArtworkURLRecord]()
  init(_ directory:URL?,beforeWrite:((String)->Bool)?=nil){self.directory=directory;self.beforeWrite=beforeWrite}
  static func hash(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
  private static func validHash(_ hash:String)->Bool{hash.count==64 && hash.utf8.allSatisfy{(48...57).contains($0)||(97...102).contains($0)}}
  private static func validURL(_ address:String)->Bool{guard address.utf8.count<=4096,let url=URL(string:address)else{return false};return url.scheme?.lowercased()=="https" && url.host != nil && url.user==nil && url.password==nil}
  private static func validRecord(_ value:ArtworkURLRecord)->Bool{
    (value.hash.map(validHash) ?? true) && (value.file==nil || value.file==value.hash.map{$0+".asset"})
      && [value.etag,value.lastModified].compactMap{$0}.allSatisfy{$0.utf8.count<=4096 && !$0.unicodeScalars.contains{CharacterSet.controlCharacters.contains($0)}}
  }
  func load()->ArtworkDiskIndex {
    if !entryExists("index-dirty"),let data=read("index.json",limit:16*1024*1024),let value=validIndex(data){return value}
    recoveryLock.lock();defer{recoveryLock.unlock()}
    if let recovered{return recovered}
    recoveryScanCount+=1
    let value=recoverReceipts();recovered=value;repairNeeded = !value.urls.isEmpty || !value.roles.isEmpty
    return value
  }
  @discardableResult func save(_ index:ArtworkDiskIndex)->Bool {
    guard let data=try?JSONEncoder().encode(index),data.count<=16*1024*1024 else{return false}
    // Keep a separately committed snapshot first: existing pre-receipt assets
    // gain recovery coverage without thousands of one-off sidecar writes.
    let backup=write(data,name:"index-recovery.json")
    let primary=write(data,name:"index.json")
    guard backup && primary,pendingRecords.allSatisfy({index.urls[$0.key]==$0.value})else{return false}
    guard clearDirty()else{return false};pendingRecords.removeAll();return true
  }
  @discardableResult func ensureRecoverySnapshot(_ index:ArtworkDiskIndex)->Bool {
    if let data=read("index-recovery.json",limit:16*1024*1024),validIndex(data) != nil{return true}
    guard let data=try?JSONEncoder().encode(index),data.count<=16*1024*1024 else{return false}
    return write(data,name:"index-recovery.json")
  }
  private func validIndex(_ data:Data)->ArtworkDiskIndex? {
    guard let value=try?JSONDecoder().decode(ArtworkDiskIndex.self,from:data),value.schema==1,value.kind=="ready-artwork-index-v1",value.urls.count<=100000,value.roles.count<=100000,
      value.urls.allSatisfy({Self.validURL($0.key) && Self.validRecord($0.value)}),value.roles.values.allSatisfy({$0.hash.map(Self.validHash) ?? true})else{return nil};return value
  }
  func object(_ hash:String)->Data?{
    guard Self.validHash(hash),let data=read(hash+".asset",limit:10_000_000),Self.hash(data)==hash else{return nil};return data
  }
  /// Compatibility for unassociated content. New downloads should use the
  /// URL-bound variant so index-publication failure cannot orphan their mapping.
  func saveObject(_ data:Data,hash:String)->Bool{
    guard Self.validHash(hash),data.count<=10_000_000,Self.hash(data)==hash else{return false}
    if object(hash) != nil{return true};return write(data,name:hash+".asset")
  }
  /// Intent is durable before the blob; the prior committed URL receipt remains
  /// valid until replacement data is durable. Recovery selects the newest
  /// receipt whose actual blob validates, including a crash-pending receipt.
  func saveURLObject(_ data:Data,hash:String,address:String,etag:String?=nil,lastModified:String?=nil)->Bool {
    guard Self.validURL(address),Self.validHash(hash),!data.isEmpty,data.count<=10_000_000,Self.hash(data)==hash else{return false}
    let record=ArtworkURLRecord(hash:hash,etag:etag,lastModified:lastModified)
    guard Self.validRecord(record)else{return false}
    let sequence=nextSequence(address)
    guard let sequence else{return false}
    let receipt=ArtworkObjectReceipt(address:address,sequence:sequence,record:record)
    guard let encoded=try?JSONEncoder().encode(receipt),markDirty(),write(encoded,name:receiptName(address,pending:true)),saveObject(data,hash:hash)else{return false}
    pendingRecords[address]=record
    guard write(encoded,name:receiptName(address,pending:false))else{return false}
    removePending(address,sequence:sequence)
    return true
  }
  /// Persist validators/negative results without rewriting an existing blob.
  @discardableResult func saveURLRecord(_ record:ArtworkURLRecord,address:String)->Bool {
    guard Self.validURL(address),Self.validRecord(record),let sequence=nextSequence(address),
      record.hash.map({object($0) != nil}) ?? (record.negativeStatus != nil),
      let data=try?JSONEncoder().encode(ArtworkObjectReceipt(address:address,sequence:sequence,record:record))else{return false}
    guard markDirty(),write(data,name:receiptName(address,pending:false))else{return false}
    pendingRecords[address]=record;return true
  }
  /// Two exact filenames, no enumeration. Useful when a valid old index does
  /// not yet contain an object whose index commit failed or was interrupted.
  func urlRecord(for address:String)->ArtworkURLRecord? {
    guard Self.validURL(address)else{return nil}
    return receipts(address).filter{validObject($0.record)}.max(by:{$0.sequence<$1.sequence})?.record
  }
  func thumbnail(_ hash:String,size:Int)->Data?{guard Self.validHash(hash),(64...2048).contains(size)else{return nil};return read(hash+"-\(size).png",limit:10_000_000)}
  func saveThumbnail(_ data:Data,hash:String,size:Int){guard Self.validHash(hash),(64...2048).contains(size),data.count<=10_000_000 else{return};_=write(data,name:hash+"-\(size).png")}
  func legacy(_ address:String,size:Int)->Data?{read(Self.hash(Data((String(size)+":"+address).utf8))+".png",limit:10_000_000)}
  private func entryExists(_ name:String)->Bool {
    guard let directory=openDirectory(create:false)else{return false};defer{close(directory)}
    var info=stat();return fstatat(directory,name,&info,AT_SYMLINK_NOFOLLOW)==0
  }
  private func markDirty()->Bool{write(Data("ready-artwork-index-dirty-v1\n".utf8),name:"index-dirty")}
  private func clearDirty()->Bool {
    guard let directory=openDirectory(create:false)else{return false};defer{close(directory)}
    var info=stat()
    if fstatat(directory,"index-dirty",&info,AT_SYMLINK_NOFOLLOW)<0{return errno==ENOENT}
    guard info.st_uid==getuid(),info.st_mode&S_IFMT==S_IFREG,info.st_mode&0o7777==0o600,info.st_nlink==1 else{return false}
    guard unlinkat(directory,"index-dirty",0)==0 else{return false};return fsync(directory)==0
  }
  private func receiptName(_ address:String,pending:Bool)->String{"url-"+Self.hash(Data(address.utf8))+(pending ? ".pending.json":".receipt.json")}
  private func receipt(_ name:String)->ArtworkObjectReceipt? {
    guard let data=read(name,limit:16384),let receipt=try?JSONDecoder().decode(ArtworkObjectReceipt.self,from:data),
      receipt.schema==1,receipt.kind=="ready-artwork-url-object-v1",Self.validURL(receipt.address),Self.validRecord(receipt.record),
      name==receiptName(receipt.address,pending:true) || name==receiptName(receipt.address,pending:false) else{return nil}
    return receipt
  }
  private func receipts(_ address:String)->[ArtworkObjectReceipt]{[receiptName(address,pending:false),receiptName(address,pending:true)].compactMap{receipt($0)}}
  private func nextSequence(_ address:String)->UInt64?{let previous=receipts(address).map(\.sequence).max() ?? 0;return previous==UInt64.max ? nil:previous+1}
  private func validObject(_ record:ArtworkURLRecord)->Bool{if let hash=record.hash{return object(hash) != nil};return record.negativeStatus != nil}
  private func removePending(_ address:String,sequence:UInt64){
    let name=receiptName(address,pending:true)
    guard receipt(name)?.sequence==sequence,let directory=openDirectory(create:false)else{return};defer{close(directory)}
    if unlinkat(directory,name,0)==0{_=fsync(directory)}
  }
  private func recoverReceipts()->ArtworkDiskIndex {
    var result=read("index-recovery.json",limit:16*1024*1024).flatMap(validIndex)
      ?? read("index.json",limit:16*1024*1024).flatMap(validIndex) ?? ArtworkDiskIndex()
    var sequences=[String:UInt64]()
    guard let directory=openDirectory(create:false)else{return result};defer{close(directory)}
    let copy=dup(directory);guard copy>=0 else{return result}
    guard let stream=fdopendir(copy)else{close(copy);return result};defer{closedir(stream)}
    var visited=0,receiptsFound=0
    while let entry=readdir(stream),visited<300000,receiptsFound<100000 {
      visited+=1
      let name=withUnsafePointer(to:&entry.pointee.d_name){pointer in pointer.withMemoryRebound(to:CChar.self,capacity:Int(MAXNAMLEN)+1){String(cString:$0)}}
      guard name.hasPrefix("url-"),(name.hasSuffix(".receipt.json") || name.hasSuffix(".pending.json")),let value=receipt(name),
        value.sequence>=(sequences[value.address] ?? 0),validObject(value.record)else{continue}
      receiptsFound+=1;sequences[value.address]=value.sequence;result.urls[value.address]=value.record
    }
    for (key,var role) in result.roles {
      if let address=role.preferredURL,let hash=result.urls[address]?.hash,object(hash) != nil{role.hash=hash;result.roles[key]=role}
    }
    return result
  }
  private func openDirectory(create:Bool)->Int32?{
    guard let directory,directory.isFileURL,directory.path.hasPrefix("/"),directory.path != "/",
      directory.standardizedFileURL.path==directory.path,directory.resolvingSymlinksInPath().path==directory.path else{return nil}
    if create{try?FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
    let fd=open(directory.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
    guard fd>=0 else{return nil};var info=stat()
    guard fstat(fd,&info)==0,info.st_uid==getuid(),info.st_mode&S_IFMT==S_IFDIR,info.st_mode&0o7777==0o700 else{close(fd);return nil}
    return fd
  }
  private func read(_ name:String,limit:Int)->Data?{
    guard !name.contains("/"),let directory=openDirectory(create:false)else{return nil};defer{close(directory)}
    let fd=openat(directory,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
    guard fd>=0 else{return nil};defer{close(fd)}
    var before=stat(),after=stat()
    guard fstat(fd,&before)==0,before.st_mode&S_IFMT==S_IFREG,before.st_uid==getuid(),before.st_nlink==1,before.st_mode&0o7777==0o600,before.st_size>0,before.st_size<=limit else{return nil}
    var data=Data(),buffer=[UInt8](repeating:0,count:16384)
    while true{let count=Darwin.read(fd,&buffer,buffer.count);if count<0&&errno==EINTR{continue};guard count>=0 else{return nil};if count==0{break};data.append(contentsOf:buffer.prefix(count));guard data.count<=limit else{return nil}}
    guard fstat(fd,&after)==0,before.st_dev==after.st_dev,before.st_ino==after.st_ino,before.st_size==after.st_size,
      before.st_uid==after.st_uid,before.st_nlink==after.st_nlink,before.st_mode==after.st_mode,
      before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec,before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec,data.count==Int(after.st_size)else{return nil}
    return data
  }
  private func write(_ data:Data,name:String)->Bool{
    guard beforeWrite?(name) ?? true,!name.contains("/"),let directory=openDirectory(create:true)else{return false};defer{close(directory)}
    var old=stat()
    if fstatat(directory,name,&old,AT_SYMLINK_NOFOLLOW)==0 {
      guard old.st_mode&S_IFMT==S_IFREG,old.st_uid==getuid(),old.st_mode&0o7777==0o600,old.st_nlink==1 else{return false}
    }else if errno != ENOENT{return false}
    let temporary=".ready-artwork-"+UUID().uuidString.lowercased(),fd=openat(directory,temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
    guard fd>=0 else{return false};var committed=false
    defer{close(fd);if !committed{_=unlinkat(directory,temporary,0)}}
    guard fchmod(fd,0o600)==0 else{return false}
    let success=data.withUnsafeBytes{bytes->Bool in var offset=0;while offset<bytes.count{let count=Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset);if count<0&&errno==EINTR{continue};guard count>0 else{return false};offset+=count};return true}
    guard success,fsync(fd)==0,renameat(directory,temporary,directory,name)==0 else{return false};committed=true
    return fsync(directory)==0
  }
}
