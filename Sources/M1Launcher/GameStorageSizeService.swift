// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import LauncherCore

/// Only known installation roots are measured, on a utility worker. Startup and
/// page changes use the indexed result, never a scan of arbitrary disks.
final class GameStorageSizeService {
  private struct Entry:Codable{let bytes:UInt64,root:String;let measured:Date;let signature:String?}
  private let io=DispatchQueue(label:"app.ready.installed-size",qos:.utility)
  private let directory:URL?
  private var entries=[String:Entry](),loaded=false
  init(directory:URL?=nil){self.directory=directory}
  func measure(game:Game,variant:GameVariant,refresh:Bool=false,completion:@escaping(UInt64?)->Void){
    guard variant.installed,let root=try?variant.installationDirectory()else{completion(nil);return}
    let key=game.store.rawValue+":"+game.storeID+":"+variant.id
    io.async{[self]in
      load()
      let stamp=Self.signature(root:root,variant:variant,game:game)
      if !refresh,let value=entries[key],value.root==root.path,value.signature==stamp{DispatchQueue.main.async{completion(value.bytes)};return}
      let measured=Self.walk(root)
      let result=stamp==Self.signature(root:root,variant:variant,game:game) ? measured:nil
      if let bytes=result{entries[key]=Entry(bytes:bytes,root:root.path,measured:Date(),signature:stamp);save()}
      DispatchQueue.main.async{completion(result)}
    }
  }
  func invalidate(game:Game){io.async{[self]in load();let prefix=game.store.rawValue+":"+game.storeID+":";entries=entries.filter{!$0.key.hasPrefix(prefix)};save()}}
  private static func signature(root:URL,variant:GameVariant,game:Game)->String{
    var files=[root,root.appendingPathComponent(".DepotDownloader/depot.config")]
    if let executable=variant.executable{files.append(URL(fileURLWithPath:executable))}
    if game.store == .steam{files.append(root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("appmanifest_"+game.storeID+".acf"))}
    return files.map{url in var s=stat();guard lstat(url.path,&s)==0 else{return "missing"};return [String(s.st_dev),String(s.st_ino),String(s.st_size),String(s.st_mtimespec.tv_sec),String(s.st_mtimespec.tv_nsec)].joined(separator:":")}.joined(separator:"|")
  }
  private static func walk(_ root:URL)->UInt64?{
    let fm=FileManager.default;var total:UInt64=0,seen=Set<String>(),failed=false
    guard let items=fm.enumerator(at:root,includingPropertiesForKeys:nil,options:[],errorHandler:{_,_ in failed=true;return false})else{return nil}
    for case let url as URL in items{
      var value=stat();guard lstat(url.path,&value)==0 else{failed=true;break}
      if value.st_mode&S_IFMT==S_IFLNK{continue}
      guard value.st_mode&S_IFMT==S_IFREG else{continue}
      let identity=String(value.st_dev)+":"+String(value.st_ino)
      guard seen.insert(identity).inserted,value.st_size>=0 else{continue}
      let add=UInt64(value.st_size);guard total<=UInt64.max-add else{return nil};total+=add
    }
    return failed ? nil:total
  }
  private func file()->URL?{
    guard let directory,directory.isFileURL,directory.resolvingSymlinksInPath().path==directory.standardizedFileURL.path else{return nil}
    try?FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);var info=stat()
    guard lstat(directory.path,&info)==0,info.st_mode&S_IFMT==S_IFDIR,info.st_uid==getuid(),info.st_mode&0o7777==0o700 else{return nil}
    return directory.appendingPathComponent("installed-sizes.json")
  }
  private func load(){guard !loaded else{return};loaded=true;guard let path=file()else{return};var info=stat();guard lstat(path.path,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_uid==getuid(),info.st_nlink==1,info.st_mode&0o7777==0o600,info.st_size<=4*1024*1024,let data=try?Data(contentsOf:path),let value=try?JSONDecoder().decode([String:Entry].self,from:data)else{return};entries=value}
  private func save(){guard let path=file(),let data=try?JSONEncoder().encode(entries),data.count<=4*1024*1024 else{return};var info=stat();if lstat(path.path,&info)==0{guard info.st_mode&S_IFMT==S_IFREG,info.st_uid==getuid(),info.st_nlink==1,info.st_mode&0o7777==0o600 else{return}};try?AtomicFile.writePrivate(data,to:path)}
}
