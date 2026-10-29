// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CryptoKit
import Darwin
import ImageIO

extension Notification.Name {static let readyArtworkChanged=Notification.Name("ready.artwork.changed")}
private final class CachedArtwork:NSObject {let image:CGImage;init(_ image:CGImage){self.image=image}}
/// Public artwork only. Bounded memory/network, persistent thumbnails, and no
/// account/profile credentials are added to artwork requests or cache files.
final class ArtworkCache {
  private let memory=NSCache<NSString,CachedArtwork>()
  private let session:URLSession
  private let directory:URL?
  private let networkEnabled:Bool
  private let maximumPixelSize:Int
  private let io=DispatchQueue(label:"app.ready.artwork-cache",qos:.utility)
  private var tasks=[String:URLSessionDataTask]()
  private var pending=[String](),active=Set<String>()
  private var refreshers=[String:()->Void](),failedUntil=[String:Date]()
  private var generation=UUID()
  init(directory:URL?=ArtworkCache.defaultDirectory,session:URLSession = .shared,networkEnabled:Bool=true,maximumPixelSize:Int=1024){
    self.directory=directory;self.session=session;self.networkEnabled=networkEnabled;self.maximumPixelSize=min(2048,max(128,maximumPixelSize))
    memory.countLimit=96;memory.totalCostLimit=64*1024*1024
  }
  static var defaultDirectory:URL? {
    if let path=ProcessInfo.processInfo.environment["READY_ARTWORK_CACHE_ROOT"] ?? UserDefaults.standard.string(forKey:"readyArtworkCacheDirectory") {
      guard path.hasPrefix("/"),path != "/" else{return nil}
      let directory=URL(fileURLWithPath:path,isDirectory:true).standardizedFileURL
      return directory.path == "/" ? nil:directory
    }
    return FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask).first?.resolvingSymlinksInPath().appendingPathComponent("app.ready.artwork-v1",isDirectory:true)
  }
  func image(_ address:String?,refresh:@escaping()->Void)->CGImage? {
    guard let address,address.utf8.count<=4096,let url=URL(string:address),url.scheme?.lowercased()=="https",url.host != nil,url.user==nil,url.password==nil else{return nil}
    if let cached=memory.object(forKey:address as NSString){return cached.image}
    if let until=failedUntil[address],until>Date(){return nil}
    if !active.contains(address) && !pending.contains(address){pending.append(address);refreshers[address]=refresh;drain()}
    return nil
  }
  func image(addresses:[String?],refresh:@escaping()->Void)->CGImage? {
    var seen=Set<String>()
    let candidates=addresses.compactMap{$0}.filter{address in
      guard seen.insert(address).inserted,let url=URL(string:address)else{return false}
      return url.scheme?.lowercased()=="https" && url.host != nil && url.user==nil && url.password==nil
    }
    for address in candidates where (failedUntil[address] ?? .distantPast)<=Date(){
      if let image=image(address,refresh:refresh){return image}
      break // Try the next URL after a failure, not all at once.
    }
    return candidates.compactMap{memory.object(forKey:$0 as NSString)?.image}.first
  }
  func purge(){
    generation=UUID();tasks.values.forEach{$0.cancel()};tasks.removeAll();pending.removeAll();active.removeAll();refreshers.removeAll();failedUntil.removeAll();memory.removeAllObjects()
  }
  private func drain(){
    while active.count<4 && !pending.isEmpty {
      let address=pending.removeFirst(),epoch=generation;active.insert(address)
      io.async{[weak self]in
        guard let self else{return}
        var cached:CGImage?
        if let path=self.diskPath(address),let data=self.safeRead(path){cached=Self.decode(data,maximumPixelSize:self.maximumPixelSize)}
        DispatchQueue.main.async{[weak self]in
          guard let self,self.generation==epoch else{return}
          if let cached{self.finish(address,image:cached,epoch:epoch)}else{self.fetch(address,epoch:epoch)}
        }
      }
    }
  }
  private func fetch(_ address:String,epoch:UUID){
    guard networkEnabled,let url=URL(string:address)else{finish(address,image:nil,epoch:epoch);return}
    var request=URLRequest(url:url,cachePolicy:.returnCacheDataElseLoad,timeoutInterval:15)
    request.setValue("image/*",forHTTPHeaderField:"Accept")
    let task=session.dataTask(with:request){[weak self]data,response,_ in
      guard let self else{return}
      let valid=(response as?HTTPURLResponse).map{(200..<300).contains($0.statusCode)} ?? false
      let data=valid ? data:nil
      self.io.async{[weak self]in
        guard let self else{return};let image=data.flatMap{Self.decode($0,maximumPixelSize:self.maximumPixelSize)}
        if let image,let path=self.diskPath(address),let encoded=Self.png(image){self.save(encoded,to:path)}
        DispatchQueue.main.async{[weak self]in self?.finish(address,image:image,epoch:epoch)}
      }
    }
    tasks[address]=task;task.resume()
  }
  private func finish(_ address:String,image:CGImage?,epoch:UUID){
    guard generation==epoch else{return}
    tasks.removeValue(forKey:address);active.remove(address)
    if let image{memory.setObject(CachedArtwork(image),forKey:address as NSString,cost:image.bytesPerRow*image.height);failedUntil.removeValue(forKey:address)}
    else{failedUntil[address]=Date().addingTimeInterval(60)}
    let refresh=refreshers.removeValue(forKey:address)
    refresh?();NotificationCenter.default.post(name:.readyArtworkChanged,object:self,userInfo:["address":address])
    drain()
  }
  private static func decode(_ data:Data,maximumPixelSize:Int)->CGImage? {
    guard !data.isEmpty,data.count<=10_000_000,let source=CGImageSourceCreateWithData(data as CFData,nil)else{return nil}
    return CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:maximumPixelSize,kCGImageSourceCreateThumbnailWithTransform:true]as CFDictionary)
  }
  private static func png(_ image:CGImage)->Data? {
    let rep=NSBitmapImageRep(cgImage:image);return rep.representation(using:.png,properties:[:])
  }
  private func diskPath(_ address:String)->URL? {
    guard let directory else{return nil}
    return directory.appendingPathComponent(SHA256.hash(data:Data((String(maximumPixelSize)+":"+address).utf8)).map{String(format:"%02x",$0)}.joined()+".png")
  }
  private func safeRead(_ path:URL)->Data? {
    guard let directory else{return nil}
    var parent=stat();guard lstat(directory.path,&parent)==0,parent.st_uid==getuid(),parent.st_mode&S_IFMT==S_IFDIR,parent.st_mode&0o077==0,directory.resolvingSymlinksInPath().path==directory.path else{return nil}
    var info=stat();guard lstat(path.path,&info)==0,info.st_uid==getuid(),info.st_mode&S_IFMT==S_IFREG,info.st_size<=10_000_000 else{return nil}
    return try?Data(contentsOf:path,options:.mappedIfSafe)
  }
  private func save(_ data:Data,to path:URL){
    guard let directory,data.count<=10_000_000 else{return}
    do{
      try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
      var info=stat();guard lstat(directory.path,&info)==0,info.st_uid==getuid(),info.st_mode&S_IFMT==S_IFDIR,info.st_mode&0o077==0,directory.resolvingSymlinksInPath().path==directory.path else{return}
      try data.write(to:path,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
      let keys:Set<URLResourceKey>=[.fileSizeKey,.contentModificationDateKey,.isRegularFileKey]
      let files=(try?FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:Array(keys))) ?? []
      var entries=[(URL,Int,Date)](),total=0
      for file in files where file.pathExtension=="png" {
        var st=stat();guard lstat(file.path,&st)==0,st.st_uid==getuid(),st.st_mode&S_IFMT==S_IFREG else{continue}
        let values=try?file.resourceValues(forKeys:keys),size=values?.fileSize ?? 0;entries.append((file,size,values?.contentModificationDate ?? .distantPast));total+=size
      }
      for entry in entries.sorted(by:{$0.2<$1.2}) where total>256*1024*1024{try?FileManager.default.removeItem(at:entry.0);total-=entry.1}
    }catch{} // Artwork failures never prevent browsing or gameplay.
  }
}
