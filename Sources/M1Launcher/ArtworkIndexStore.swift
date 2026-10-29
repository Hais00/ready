// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import Darwin

struct ArtworkURLRecord:Codable {
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
/// O(1) key lookup. No directory enumeration, TTL, disk eviction or account data.
/// All methods are called only on ArtworkCache's serial background I/O queue.
final class ArtworkIndexStore {
  private let directory:URL?
  private var writable=true
  init(_ directory:URL?){self.directory=directory}
  static func hash(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
  private static func validHash(_ hash:String)->Bool{hash.count==64 && hash.utf8.allSatisfy{(48...57).contains($0)||(97...102).contains($0)}}
  func load()->ArtworkDiskIndex {
    guard let data=read("index.json",limit:16*1024*1024)else{return ArtworkDiskIndex()}
    guard let value=try?JSONDecoder().decode(ArtworkDiskIndex.self,from:data),value.schema==1,value.kind=="ready-artwork-index-v1",
      value.urls.count<=100000,value.roles.count<=100000,
      value.urls.values.allSatisfy({($0.hash.map(Self.validHash) ?? true) && ($0.file==nil || $0.file==$0.hash.map{$0+".asset"})}),value.roles.values.allSatisfy({$0.hash.map(Self.validHash) ?? true})else{writable=false;return ArtworkDiskIndex()}
    return value
  }
  func save(_ index:ArtworkDiskIndex){
    guard writable,let data=try?JSONEncoder().encode(index),data.count<=16*1024*1024 else{return}
    _=write(data,name:"index.json")
  }
  func object(_ hash:String)->Data?{
    guard Self.validHash(hash),let data=read(hash+".asset",limit:10_000_000),Self.hash(data)==hash else{return nil};return data
  }
  func saveObject(_ data:Data,hash:String)->Bool{
    guard Self.validHash(hash),data.count<=10_000_000,Self.hash(data)==hash else{return false}
    if object(hash) != nil{return true};return write(data,name:hash+".asset")
  }
  func thumbnail(_ hash:String,size:Int)->Data?{guard Self.validHash(hash),(64...2048).contains(size)else{return nil};return read(hash+"-\(size).png",limit:10_000_000)}
  func saveThumbnail(_ data:Data,hash:String,size:Int){guard Self.validHash(hash),(64...2048).contains(size),data.count<=10_000_000 else{return};_=write(data,name:hash+"-\(size).png")}
  func legacy(_ address:String,size:Int)->Data?{
    let name=Self.hash(Data((String(size)+":"+address).utf8))+".png"
    return read(name,limit:10_000_000)
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
    guard fd>=0 else{if errno != ENOENT && name=="index.json"{writable=false};return nil};defer{close(fd)}
    var before=stat(),after=stat()
    guard fstat(fd,&before)==0,before.st_mode&S_IFMT==S_IFREG,before.st_uid==getuid(),before.st_nlink==1,before.st_mode&0o7777==0o600,before.st_size>0,before.st_size<=limit else{if name=="index.json"{writable=false};return nil}
    var data=Data(),buffer=[UInt8](repeating:0,count:16384)
    while true{let count=Darwin.read(fd,&buffer,buffer.count);if count<0&&errno==EINTR{continue};guard count>=0 else{return nil};if count==0{break};data.append(contentsOf:buffer.prefix(count));guard data.count<=limit else{return nil}}
    guard fstat(fd,&after)==0,before.st_dev==after.st_dev,before.st_ino==after.st_ino,before.st_size==after.st_size,
      before.st_uid==after.st_uid,before.st_nlink==after.st_nlink,before.st_mode==after.st_mode,
      before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec,before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec,
      data.count==Int(after.st_size)else{return nil}
    return data
  }
  private func write(_ data:Data,name:String)->Bool{
    guard writable,!name.contains("/"),let directory=openDirectory(create:true)else{return false};defer{close(directory)}
    var old=stat()
    if fstatat(directory,name,&old,AT_SYMLINK_NOFOLLOW)==0 {
      guard old.st_mode&S_IFMT==S_IFREG,old.st_uid==getuid(),old.st_mode&0o7777==0o600,old.st_nlink==1 else{return false}
    }else if errno != ENOENT{return false}
    let temporary=".ready-artwork-"+UUID().uuidString.lowercased()
    let fd=openat(directory,temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
    guard fd>=0 else{return false};var committed=false
    defer{close(fd);if !committed{_=unlinkat(directory,temporary,0)}}
    guard fchmod(fd,0o600)==0 else{return false}
    let success=data.withUnsafeBytes{bytes->Bool in var offset=0;while offset<bytes.count{let count=Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset);if count<0&&errno==EINTR{continue};guard count>0 else{return false};offset+=count};return true}
    guard success,fsync(fd)==0,renameat(directory,temporary,directory,name)==0 else{return false};committed=true
    return fsync(directory)==0
  }
}
