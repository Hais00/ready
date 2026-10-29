// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreFoundation
import CryptoKit
import Darwin

/// Private per-profile/game credential revision. No raw credential, identity,
/// ticket, or digest is included in descriptions, errors, events or logs.
enum SteamNativeCacheRevision {
  enum Mode { case fresh, reuse }
  enum Failure:Error { case unsafeRoot,invalidMarker,unavailable }
  final class Selection:CustomStringConvertible,CustomDebugStringConvertible,CustomReflectable {
    let mode:Mode
    private let root:URL
    private let revision:String
    var description:String{"[private native credential revision]"}
    var debugDescription:String{description}
    var customMirror:Mirror{Mirror(self,children:[:])}
    fileprivate init(root:URL,revision:String,mode:Mode){self.root=root;self.revision=revision;self.mode=mode}
    func recordReady()throws {
      let directory=try openRoot(root);defer{close(directory)}
      _=try readMarker(directory) // Never replace an unsafe existing entry.
      let temporary=".ready-native-revision-"+UUID().uuidString.lowercased()
      let fd=openat(directory,temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
      guard fd>=0 else{throw Failure.unavailable}
      var published=false
      defer{close(fd);if !published{unlinkat(directory,temporary,0)}}
      guard fchmod(fd,0o600)==0 else{throw Failure.unavailable}
      let data=try JSONSerialization.data(withJSONObject:["schema":1,"revision":revision],options:[.sortedKeys])
      try data.withUnsafeBytes{bytes in
        var offset=0
        while offset<bytes.count {
          let count=Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset)
          if count<0&&errno==EINTR{continue}
          guard count>0 else{throw Failure.unavailable};offset+=count
        }
      }
      guard fsync(fd)==0 else{throw Failure.unavailable}
      _=try readMarker(directory)
      guard renameat(directory,temporary,directory,marker)==0 else{throw Failure.unavailable}
      published=true
      guard fsync(directory)==0 else{throw Failure.unavailable}
    }
  }
  private static let marker=".ready-native-credential-revision.json"
  static func select(packet:Data,root:URL)throws->Selection {
    let directory=try openRoot(root);defer{close(directory)}
    let revision=SHA256.hash(data:packet).map{String(format:"%02x",$0)}.joined()
    return Selection(root:root,revision:revision,mode:try readMarker(directory)==revision ? .reuse:.fresh)
  }
  private static func openRoot(_ root:URL)throws->Int32 {
    guard root.isFileURL,root.path.hasPrefix("/"),root.path != "/",root.standardizedFileURL.path==root.path,
      root.resolvingSymlinksInPath().path==root.path else{throw Failure.unsafeRoot}
    let fd=open(root.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
    guard fd>=0 else{throw Failure.unsafeRoot}
    var info=stat()
    guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFDIR,info.st_uid==getuid(),info.st_mode&0o7777==0o700 else{close(fd);throw Failure.unsafeRoot}
    return fd
  }
  private static func readMarker(_ directory:Int32)throws->String? {
    let fd=openat(directory,marker,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC)
    if fd<0{if errno==ENOENT{return nil};throw Failure.invalidMarker}
    defer{close(fd)}
    var info=stat()
    guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_uid==getuid(),info.st_nlink==1,
      info.st_mode&0o7777==0o600,info.st_size>0,info.st_size<=1024 else{throw Failure.invalidMarker}
    var data=Data(),bytes=[UInt8](repeating:0,count:1025)
    while true {
      let count=Darwin.read(fd,&bytes,bytes.count)
      if count<0&&errno==EINTR{continue};guard count>=0 else{throw Failure.invalidMarker}
      if count==0{break};data.append(contentsOf:bytes.prefix(count));guard data.count<=1024 else{throw Failure.invalidMarker}
    }
    guard let value=try?JSONSerialization.jsonObject(with:data)as?[String:Any],Set(value.keys)==Set(["schema","revision"]),
      let schema=value["schema"]as?NSNumber,CFGetTypeID(schema) != CFBooleanGetTypeID(),schema.stringValue=="1",
      let revision=value["revision"]as?String,revision.utf8.count==64,revision.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else{throw Failure.invalidMarker}
    return revision
  }
}
