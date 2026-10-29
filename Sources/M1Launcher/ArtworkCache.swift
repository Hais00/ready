// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CryptoKit
import Darwin
import ImageIO
import LauncherCore

extension Notification.Name {static let readyArtworkChanged=Notification.Name("ready.artwork.changed")}
private final class CachedArtwork:NSObject{let image:CGImage;init(_ image:CGImage){self.image=image}}
/// Main-thread UI facade; disk reads, hashing and image decoding use serial I/O.
/// Valid disk bindings never expire. Only explicit detail revalidation replaces
/// a good binding; warming fills missing entries and never enumerates a folder.
final class ArtworkCache {
  private struct Job{let key:String,gameID:String,role:GameArtwork.Role;var candidates:[String];let force:Bool;var priority:Bool}
  private let memory=NSCache<NSString,CachedArtwork>(),session:URLSession,store:ArtworkIndexStore
  private let networkEnabled:Bool,maximumPixelSize:Int
  private let io=DispatchQueue(label:"app.ready.artwork-index.io",qos:.utility)
  private var index=ArtworkDiskIndex(),loaded=false
  private var startup=[()->Void](),jobs=[String:Job](),pending=[String](),active=Set<String>(),tasks=[String:URLSessionDataTask]()
  private var refreshers=[String:()->Void](),warmFinished=Set<String>(),deferred=[String:Job](),revisions=[String:UInt64]()
  private var diskLoading=Set<String>()
  private var generation=UUID(),persisting=false,indexRevision:UInt64=0
  init(directory:URL?=ArtworkCache.defaultDirectory,session:URLSession = ArtworkCache.publicSession,networkEnabled:Bool=true,maximumPixelSize:Int=2048){
    self.session=session;store=ArtworkIndexStore(directory);self.networkEnabled=networkEnabled;self.maximumPixelSize=min(2048,max(128,maximumPixelSize))
    memory.countLimit=160;memory.totalCostLimit=96*1024*1024
    io.async{[weak self]in guard let self else{return};let value=self.store.load();DispatchQueue.main.async{[weak self]in guard let self else{return};self.index=value;self.loaded=true;let actions=self.startup;self.startup.removeAll();actions.forEach{$0()}}}
  }
  static let publicSession:URLSession = {
    let config=URLSessionConfiguration.ephemeral;config.httpCookieStorage=nil;config.urlCredentialStorage=nil
    config.urlCache=nil;config.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration:config)
  }()
  static var defaultDirectory:URL?{
    if let path=ProcessInfo.processInfo.environment["READY_ARTWORK_CACHE_ROOT"] ?? UserDefaults.standard.string(forKey:"readyArtworkCacheDirectory"){
      guard path.hasPrefix("/"),path != "/" else{return nil}
      let normalized=URL(fileURLWithPath:path,isDirectory:true).standardizedFileURL
      guard normalized.path != "/" else{return nil};return normalized
    }
    return FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask).first?.resolvingSymlinksInPath().appendingPathComponent("app.ready.artwork-v1",isDirectory:true)
  }
  func prepare(games:[Game],visibleGameIDs:[String]=[]){
    whenLoaded{[weak self]in guard let self else{return};let visible=Set(visibleGameIDs)
      for game in games.prefix(20000).sorted(by:{visible.contains($0.id) && !visible.contains($1.id)}){for role in GameArtwork.Role.allCases{self.bind(game,role:role);self.enqueue(gameID:game.id,role:role,force:false,priority:visible.contains(game.id))}}
    }
  }
  func prefetch(game:Game){whenLoaded{[weak self]in guard let self else{return};for role in GameArtwork.Role.allCases{self.bind(game,role:role);self.enqueue(gameID:game.id,role:role,force:false,priority:true)}}}
  /// Called only by the detail-open flow, after showing its existing cache.
  /// Checks icon AND banner even if their URL strings have not changed.
  func revalidate(game:Game){whenLoaded{[weak self]in guard let self else{return};for role in [GameArtwork.Role.icon,.banner,.card]{self.bind(game,role:role);self.enqueue(gameID:game.id,role:role,force:true,priority:true)}}}
  func hasCachedImage(gameID:String,role:GameArtwork.Role)->Bool{index.roles[key(gameID,role)]?.hash != nil}
  func revision(gameID:String,role:GameArtwork.Role)->UInt64{revisions[key(gameID,role)] ?? 0}
  func image(for game:Game,role:GameArtwork.Role,refresh:@escaping()->Void)->CGImage?{
    let binding=key(game.id,role)
    if !loaded{whenLoaded{[weak self]in _=self?.image(for:game,role:role,refresh:refresh)};return nil}
    bind(game,role:role)
    if let hash=index.roles[binding]?.hash,let value=memory.object(forKey:memoryKey(hash,role)as NSString){return value.image}
    refreshers[binding]=refresh;enqueue(gameID:game.id,role:role,force:false,priority:true);return nil
  }
  func image(_ address:String?,refresh:@escaping()->Void)->CGImage?{image(addresses:[address],refresh:refresh)}
  func image(addresses:[String?],refresh:@escaping()->Void)->CGImage?{
    let candidates=addresses.compactMap{$0}.filter(Self.validURL),id="legacy:"+ArtworkIndexStore.hash(Data(candidates.joined(separator:"\n").utf8)),binding=key(id,.card)
    guard !candidates.isEmpty else{return nil}
    guard loaded else{whenLoaded{[weak self]in _=self?.image(addresses:addresses,refresh:refresh)};return nil}
    if index.roles[binding]==nil{index.roles[binding]=ArtworkRoleRecord(gameID:id,role:.card,candidates:candidates);changedIndex()}
    if let hash=index.roles[binding]?.hash,let value=memory.object(forKey:memoryKey(hash,.card)as NSString){return value.image}
    refreshers[binding]=refresh;enqueue(gameID:id,role:.card,force:false,priority:true);return nil
  }
  /// Releases RAM and owned requests only. The durable index, positive bytes
  /// and persistent negatives remain intact, with no disk eviction or TTL.
  func purge(){generation=UUID();tasks.values.forEach{$0.cancel()};tasks.removeAll();pending.removeAll();active.removeAll();jobs.removeAll();deferred.removeAll();refreshers.removeAll();warmFinished.removeAll();diskLoading.removeAll();startup.removeAll();memory.removeAllObjects()}
  private func whenLoaded(_ action:@escaping()->Void){if loaded{action()}else{startup.append(action)}}
  private func key(_ game:String,_ role:GameArtwork.Role)->String{game+"\u{1f}"+role.rawValue}
  private func size(_ role:GameArtwork.Role)->Int{switch role{case .icon:return 128;case .card:return min(maximumPixelSize,1024);case .banner:return maximumPixelSize}}
  private func memoryKey(_ hash:String,_ role:GameArtwork.Role)->String{hash+":"+String(size(role))}
  private static func validURL(_ value:String)->Bool{guard value.utf8.count<=4096,let url=URL(string:value)else{return false};return url.scheme?.lowercased()=="https" && url.host != nil && url.user==nil && url.password==nil}
  private func bind(_ game:Game,role:GameArtwork.Role){
    let id=key(game.id,role),candidates=GameArtwork.candidates(for:game,role:role).filter(Self.validURL)
    if var previous=index.roles[id]{if previous.candidates != candidates{previous.candidates=candidates;index.roles[id]=previous;changedIndex()}}
    else{index.roles[id]=ArtworkRoleRecord(gameID:game.id,role:role,candidates:candidates);changedIndex()}
  }
  private func enqueue(gameID:String,role:GameArtwork.Role,force:Bool,priority:Bool){
    let id=key(gameID,role)
    guard let record=index.roles[id],!record.candidates.isEmpty || record.hash != nil else{return}
    if !force,let hash=record.hash,let address=record.preferredURL {
      guard priority || refreshers[id] != nil else{return}
      guard memory.object(forKey:memoryKey(hash,role)as NSString)==nil,diskLoading.insert(id).inserted else{return}
      let epoch=generation
      // Cache hits never queue behind slow network jobs. Decode directly on the
      // serial disk worker, then publish only this binding's RAM availability.
      load(hash:hash,role:role){[weak self]image in
        guard let self,self.generation==epoch else{return};self.diskLoading.remove(id)
        guard self.index.roles[id]?.hash==hash else{return}
        guard let image else {
          // An indexed name without readable bytes is a cache miss, not a
          // reason to remain permanently blank. Keep the binding until a
          // decoded replacement succeeds; never invalidate a good image.
          if self.jobs[id]==nil,let current=self.index.roles[id] {
            var seen=Set<String>();let candidates=([address]+current.candidates).filter{seen.insert($0).inserted}
            self.jobs[id]=Job(key:id,gameID:gameID,role:role,candidates:candidates,force:false,priority:true)
            self.pending.insert(id,at:0);self.drain()
          }
          return
        }
        let absent=self.memory.object(forKey:self.memoryKey(hash,role)as NSString)==nil
        if absent{self.memory.setObject(CachedArtwork(image),forKey:self.memoryKey(hash,role)as NSString,cost:image.bytesPerRow*image.height)}
        if absent || self.refreshers[id] != nil {
          self.revisions[id,default:0]+=1;self.refreshers.removeValue(forKey:id)?()
          NotificationCenter.default.post(name:.readyArtworkChanged,object:self,userInfo:["address":address,"gameID":gameID,"role":role.rawValue,"revision":self.revisions[id] ?? 0,"changed":false,"loaded":true])
        }
      }
      return
    }
    if !force,record.hash==nil,warmFinished.contains(id){return}
    if !force,let hash=record.hash,memory.object(forKey:memoryKey(hash,role)as NSString) != nil{return}
    // Metadata may reorder different Steam assets. Revalidate the selected
    // asset itself; a transient failure must not replace it with another image.
    let candidates:[String]
    if force,record.hash != nil,let preferred=record.preferredURL,record.candidates.contains(preferred){candidates=[preferred]}
    else{candidates=record.candidates}
    let job=Job(key:id,gameID:gameID,role:role,candidates:candidates,force:force,priority:priority)
    if let existing=jobs[id]{
      if force{if !existing.force || existing.candidates != job.candidates{deferred[id]=job}}
      else if priority && !existing.priority {var upgraded=existing;upgraded.priority=true;jobs[id]=upgraded;tasks[id]?.priority=URLSessionTask.defaultPriority;if let i=pending.firstIndex(of:id){pending.remove(at:i);pending.insert(id,at:0)}}
      return
    }
    jobs[id]=job;if priority{pending.insert(id,at:0)}else{pending.append(id)};drain()
  }
  private func drain(){while active.count<2,!pending.isEmpty{let id=pending.removeFirst();guard let job=jobs[id]else{continue};active.insert(id);let epoch=generation
      if !job.force,let record=index.roles[id],let hash=record.hash,let url=record.preferredURL {load(hash:hash,role:job.role){[weak self]image in guard let self,self.generation==epoch else{return};if let image{self.finish(job,url:url,hash:hash,image:image,remote:false,epoch:epoch)}else{self.resolve(job,position:0,epoch:epoch)}}}
      else{resolve(job,position:0,epoch:epoch)}
    }}
  private func resolve(_ job:Job,position:Int,epoch:UUID){
    guard generation==epoch else{return}
    guard position<job.candidates.count else{finish(job,url:nil,hash:nil,image:nil,remote:job.force,epoch:epoch);return}
    let address=job.candidates[position],record=index.urls[address]
    if !job.force,let hash=record?.hash {load(hash:hash,role:job.role){[weak self]image in guard let self,self.generation==epoch else{return};if let image{self.finish(job,url:address,hash:hash,image:image,remote:false,epoch:epoch)}else{self.fetch(job,address:address,position:position,epoch:epoch)}};return}
    if !job.force,record?.negativeStatus != nil{resolve(job,position:position+1,epoch:epoch);return}
    // Adopt only an exact known legacy URL filename, never scan old folders.
    if !job.force,record==nil {io.async{[weak self]in guard let self else{return};let data=self.store.legacy(address,size:1024);let image=data.flatMap{Self.decode($0,maximumPixelSize:self.size(job.role))};let hash=data.map(ArtworkIndexStore.hash);if let data,let hash,let image{_=self.store.saveObject(data,hash:hash);if let png=Self.png(image){self.store.saveThumbnail(png,hash:hash,size:self.size(job.role))}}
        DispatchQueue.main.async{[weak self]in guard let self,self.generation==epoch else{return};if let hash,let image{self.index.urls[address]=ArtworkURLRecord(hash:hash);self.changedIndex();self.finish(job,url:address,hash:hash,image:image,remote:false,epoch:epoch)}else{self.fetch(job,address:address,position:position,epoch:epoch)}}};return}
    fetch(job,address:address,position:position,epoch:epoch)
  }
  private func fetch(_ job:Job,address:String,position:Int,epoch:UUID){
    guard networkEnabled,Self.validURL(address),let url=URL(string:address)else{resolve(job,position:position+1,epoch:epoch);return}
    var request=URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:15);request.httpShouldHandleCookies=false;request.networkServiceType = .background
    request.setValue("image/*",forHTTPHeaderField:"Accept")
    if job.force,let old=index.urls[address]{if let tag=Self.header(old.etag){request.setValue(tag,forHTTPHeaderField:"If-None-Match")};if let date=Self.header(old.lastModified){request.setValue(date,forHTTPHeaderField:"If-Modified-Since")}}
    let prior=index.urls[address]
    let task=session.dataTask(with:request){[weak self]data,response,_ in guard let self else{return};let http=response as?HTTPURLResponse,status=http?.statusCode ?? 0
      if status==304,let hash=prior?.hash {self.load(hash:hash,role:job.role){[weak self]image in guard let self,self.generation==epoch else{return};if let image{var value=prior!;value.etag=Self.header(http?.value(forHTTPHeaderField:"ETag")) ?? value.etag;value.lastModified=Self.header(http?.value(forHTTPHeaderField:"Last-Modified")) ?? value.lastModified;self.index.urls[address]=value;self.changedIndex();self.finish(job,url:address,hash:hash,image:image,remote:true,epoch:epoch)}else{self.resolve(job,position:position+1,epoch:epoch)}};return}
      self.io.async{[weak self]in guard let self else{return};let payload=(200..<300).contains(status) ? data:nil
        let image=payload.flatMap{Self.decode($0,maximumPixelSize:self.size(job.role))},hash=image == nil ? nil:payload.map(ArtworkIndexStore.hash)
        if let payload,let hash,let image{_=self.store.saveObject(payload,hash:hash);if let png=Self.png(image){self.store.saveThumbnail(png,hash:hash,size:self.size(job.role))}}
        DispatchQueue.main.async{[weak self]in guard let self,self.generation==epoch else{return};self.tasks.removeValue(forKey:job.key)
          if let image,let hash{self.index.urls[address]=ArtworkURLRecord(hash:hash,etag:Self.header(http?.value(forHTTPHeaderField:"ETag")),lastModified:Self.header(http?.value(forHTTPHeaderField:"Last-Modified")));self.changedIndex();self.finish(job,url:address,hash:hash,image:image,remote:true,epoch:epoch)}
          else{if status==404 || status==410{var value=prior ?? ArtworkURLRecord();value.negativeStatus=status;self.index.urls[address]=value;self.changedIndex()};self.resolve(job,position:position+1,epoch:epoch)}
        }
      }
    };task.priority=job.priority ? URLSessionTask.defaultPriority:URLSessionTask.lowPriority;tasks[job.key]=task;task.resume()
  }
  private func load(hash:String,role:GameArtwork.Role,completion:@escaping(CGImage?)->Void){io.async{[weak self]in guard let self else{return};let maximum=self.size(role)
      var image=self.store.thumbnail(hash,size:maximum).flatMap{Self.decode($0,maximumPixelSize:maximum)}
      if image==nil,let data=self.store.object(hash){image=Self.decode(data,maximumPixelSize:maximum);if let image,let png=Self.png(image){self.store.saveThumbnail(png,hash:hash,size:maximum)}}
      DispatchQueue.main.async{completion(image)}
    }}
  private func finish(_ job:Job,url:String?,hash:String?,image:CGImage?,remote:Bool,epoch:UUID){
    guard generation==epoch else{return}
    let demand=job.force || (jobs[job.key]?.priority ?? job.priority) || refreshers[job.key] != nil
    tasks.removeValue(forKey:job.key);active.remove(job.key);jobs.removeValue(forKey:job.key);warmFinished.insert(job.key)
    if let image,let url,let hash,var record=index.roles[job.key]{let oldHash=record.hash,wasMissing=memory.object(forKey:memoryKey(hash,job.role)as NSString)==nil,waiting=refreshers[job.key] != nil
      record.hash=hash;record.preferredURL=url;index.roles[job.key]=record;changedIndex();if demand && wasMissing{memory.setObject(CachedArtwork(image),forKey:memoryKey(hash,job.role)as NSString,cost:image.bytesPerRow*image.height)}
      let changed=oldHash != hash
      if demand && (changed || (!job.force && (wasMissing || waiting))){revisions[job.key,default:0]+=1;refreshers.removeValue(forKey:job.key)?();NotificationCenter.default.post(name:.readyArtworkChanged,object:self,userInfo:["address":url,"gameID":job.gameID,"role":job.role.rawValue,"revision":revisions[job.key] ?? 0,"changed":changed,"loaded":!job.force])}
      else{refreshers.removeValue(forKey:job.key)}
    }else{refreshers.removeValue(forKey:job.key)} // Preserve every previous good binding on errors.
    if let next=deferred.removeValue(forKey:job.key){jobs[next.key]=next;pending.insert(next.key,at:0)}
    drain()
  }
  private func changedIndex(){indexRevision &+= 1;persist()}
  private func persist(){guard loaded,!persisting else{return};persisting=true;let snapshot=index,version=indexRevision
    io.async{[weak self]in guard let self else{return};self.store.save(snapshot);DispatchQueue.main.async{[weak self]in guard let self else{return};self.persisting=false;if self.indexRevision != version{self.persist()}}}
  }
  private static func header(_ value:String?)->String?{guard let value,value.utf8.count<=4096,!value.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)})else{return nil};return value}
  private static func decode(_ data:Data,maximumPixelSize:Int)->CGImage?{guard !data.isEmpty,data.count<=10_000_000,let source=CGImageSourceCreateWithData(data as CFData,nil)else{return nil};return CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:maximumPixelSize,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceShouldCacheImmediately:true]as CFDictionary)}
  private static func png(_ image:CGImage)->Data?{NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])}
}
