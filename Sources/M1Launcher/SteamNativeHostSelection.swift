// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import CoreFoundation
import LauncherCore

/// User native components are independent of engines and StoreBridge selection.
/// An invalid present selection never silently chooses a legacy binding.
enum SteamNativeHostSelection {
  enum Failure: Error { case missing, invalid, fixture }
  static func load(runtimeRoot:URL,gameID:String,stateRoot:URL?=nil,
                   environment:[String:String]=ProcessInfo.processInfo.environment) throws -> SteamNativeHostProcess.Binding {
    guard !gameID.isEmpty,gameID.utf8.allSatisfy({(48...57).contains($0)}),let app=UInt32(gameID),app>0 else{throw Failure.invalid}
    let explicit=environment["READY_STEAM_NATIVE_BINDING"],explicitHash=environment["READY_STEAM_NATIVE_BINDING_SHA256"]
    if explicit != nil || explicitHash != nil {
      guard let explicit,let explicitHash else{throw Failure.invalid}
      return try production(absolute(explicit),hash:explicitHash)
    }
    let state=try baseRoot(stateRoot ?? LauncherPaths().root)
    if let directory=try userDirectory(state,components:["Components","SteamNativeHost",String(app)]) {
      defer{close(directory)}
      if let bytes=try readSelector(directory){
        return try selected(bytes,under:state.appendingPathComponent("Components/SteamNativeHost/\(app)"))
      }
    }
    // Preserve explicit historical override aliases, resolved once. A new
    // StoreBridge selector never changes the native component's legacy lookup.
    let tools:URL
    if let raw=environment["READY_STORE_TOOLS_ROOT"]{tools=try baseRoot(absolute(raw))}
    else{tools=try baseRoot(runtimeRoot.appendingPathComponent("Tools/StoreBridge"))}
    let root=tools.appendingPathComponent("NativeSteamHost/\(app)")
    guard let directory=try openDirectory(root) else{throw Failure.missing};defer{close(directory)}
    guard let bytes=try readSelector(directory) else{throw Failure.missing}
    return try selected(bytes,under:root)
  }
  private static func selected(_ bytes:Data,under root:URL) throws -> SteamNativeHostProcess.Binding {
    guard let value=try? JSONSerialization.jsonObject(with:bytes)as?[String:Any],
      Set(value.keys)==Set(["schema","kind","manifestPath","manifestSHA256"]),
      let schema=value["schema"]as?NSNumber,CFGetTypeID(schema) != CFBooleanGetTypeID(),schema.stringValue=="1",
      value["kind"]as?String=="ready-native-steam-host-selection-v1",
      let relative=value["manifestPath"]as?String,!relative.hasPrefix("/"),!relative.contains("\\"),!relative.utf8.contains(0),
      relative.split(separator:"/",omittingEmptySubsequences:false).allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".."}),
      let hash=value["manifestSHA256"]as?String else{throw Failure.invalid}
    let path=root.appendingPathComponent(relative)
    guard path.path.hasPrefix(root.path+"/") else{throw Failure.invalid}
    return try production(path,hash:hash)
  }
  private static func production(_ path:URL,hash:String) throws -> SteamNativeHostProcess.Binding {
    guard hash.utf8.count==64,hash.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else{throw Failure.invalid}
    let binding=try SteamNativeHostProcess.Binding.load(manifestURL:canonical(path),expectedSHA256:hash)
    guard !binding.fixtureOnly else{throw Failure.fixture};return binding
  }
  private static func absolute(_ raw:String) throws -> URL {
    guard raw.hasPrefix("/"),raw != "/",!raw.utf8.contains(0),
      raw.split(separator:"/",omittingEmptySubsequences:false).dropFirst().allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".."}) else{throw Failure.invalid}
    return URL(fileURLWithPath:raw)
  }
  private static func canonical(_ path:URL) throws -> URL {
    guard path.isFileURL else{throw Failure.invalid}
    let checked=try absolute(path.path)
    guard checked.standardizedFileURL.path==path.path,checked.resolvingSymlinksInPath().path==path.path else{throw Failure.invalid};return checked
  }
  private static func baseRoot(_ supplied:URL) throws -> URL {
    guard supplied.isFileURL else{throw Failure.invalid}
    var existing=try absolute(supplied.standardizedFileURL.path),suffix=[String]()
    while true {
      var info=stat();if lstat(existing.path,&info)==0{break}
      guard errno==ENOENT,existing.path != "/" else{throw Failure.invalid}
      suffix.insert(existing.lastPathComponent,at:0);existing=existing.deletingLastPathComponent()
    }
    guard let resolved=realpath(existing.path,nil) else{throw Failure.invalid};defer{free(resolved)}
    var result=URL(fileURLWithPath:String(cString:resolved));for part in suffix{result.appendPathComponent(part)};return result
  }
  private static func openDirectory(_ path:URL) throws -> Int32? {
    var fd=Darwin.open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC);guard fd>=0 else{throw Failure.invalid}
    for component in path.pathComponents.dropFirst() {
      let next=openat(fd,component,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);let error=errno;close(fd)
      if next<0{if error==ENOENT{return nil};throw Failure.invalid};fd=next
    }
    return fd
  }
  private static func userDirectory(_ state:URL,components:[String]) throws -> Int32? {
    guard var fd=try openDirectory(state) else{return nil};var retained=false
    defer{if !retained{close(fd)}}
    try privateDirectory(fd)
    for component in components {
      let next=openat(fd,component,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);let error=errno
      if next<0{if error==ENOENT{return nil};throw Failure.invalid}
      close(fd);fd=next;try privateDirectory(fd)
    }
    retained=true;return fd
  }
  private static func privateDirectory(_ fd:Int32) throws {
    var info=stat();guard fstat(fd,&info)==0,info.st_uid==getuid(),info.st_mode&S_IFMT==S_IFDIR,info.st_mode&0o077==0 else{throw Failure.invalid}
  }
  private static func readSelector(_ directory:Int32) throws -> Data? {
    let fd=openat(directory,"selected.json",O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);let error=errno
    if fd<0{if error==ENOENT{return nil};throw Failure.invalid};defer{close(fd)}
    var before=stat(),after=stat()
    guard fstat(fd,&before)==0,before.st_mode&S_IFMT==S_IFREG,before.st_uid==getuid(),before.st_mode&0o077==0,
      before.st_size>0,before.st_size<=16384 else{throw Failure.invalid}
    var data=Data(),buffer=[UInt8](repeating:0,count:4096)
    while true {
      let count=Darwin.read(fd,&buffer,buffer.count);if count<0&&errno==EINTR{continue}
      guard count>=0,data.count+max(0,count)<=16384 else{throw Failure.invalid}
      if count==0{break};data.append(contentsOf:buffer.prefix(count))
    }
    guard fstat(fd,&after)==0,before.st_dev==after.st_dev,before.st_ino==after.st_ino,before.st_size==after.st_size,
      before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec,before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec,
      data.count==before.st_size else{throw Failure.invalid};return data
  }
}
