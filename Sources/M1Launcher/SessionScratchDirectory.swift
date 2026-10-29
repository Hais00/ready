// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// An opt-in scratch area, not a replacement HOME, installation or save folder.
/// Every component is selected by a no-follow directory FD. Existing private
/// directories are never chmod'ed, removed or adopted from another owner.
enum SessionScratchDirectory {
  enum Failure:Error {case invalidPreference,unsafeDirectory,unavailable}
  static func nativeEnvironment(sessionID:UUID,preferences:UserDefaults = .standard)throws->[String:String]{
    guard let raw=preferences.object(forKey:"readySessionScratchDirectory") else{return [:]}
    guard let path=raw as?String,path.hasPrefix("/"),!path.utf8.contains(0) else{throw Failure.invalidPreference}
    let directory=try prepare(root:URL(fileURLWithPath:path,isDirectory:true),sessionID:sessionID)
    return ["TMPDIR":directory.path+"/","TMP":directory.path,"TEMP":directory.path,
      "READY_NATIVE_SESSION_TMPDIR":directory.path+"/"]
  }
  static func prepare(root:URL,sessionID:UUID)throws->URL {
    guard root.isFileURL,root.path.hasPrefix("/"),!root.path.utf8.contains(0) else{throw Failure.invalidPreference}
    var path=root.standardizedFileURL.path
    guard path != "/" else{throw Failure.invalidPreference}
    // Only Darwin's standard top-level aliases are resolved. A symbolic link
    // anywhere in the selected scratch subtree is still rejected by openat.
    if path=="/tmp" || path.hasPrefix("/tmp/"){path="/private/tmp"+path.dropFirst(4)}
    else if path=="/var" || path.hasPrefix("/var/"){path="/private/var"+path.dropFirst(4)}
    let parts=path.split(separator:"/").map(String.init)
    guard !parts.isEmpty else{throw Failure.invalidPreference}
    var held=[Int32]();defer{for fd in held.reversed(){close(fd)}}
    var parent=Darwin.open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC)
    guard parent>=0 else{throw Failure.unavailable};held.append(parent)
    for (offset,part) in parts.enumerated(){
      if offset==parts.count-1,mkdirat(parent,part,0o700) != 0,errno != EEXIST{throw Failure.unavailable}
      let fd=openat(parent,part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
      guard fd>=0 else{throw Failure.unsafeDirectory};held.append(fd)
      try namedDirectory(parent:parent,name:part,child:fd)
      parent=fd
    }
    let rootFD=parent;try privateDirectory(rootFD)
    let rootPath=try descriptorPath(rootFD)
    let children=[sessionID.uuidString.lowercased(),"tmp"]
    for child in children {
      if mkdirat(parent,child,0o700) != 0,errno != EEXIST{throw Failure.unavailable}
      let fd=openat(parent,child,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
      guard fd>=0 else{throw Failure.unsafeDirectory};held.append(fd)
      try privateDirectory(fd);try namedDirectory(parent:parent,name:child,child:fd);parent=fd
    }
    let actual=try descriptorPath(parent)
    guard try descriptorPath(rootFD)==rootPath,actual.hasPrefix(rootPath+"/"),
      actual.dropFirst(rootPath.count+1).lowercased()==children.joined(separator:"/") else{throw Failure.unsafeDirectory}
    let result=URL(fileURLWithPath:actual,isDirectory:true)
    guard result.resolvingSymlinksInPath().path==actual else{throw Failure.unsafeDirectory}
    return result
  }
  private static func namedDirectory(parent:Int32,name:String,child:Int32)throws{
    var named=stat(),opened=stat()
    guard fstatat(parent,name,&named,AT_SYMLINK_NOFOLLOW)==0,fstat(child,&opened)==0,
      named.st_mode&S_IFMT==S_IFDIR,named.st_dev==opened.st_dev,named.st_ino==opened.st_ino else{throw Failure.unsafeDirectory}
  }
  private static func privateDirectory(_ fd:Int32)throws{
    var value=stat()
    guard fstat(fd,&value)==0,value.st_mode&S_IFMT==S_IFDIR,value.st_uid==getuid(),value.st_mode&0o7777==0o700 else{throw Failure.unsafeDirectory}
  }
  private static func descriptorPath(_ fd:Int32)throws->String{
    var bytes=[CChar](repeating:0,count:Int(PATH_MAX)+1)
    guard fcntl(fd,F_GETPATH,&bytes)==0,let path=String(validatingUTF8:bytes),path.hasPrefix("/"),path != "/" else{throw Failure.unavailable}
    return path
  }
}
