// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import CoreFoundation
import Darwin

/// Store tools have their own selected component root, independent of engines.
/// This checks the selected manifest's identity/header, not its entire inventory.
/// Full payload verification belongs to component installation/publication.
public enum StoreToolsLocation {
  public enum Failure: Error { case invalidPath, invalidSelector, invalidManifest }

  public static func resolve(stateRoot:URL?=nil,runtimeRoot:URL,
                             environment:[String:String]=ProcessInfo.processInfo.environment) throws -> URL {
    if let explicit=environment["READY_STORE_TOOLS_ROOT"] {
      let path=try absolute(explicit)
      // Explicit legacy overrides may name an existing alias. Freeze its target
      // once before passing it to Python/dotnet; selectors must already be canonical.
      return try baseRoot(path)
    }
    let state=try baseRoot(stateRoot ?? LauncherPaths().root)
    guard let selector=try readSelector(state) else {
      return try baseRoot(runtimeRoot.appendingPathComponent("Tools/StoreBridge"))
    }
    guard let record=try? JSONSerialization.jsonObject(with:selector)as?[String:Any],
      Set(record.keys)==Set(["schema","kind","toolsRoot","manifestSHA256"]),schemaOne(record["schema"]),
      record["kind"]as?String=="ready-store-tools-location-v1",
      let raw=record["toolsRoot"]as?String,let digest=record["manifestSHA256"]as?String,validHash(digest) else{throw Failure.invalidSelector}
    let tools=try canonical(absolute(raw))
    guard let directory=try openDirectory(tools) else{throw Failure.invalidManifest};defer{close(directory)}
    var info=stat()
    guard fstat(directory,&info)==0,info.st_uid==getuid(),info.st_mode&0o022==0 else{throw Failure.invalidManifest}
    guard let data=try read("manifest.json",at:directory,privateFile:false,limit:16*1024*1024),
      SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined()==digest,
      let manifest=try? JSONSerialization.jsonObject(with:data)as?[String:Any],schemaOne(manifest["schema"]),
      manifest["kind"]as?String=="ready-local-steam-tools-v1",boolean(manifest["localOnly"])==true,
      boolean(manifest["binaryDistributionApproved"])==false else{throw Failure.invalidManifest}
    return tools
  }
  private static func absolute(_ raw:String) throws -> URL {
    guard raw.hasPrefix("/"),raw != "/",!raw.utf8.contains(0),
      raw.split(separator:"/",omittingEmptySubsequences:false).dropFirst().allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".."}) else{throw Failure.invalidPath}
    return URL(fileURLWithPath:raw)
  }
  private static func canonical(_ url:URL) throws -> URL {
    guard url.isFileURL else{throw Failure.invalidPath}
    let value=try absolute(url.path)
    guard value.standardizedFileURL.path==url.path,value.resolvingSymlinksInPath().path==url.path else{throw Failure.invalidPath}
    return value
  }
  /// Caller-supplied data roots may use OS aliases (/var, /tmp), including a
  /// not-yet-created suffix. Freeze only that base once; inner selectors and
  /// directories still use NOFOLLOW. URL.realpath fallback alone misses aliases
  /// when the complete supplied path does not exist yet.
  private static func baseRoot(_ supplied:URL) throws -> URL {
    guard supplied.isFileURL else{throw Failure.invalidPath}
    var existing=try absolute(supplied.standardizedFileURL.path),suffix=[String]()
    while true {
      var info=stat()
      if lstat(existing.path,&info)==0{break}
      guard errno==ENOENT,existing.path != "/" else{throw Failure.invalidPath}
      suffix.insert(existing.lastPathComponent,at:0);existing=existing.deletingLastPathComponent()
    }
    guard let resolved=realpath(existing.path,nil) else{throw Failure.invalidPath};defer{free(resolved)}
    var result=URL(fileURLWithPath:String(cString:resolved))
    for part in suffix{result.appendPathComponent(part)}
    return result
  }
  private static func schemaOne(_ value:Any?)->Bool {
    guard let number=value as?NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID() else{return false}
    return number.stringValue=="1"
  }
  private static func boolean(_ value:Any?)->Bool? {
    guard let number=value as?NSNumber,CFGetTypeID(number)==CFBooleanGetTypeID() else{return nil};return number.boolValue
  }
  private static func validHash(_ value:String)->Bool {value.utf8.count==64 && value.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)})}
  /// No component is followed through a symbolic-link directory. Only ENOENT
  /// means absent; permissions, aliases, non-directories and I/O errors fail closed.
  private static func openDirectory(_ path:URL) throws -> Int32? {
    var descriptor=Darwin.open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC)
    guard descriptor>=0 else{throw Failure.invalidPath}
    for part in path.pathComponents.dropFirst() {
      let next=openat(descriptor,part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);let error=errno
      close(descriptor)
      if next<0 {if error==ENOENT{return nil};throw Failure.invalidPath};descriptor=next
    }
    return descriptor
  }
  private static func readSelector(_ state:URL) throws -> Data? {
    guard var directory=try openDirectory(state) else{return nil}
    defer{close(directory)}
    try privateDirectory(directory)
    for name in ["Components","StoreBridge"] {
      let next=openat(directory,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);let error=errno
      if next<0 {if error==ENOENT{return nil};throw Failure.invalidSelector}
      close(directory);directory=next;try privateDirectory(directory)
    }
    return try read("selected.json",at:directory,privateFile:true,limit:16384)
  }
  private static func privateDirectory(_ descriptor:Int32) throws {
    var info=stat()
    guard fstat(descriptor,&info)==0,info.st_uid==getuid(),info.st_mode&S_IFMT==S_IFDIR,info.st_mode&0o077==0 else{throw Failure.invalidSelector}
  }
  private static func read(_ name:String,at directory:Int32,privateFile:Bool,limit:Int) throws -> Data? {
    let descriptor=openat(directory,name,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);let error=errno
    if descriptor<0 {if error==ENOENT{return nil};throw Failure.invalidSelector}
    defer{close(descriptor)}
    var before=stat(),after=stat()
    guard fstat(descriptor,&before)==0,before.st_uid==getuid(),before.st_mode&S_IFMT==S_IFREG,
      before.st_mode & (privateFile ? 0o077:0o022)==0,before.st_size>0,before.st_size<=limit else{throw Failure.invalidSelector}
    var data=Data(),buffer=[UInt8](repeating:0,count:8192)
    while true {
      let count=Darwin.read(descriptor,&buffer,buffer.count)
      if count<0&&errno==EINTR{continue}
      guard count>=0,data.count+max(0,count)<=limit else{throw Failure.invalidSelector}
      if count==0{break};data.append(contentsOf:buffer.prefix(count))
    }
    guard fstat(descriptor,&after)==0,before.st_dev==after.st_dev,before.st_ino==after.st_ino,before.st_size==after.st_size,
      before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec,before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec,
      data.count==before.st_size else{throw Failure.invalidSelector}
    return data
  }
}
