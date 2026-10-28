// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import LauncherCore

/// Creates only the private native Steam subtree. Directory descriptors select
/// real entries; F_GETPATH supplies their actual spelling on case-insensitive
/// filesystems instead of treating a differently cased URL as canonical.
enum SteamNativeStateDirectory {
  enum Failure:Error {case invalidRoot,invalidGameID,unsafeDirectory,unavailable}

  static func prepare(paths:LauncherPaths,profile:UUID,gameID:UInt32) throws -> URL {
    guard gameID>0 else{throw Failure.invalidGameID}
    guard paths.root.isFileURL,paths.root.path.hasPrefix("/"),paths.root.path != "/",!paths.root.path.utf8.contains(0),
      let raw=realpath(paths.root.standardizedFileURL.path,nil) else{throw Failure.invalidRoot}
    let frozen=String(cString:raw);free(raw)
    // Resolve the caller's base once (including OS /var aliases), then refuse
    // symbolic links in every opened base component and every private child.
    let root=try openRoot(frozen)
    var held=[root];defer{for fd in held.reversed(){close(fd)}}
    try privateDirectory(root)
    let basePath=try descriptorPath(root)
    let components=["Profiles",profile.uuidString,"Steam","Native",String(gameID)]
    var parent=root
    for component in components {
      if mkdirat(parent,component,0o700) != 0,errno != EEXIST{throw Failure.unavailable}
      let child=openat(parent,component,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
      guard child>=0 else{throw Failure.unsafeDirectory}
      held.append(child)
      try privateDirectory(child)
      var entry=stat(),opened=stat()
      guard fstatat(parent,component,&entry,AT_SYMLINK_NOFOLLOW)==0,fstat(child,&opened)==0,
        entry.st_mode&S_IFMT==S_IFDIR,entry.st_dev==opened.st_dev,entry.st_ino==opened.st_ino else{throw Failure.unsafeDirectory}
      parent=child
    }
    // Keep the complete chain open until the final descriptor yields its actual
    // pathname. Never lowercase a supplied URL to manufacture canonicality.
    let actual=try descriptorPath(parent)
    guard try descriptorPath(root)==basePath,actual.hasPrefix(basePath+"/") else{throw Failure.unsafeDirectory}
    let relative=actual.dropFirst(basePath.count+1).split(separator:"/").map(String.init)
    guard relative.count==components.count,zip(relative,components).allSatisfy({$0.0.caseInsensitiveCompare($0.1) == .orderedSame}) else{throw Failure.unsafeDirectory}
    let result=URL(fileURLWithPath:actual,isDirectory:true)
    guard result.standardizedFileURL.path==actual,result.resolvingSymlinksInPath().path==actual else{throw Failure.unsafeDirectory}
    // Reopen from the pinned base without following links to confirm that the
    // returned pathname still identifies the directory selected by the FD.
    var check=root,temporary=[Int32]()
    defer{for fd in temporary.reversed(){close(fd)}}
    for component in relative {
      let next=openat(check,component,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
      guard next>=0 else{throw Failure.unsafeDirectory};temporary.append(next);try privateDirectory(next);check=next
    }
    var first=stat(),last=stat()
    guard fstat(parent,&first)==0,fstat(check,&last)==0,first.st_dev==last.st_dev,first.st_ino==last.st_ino else{throw Failure.unsafeDirectory}
    return result
  }
  private static func openRoot(_ path:String)throws->Int32 {
    var fd=Darwin.open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC);guard fd>=0 else{throw Failure.unavailable}
    for component in path.split(separator:"/") {
      let next=openat(fd,String(component),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
      close(fd);guard next>=0 else{throw Failure.invalidRoot};fd=next
    }
    return fd
  }
  private static func privateDirectory(_ fd:Int32)throws {
    var info=stat()
    guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFDIR,info.st_uid==getuid(),info.st_mode&0o7777==0o700 else{throw Failure.unsafeDirectory}
  }
  private static func descriptorPath(_ fd:Int32)throws->String {
    var bytes=[CChar](repeating:0,count:Int(PATH_MAX)+1)
    guard fcntl(fd,F_GETPATH,&bytes)==0,let path=String(validatingUTF8:bytes),path.hasPrefix("/"),path != "/" else{throw Failure.unavailable}
    return path
  }
}
