// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CryptoKit
import Darwin
import ImageIO
import LauncherCore

extension Notification.Name {static let readyArtworkChanged=Notification.Name("ready.artwork.changed")}
private final class CachedArtwork:NSObject{let image:CGImage;init(_ image:CGImage){self.image=image}}
/// UI state belongs to Main. Interactive reads never queue behind index/blob
/// writes; publication also runs in AppKit's event-tracking run-loop mode.
final class ArtworkCache {
  private struct Job {
    let key:String,gameID:String,role:GameArtwork.Role,candidates:[String],force:Bool
    var priority:Int
    let token=UUID()
  }
  private let cardMemory=NSCache<NSString,CachedArtwork>(),detailMemory=NSCache<NSString,CachedArtwork>()
  private let session:URLSession,store:ArtworkIndexStore,directory:URL?
  private let networkEnabled:Bool,maximumPixelSize:Int,backgroundWriteGate:(()->Void)?
  private let io=DispatchQueue(label:"app.ready.artwork-index.writer",qos:.utility)
  private let readers:OperationQueue = {let q=OperationQueue();q.name="app.ready.artwork.visible-read";q.qualityOfService = .userInitiated;q.maxConcurrentOperationCount=2;return q}()
  private var index=ArtworkDiskIndex(),loaded=false
  private var startup=[()->Void](),jobs=[String:Job](),pending=[String](),active=Set<String>(),tasks=[String:URLSessionDataTask]()
  private var refreshers=[String:()->Void](),warmFinished=Set<String>(),deferred=[String:Job](),revisions=[String:UInt64]()
  private var diskLoading=Set<String>(),readOperations=[String:Operation](),viewportPriorities=[String:Int]()
  private var stagedData=[String:Data](),stagedCounts=[String:Int](),stagedBytes=0
  private var generation=UUID(),persisting=false,indexRevision:UInt64=0
  private let maintenanceLock=NSLock()
  private var maintenancePaused=false,workGeneration=UUID()
  private var gameplayPaused=false,returnHold=false
  private struct ReturnCard {let hash:String,image:CGImage}
  private var returnCards=[String:ReturnCard](),returnBytes=0
  private var returnPending=Set<String>(),returnCompletion:(()->Void)?
  var gameplayRetentionSnapshot:(count:Int,bytes:Int,paused:Bool){(returnCards.count,returnBytes,gameplaySuspended)}
  private var gameplaySuspended:Bool{maintenanceLock.lock();defer{maintenanceLock.unlock()};return gameplayPaused}
  private var workSuspended:Bool{maintenanceSuspended || gameplaySuspended}
  /// Keep only already decoded card thumbnails for the last viewport. These
  /// are CPU images, never card tiles, Metal textures, banners or full assets.
  func beginGameplay(retainingViewport games:[Game]){
    guard !gameplaySuspended else{return}
    var kept=[String:ReturnCard](),bytes=0
    for game in games.prefix(24){
      let id=key(game.id,.card)
      guard let hash=index.roles[id]?.hash,
        let image=cardMemory.object(forKey:memoryKey(hash,.card)as NSString)?.image else{continue}
      let cost=image.bytesPerRow*image.height
      guard cost<=16*1024*1024-bytes else{continue}
      kept[id]=ReturnCard(hash:hash,image:image);bytes+=cost
    }
    returnCards=kept;returnBytes=bytes
    maintenanceLock.lock();gameplayPaused=true;maintenanceLock.unlock()
    purge()
  }
  /// Rehydrate RAM immediately, then only the first viewport's indexed cards.
  /// Background artwork waits for these reads; missing blobs do not hold UI
  /// restoration hostage to a network request. Root owns model/GPU restoration.
  func restoreFirstViewport(games:[Game],completion:@escaping()->Void){
    returnHold=true;returnCompletion=completion;returnPending.removeAll()
    maintenanceLock.lock();gameplayPaused=false;maintenancePaused=false;maintenanceLock.unlock()
    whenLoaded{[weak self]in
      guard let self else{return};let epoch=self.generation
      let viewport=Array(games.prefix(32))
      for game in viewport{
        self.bind(game,role:.card);let id=self.key(game.id,.card)
        guard let hash=self.index.roles[id]?.hash else{continue}
        if let card=self.returnCards[id],card.hash==hash{self.cardMemory.setObject(CachedArtwork(card.image),forKey:self.memoryKey(hash,.card)as NSString,cost:card.image.bytesPerRow*card.image.height)}
        if self.cardMemory.object(forKey:self.memoryKey(hash,.card)as NSString)==nil{self.returnPending.insert(id)}
      }
      for game in viewport{
        let id=self.key(game.id,.card);guard self.returnPending.contains(id),let record=self.index.roles[id],let hash=record.hash else{continue}
        self.diskLoading.insert(id)
        self.load(hash:hash,role:.card,priority:3,binding:id){[weak self]image in
          guard let self,self.generation==epoch else{return};self.diskLoading.remove(id)
          if self.index.roles[id]?.hash==hash,let image{
            self.cardMemory.setObject(CachedArtwork(image),forKey:self.memoryKey(hash,.card)as NSString,cost:image.bytesPerRow*image.height)
            self.notify(gameID:game.id,role:.card,url:record.preferredURL ?? "",changed:false,loaded:true)
          }
          self.returnPending.remove(id);self.finishViewportRestore()
        }
      }
      self.finishViewportRestore()
    }
  }
  private func finishViewportRestore(){
    guard returnHold,returnPending.isEmpty,let done=returnCompletion else{return}
    returnCompletion=nil;returnCards.removeAll();returnBytes=0
    let epoch=generation
    Self.publish{[weak self]in
      done()
      guard let self,self.generation==epoch else{return}
      self.returnHold=false;self.drain();self.persist()
    }
  }
  var maintenanceSuspended:Bool{maintenanceLock.lock();defer{maintenanceLock.unlock()};return maintenancePaused}
  func setMaintenanceSuspended(_ value:Bool){
    maintenanceLock.lock();let changed=maintenancePaused != value;maintenancePaused=value;maintenanceLock.unlock()
    if changed && value{purge()}else if changed{persist()}
  }
  private func readEpoch()->UUID{maintenanceLock.lock();defer{maintenanceLock.unlock()};return workGeneration}
  private func workAllowed(_ epoch:UUID)->Bool{maintenanceLock.lock();defer{maintenanceLock.unlock()};return !maintenancePaused && !gameplayPaused && workGeneration==epoch}
  init(directory:URL?=ArtworkCache.defaultDirectory,session:URLSession = ArtworkCache.publicSession,networkEnabled:Bool=true,maximumPixelSize:Int=2048,backgroundWriteGate:(()->Void)?=nil,indexStore:ArtworkIndexStore?=nil){
    self.directory=directory;self.session=session;store=indexStore ?? ArtworkIndexStore(directory);self.networkEnabled=networkEnabled
    self.maximumPixelSize=min(2048,max(128,maximumPixelSize));self.backgroundWriteGate=backgroundWriteGate
    cardMemory.countLimit=256;cardMemory.totalCostLimit=96*1024*1024
    detailMemory.countLimit=96;detailMemory.totalCostLimit=64*1024*1024
    io.async{[weak self]in
      guard let self else{return};let value=self.store.load()
      Self.publish{[weak self]in guard let self else{return};self.index=value;self.loaded=true;let actions=self.startup;self.startup.removeAll();actions.forEach{$0()}}
      if self.store.repairNeeded{_=self.store.save(value)}else{_=self.store.ensureRecoverySnapshot(value)}
    }
  }
  static let publicSession:URLSession = {
    let c=URLSessionConfiguration.ephemeral;c.httpCookieStorage=nil;c.urlCredentialStorage=nil;c.urlCache=nil
    c.requestCachePolicy = .reloadIgnoringLocalCacheData;c.httpMaximumConnectionsPerHost=6
    return URLSession(configuration:c)
  }()
  static var defaultDirectory:URL?{
    if let path=ProcessInfo.processInfo.environment["READY_ARTWORK_CACHE_ROOT"] ?? UserDefaults.standard.string(forKey:"readyArtworkCacheDirectory"){
      guard path.hasPrefix("/"),path != "/" else{return nil};let normalized=URL(fileURLWithPath:path,isDirectory:true).standardizedFileURL
      guard normalized.path != "/" else{return nil};return normalized
    }
    return FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask).first?.resolvingSymlinksInPath().appendingPathComponent("app.ready.artwork-v1",isDirectory:true)
  }
  private static func publish(_ block:@escaping()->Void){
    let modes=[RunLoop.Mode.common.rawValue,RunLoop.Mode.eventTracking.rawValue,RunLoop.Mode.modalPanel.rawValue] as CFArray
    CFRunLoopPerformBlock(CFRunLoopGetMain(),modes,block);CFRunLoopWakeUp(CFRunLoopGetMain())
  }
  func prepare(games:[Game],visibleGameIDs:[String]=[]){
    whenLoaded{[weak self]in guard let self else{return};let visible=Set(visibleGameIDs)
      for game in games.prefix(20000){for role in GameArtwork.Role.allCases{self.bind(game,role:role);self.enqueue(gameID:game.id,role:role,force:false,priority:role == .card && visible.contains(game.id) ? 2:0)}}
    }
  }
  /// Only card thumbnails enter the scroll working set. Never decode banners
  /// or icons because a row happened to move into view.
  func prepareViewport(games:[Game],visibleGameIDs:[String],lookAheadGameIDs:[String]){
    whenLoaded{[weak self]in guard let self else{return}
      let old=self.viewportPriorities,visible=Set(visibleGameIDs),ahead=Set(lookAheadGameIDs)
      var next=[String:Int]();for game in games{if visible.contains(game.id){next[self.key(game.id,.card)]=2}else if ahead.contains(game.id){next[self.key(game.id,.card)]=1}}
      self.viewportPriorities=next
      for id in Array(self.jobs.keys){
        guard var job=self.jobs[id],!job.force,job.role == .card,old[id] != nil else{continue}
        let priority=next[id] ?? 0
        if self.active.contains(id),job.priority>=2,priority<2{
          self.tasks.removeValue(forKey:id)?.cancel();self.active.remove(id)
          job=Job(key:job.key,gameID:job.gameID,role:job.role,candidates:job.candidates,force:false,priority:priority)
          self.jobs[id]=job;if !self.pending.contains(id){self.pending.append(id)}
        }else{job.priority=priority;self.jobs[id]=job;self.tasks[id]?.priority=Self.taskPriority(priority)}
      }
      for (id,operation) in self.readOperations where old[id] != nil{
        let p=next[id] ?? 0
        if p==0,!operation.isExecuting{operation.cancel();self.readOperations.removeValue(forKey:id);self.diskLoading.remove(id)}
        else{operation.queuePriority=p>=2 ? .veryHigh:p==1 ? .normal:.veryLow}
      }
      // FIFO within a priority; visible cards cannot be displaced by later
      // background completions or a later banner prefetch.
      for priority in [2,1]{for game in games where next[self.key(game.id,.card)]==priority{self.bind(game,role:.card);self.enqueue(gameID:game.id,role:.card,force:false,priority:priority)}}
      self.drain()
    }
  }
  func prefetch(game:Game){whenLoaded{[weak self]in guard let self else{return};for role in GameArtwork.Role.allCases{self.bind(game,role:role);self.enqueue(gameID:game.id,role:role,force:false,priority:3)}}}
  func revalidate(game:Game){whenLoaded{[weak self]in guard let self else{return};for role in [GameArtwork.Role.icon,.banner,.card]{self.bind(game,role:role);self.enqueue(gameID:game.id,role:role,force:true,priority:3)}}}
  func hasCachedImage(gameID:String,role:GameArtwork.Role)->Bool{index.roles[key(gameID,role)]?.hash != nil}
  func revision(gameID:String,role:GameArtwork.Role)->UInt64{revisions[key(gameID,role)] ?? 0}
  func image(for game:Game,role:GameArtwork.Role,refresh:@escaping()->Void)->CGImage?{
    guard !workSuspended else{return nil}
    let id=key(game.id,role)
    guard loaded else{whenLoaded{[weak self]in _=self?.image(for:game,role:role,refresh:refresh)};return nil}
    bind(game,role:role)
    if let hash=index.roles[id]?.hash,let image=memory(role).object(forKey:memoryKey(hash,role)as NSString){return image.image}
    refreshers[id]=refresh;enqueue(gameID:game.id,role:role,force:false,priority:viewportPriorities[id] ?? 3);return nil
  }
  func image(_ address:String?,refresh:@escaping()->Void)->CGImage?{image(addresses:[address],refresh:refresh)}
  func image(addresses:[String?],refresh:@escaping()->Void)->CGImage?{
    guard !workSuspended else{return nil}
    let candidates=addresses.compactMap{$0}.filter(Self.validURL),gameID="legacy:"+ArtworkIndexStore.hash(Data(candidates.joined(separator:"\n").utf8)),id=key(gameID,.card)
    guard !candidates.isEmpty else{return nil};guard loaded else{whenLoaded{[weak self]in _=self?.image(addresses:addresses,refresh:refresh)};return nil}
    if index.roles[id]==nil{index.roles[id]=ArtworkRoleRecord(gameID:gameID,role:.card,candidates:candidates);changedIndex()}
    if let hash=index.roles[id]?.hash,let image=cardMemory.object(forKey:memoryKey(hash,.card)as NSString){return image.image}
    refreshers[id]=refresh;enqueue(gameID:gameID,role:.card,force:false,priority:3);return nil
  }
  /// Disk objects, receipts and bindings survive session/RAM cleanup.
  func purge(){
    returnPending.removeAll();returnCompletion=nil;returnHold=false
    if !gameplaySuspended{returnCards.removeAll();returnBytes=0}
    maintenanceLock.lock();workGeneration=UUID();maintenanceLock.unlock()
    generation=UUID();tasks.values.forEach{$0.cancel()};tasks.removeAll();readers.cancelAllOperations();readOperations.removeAll()
    pending.removeAll();active.removeAll();jobs.removeAll();deferred.removeAll();refreshers.removeAll();warmFinished.removeAll();diskLoading.removeAll();startup.removeAll();viewportPriorities.removeAll()
    cardMemory.removeAllObjects();detailMemory.removeAllObjects()
  }
  private func whenLoaded(_ action:@escaping()->Void){guard !workSuspended else{return};if loaded{action()}else{startup.append(action)}}
  private func key(_ game:String,_ role:GameArtwork.Role)->String{game+"\u{1f}"+role.rawValue}
  private func size(_ role:GameArtwork.Role)->Int{switch role{case .icon:return 128;case .card:return min(maximumPixelSize,512);case .banner:return maximumPixelSize}}
  private func memory(_ role:GameArtwork.Role)->NSCache<NSString,CachedArtwork>{role == .card ? cardMemory:detailMemory}
  private func memoryKey(_ hash:String,_ role:GameArtwork.Role)->String{hash+":"+String(size(role))}
  private static func taskPriority(_ p:Int)->Float{p>=2 ? URLSessionTask.highPriority:p==1 ? URLSessionTask.defaultPriority:URLSessionTask.lowPriority}
  private static func validURL(_ value:String)->Bool{guard value.utf8.count<=4096,let url=URL(string:value)else{return false};return url.scheme?.lowercased()=="https" && url.host != nil && url.user==nil && url.password==nil}
  private func bind(_ game:Game,role:GameArtwork.Role){
    let id=key(game.id,role),candidates=GameArtwork.candidates(for:game,role:role).filter(Self.validURL)
    if var old=index.roles[id]{if old.candidates != candidates{old.candidates=candidates;index.roles[id]=old;changedIndex()}}
    else{index.roles[id]=ArtworkRoleRecord(gameID:game.id,role:role,candidates:candidates);changedIndex()}
  }
  private func enqueue(gameID:String,role:GameArtwork.Role,force:Bool,priority:Int){
    let id=key(gameID,role);guard let record=index.roles[id],!record.candidates.isEmpty || record.hash != nil else{return}
    if !force,let hash=record.hash,let address=record.preferredURL{
      guard priority>0 || refreshers[id] != nil else{return}
      guard memory(role).object(forKey:memoryKey(hash,role)as NSString)==nil else{return}
      if diskLoading.contains(id){if let operation=readOperations[id]{operation.queuePriority=priority>=2 ? .veryHigh:.normal};return}
      diskLoading.insert(id);let epoch=generation
      load(hash:hash,role:role,priority:priority,binding:id){[weak self]image in
        guard let self,self.generation==epoch else{return};self.diskLoading.remove(id)
        guard self.index.roles[id]?.hash==hash else{return}
        guard let image else{
          if self.jobs[id]==nil,let current=self.index.roles[id]{var seen=Set<String>();let candidates=([address]+current.candidates).filter{seen.insert($0).inserted};self.jobs[id]=Job(key:id,gameID:gameID,role:role,candidates:candidates,force:false,priority:priority);self.pending.append(id);self.drain()};return
        }
        let absent=self.memory(role).object(forKey:self.memoryKey(hash,role)as NSString)==nil
        if absent{self.memory(role).setObject(CachedArtwork(image),forKey:self.memoryKey(hash,role)as NSString,cost:image.bytesPerRow*image.height)}
        if absent || self.refreshers[id] != nil{self.notify(gameID:gameID,role:role,url:address,changed:false,loaded:true)}
      };return
    }
    if !force,record.hash==nil,warmFinished.contains(id){return}
    let candidates:[String]
    if force,record.hash != nil,let preferred=record.preferredURL,record.candidates.contains(preferred){candidates=[preferred]}else{candidates=record.candidates}
    let job=Job(key:id,gameID:gameID,role:role,candidates:candidates,force:force,priority:priority)
    if var old=jobs[id]{
      if force{if !old.force || old.candidates != candidates{deferred[id]=job}}
      else if priority>old.priority{old.priority=priority;jobs[id]=old;tasks[id]?.priority=Self.taskPriority(priority)}
      return
    }
    jobs[id]=job;pending.append(id);drain()
  }
  private func valid(_ job:Job,_ epoch:UUID)->Bool{!workSuspended && generation==epoch && jobs[job.key]?.token==job.token}
  private func lane(_ priority:Int)->Int{priority>=2 ? 2:priority==1 ? 1:0}
  private func drain(){
    guard !workSuspended else{return}
    while active.count<5{
      pending.removeAll{jobs[$0]==nil || active.contains($0)}
      let counts=Dictionary(grouping:active.compactMap{jobs[$0]}){lane($0.priority)}.mapValues(\.count)
      // Reserved foreground capacity cannot be consumed by backgrounds or
      // look-ahead. All lanes are bounded; visible downloads retain two slots.
      let eligible=pending.enumerated().filter{_,id in guard let job=jobs[id]else{return false};let l=lane(job.priority);return (!returnHold || l>0) && (counts[l] ?? 0)<(l==1 ? 1:2) && stagedBytes<(l==0 ? 32:64)*1024*1024}
      guard let selected=eligible.max(by:{a,b in let x=jobs[a.element]!.priority,y=jobs[b.element]!.priority;return x==y ? a.offset>b.offset:x<y})else{return}
      let id=pending.remove(at:selected.offset);guard let job=jobs[id]else{continue};active.insert(id);resolve(job,position:0,epoch:generation)
    }
  }
  private func resolve(_ job:Job,position:Int,epoch:UUID){
    guard valid(job,epoch)else{return}
    guard position<job.candidates.count else{finish(job,url:nil,hash:nil,image:nil,epoch:epoch);return}
    let address=job.candidates[position],record=index.urls[address]
    if !job.force,let hash=record?.hash{load(hash:hash,role:job.role,priority:jobs[job.key]?.priority ?? job.priority){[weak self]image in guard let self,self.valid(job,epoch)else{return};if let image{self.finish(job,url:address,hash:hash,image:image,epoch:epoch)}else{self.fetch(job,address:address,position:position,epoch:epoch)}};return}
    if !job.force,record?.negativeStatus != nil{resolve(job,position:position+1,epoch:epoch);return}
    if !job.force,record==nil{
      let directory=self.directory,maximum=size(job.role)
      read(priority:jobs[job.key]?.priority ?? job.priority){()->(ArtworkURLRecord?,Data?,CGImage?) in
        let reader=ArtworkIndexStore(directory)
        if let recovered=reader.urlRecord(for:address){return (recovered,nil as Data?,nil as CGImage?)}
        let data=reader.legacy(address,size:1024),image=data.flatMap{Self.decode($0,maximumPixelSize:maximum)}
        return (nil as ArtworkURLRecord?,image==nil ? nil:data,image)
      } completion:{[weak self]result in
        let (recovered,data,image)=result
        guard let self,self.valid(job,epoch)else{return}
        if let recovered{self.index.urls[address]=recovered;self.changedIndex();self.resolve(job,position:position,epoch:epoch)}
        else if let data,let image{let hash=ArtworkIndexStore.hash(data);self.stage(data,hash:hash,address:address,image:image,role:job.role,etag:nil,lastModified:nil);self.index.urls[address]=ArtworkURLRecord(hash:hash);self.changedIndex();self.finish(job,url:address,hash:hash,image:image,epoch:epoch)}
        else{self.fetch(job,address:address,position:position,epoch:epoch)}
      };return
    }
    fetch(job,address:address,position:position,epoch:epoch)
  }
  private func fetch(_ job:Job,address:String,position:Int,epoch:UUID){
    guard valid(job,epoch)else{return}
    guard networkEnabled,Self.validURL(address),let url=URL(string:address)else{resolve(job,position:position+1,epoch:epoch);return}
    let priority=jobs[job.key]?.priority ?? job.priority
    var request=URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:15);request.httpShouldHandleCookies=false
    request.networkServiceType=priority>=2 ? .responsiveData:.background;request.setValue("image/*",forHTTPHeaderField:"Accept")
    if job.force,let old=index.urls[address]{if let tag=Self.header(old.etag){request.setValue(tag,forHTTPHeaderField:"If-None-Match")};if let date=Self.header(old.lastModified){request.setValue(date,forHTTPHeaderField:"If-Modified-Since")}}
    let prior=index.urls[address]
    let task=session.dataTask(with:request){[weak self]data,response,_ in
      Self.publish{[weak self]in
        guard let self,self.valid(job,epoch)else{return};self.tasks.removeValue(forKey:job.key)
        let http=response as?HTTPURLResponse,status=http?.statusCode ?? 0
        if status==304,let hash=prior?.hash{
          self.load(hash:hash,role:job.role,priority:self.jobs[job.key]?.priority ?? priority){[weak self]image in
            guard let self,self.valid(job,epoch)else{return}
            if let image{var value=prior!;value.etag=Self.header(http?.value(forHTTPHeaderField:"ETag")) ?? value.etag;value.lastModified=Self.header(http?.value(forHTTPHeaderField:"Last-Modified")) ?? value.lastModified;self.index.urls[address]=value;self.io.async{_=self.store.saveURLRecord(value,address:address)};self.changedIndex();self.finish(job,url:address,hash:hash,image:image,epoch:epoch)}
            else{self.resolve(job,position:position+1,epoch:epoch)}
          };return
        }
        let payload=(200..<300).contains(status) ? data:nil,maximum=self.size(job.role)
        self.read(priority:self.jobs[job.key]?.priority ?? priority){()->(CGImage?,String?) in
          let image=payload.flatMap{Self.decode($0,maximumPixelSize:maximum)}
          return (image,image==nil ? nil:payload.map(ArtworkIndexStore.hash))
        } completion:{[weak self]image,hash in
          guard let self,self.valid(job,epoch)else{return}
          if let image,let hash,let payload{
            let tag=Self.header(http?.value(forHTTPHeaderField:"ETag")),modified=Self.header(http?.value(forHTTPHeaderField:"Last-Modified"))
            self.stage(payload,hash:hash,address:address,image:image,role:job.role,etag:tag,lastModified:modified)
            self.index.urls[address]=ArtworkURLRecord(hash:hash,etag:tag,lastModified:modified);self.changedIndex();self.finish(job,url:address,hash:hash,image:image,epoch:epoch)
          }else{
            if status==404 || status==410{var value=prior ?? ArtworkURLRecord();value.negativeStatus=status;self.index.urls[address]=value;self.io.async{_=self.store.saveURLRecord(value,address:address)};self.changedIndex()}
            self.resolve(job,position:position+1,epoch:epoch)
          }
        }
      }
    };task.priority=Self.taskPriority(priority);tasks[job.key]=task;task.resume()
  }
  private func stage(_ data:Data,hash:String,address:String,image:CGImage,role:GameArtwork.Role,etag:String?,lastModified:String?){
    if stagedData[hash]==nil{stagedData[hash]=data;stagedBytes+=data.count};stagedCounts[hash,default:0]+=1
    let maximum=size(role),epoch=readEpoch()
    io.async{[self]in
      _=store.saveURLObject(data,hash:hash,address:address,etag:etag,lastModified:lastModified)
      if workAllowed(epoch),let png=Self.png(image){store.saveThumbnail(png,hash:hash,size:maximum)}
      Self.publish{[weak self]in guard let self else{return};self.stagedCounts[hash,default:1]-=1;if self.stagedCounts[hash]==0{self.stagedCounts.removeValue(forKey:hash);if let data=self.stagedData.removeValue(forKey:hash){self.stagedBytes-=data.count}};self.drain()}
    }
  }
  private func read<T>(priority:Int,binding:String?=nil,_ work:@escaping()->T,completion:@escaping(T)->Void){
    let epoch=readEpoch()
    guard workAllowed(epoch) else{return}
    if priority==0{io.async{[weak self]in guard let self,self.workAllowed(epoch)else{return};let value=autoreleasepool(invoking:work);Self.publish{[weak self]in guard let self,self.workAllowed(epoch)else{return};completion(value)}};return}
    let operation=BlockOperation();operation.queuePriority=priority>=2 ? .veryHigh:.normal
    if let binding{readOperations[binding]=operation}
    operation.addExecutionBlock{[weak self,weak operation]in
      guard let self,let operation,!operation.isCancelled,self.workAllowed(epoch) else{return};let value=autoreleasepool(invoking:work)
      Self.publish{[weak self]in guard let self,!operation.isCancelled,self.workAllowed(epoch) else{return};if let binding,self.readOperations[binding]===operation{self.readOperations.removeValue(forKey:binding)};completion(value)}
    };readers.addOperation(operation)
  }
  private func load(hash:String,role:GameArtwork.Role,priority:Int,binding:String?=nil,completion:@escaping(CGImage?)->Void){
    let maximum=size(role),directory=self.directory,staged=stagedData[hash],epoch=readEpoch()
    read(priority:priority,binding:binding){()->(CGImage?,Bool) in
      let reader=ArtworkIndexStore(directory)
      if let image=reader.thumbnail(hash,size:maximum).flatMap({Self.decode($0,maximumPixelSize:maximum)}){return(image,false)}
      if role == .card,maximum<1024,let image=reader.thumbnail(hash,size:1024).flatMap({Self.decode($0,maximumPixelSize:maximum)}){return(image,true)}
      return((staged ?? reader.object(hash)).flatMap{Self.decode($0,maximumPixelSize:maximum)},true)
    } completion:{[weak self]image,needsThumbnail in
      // Publish before encoding or fsync. The old larger thumbnail remains valid.
      completion(image)
      if let self,let image,needsThumbnail{self.io.async{guard self.workAllowed(epoch)else{return};if let png=Self.png(image){self.store.saveThumbnail(png,hash:hash,size:maximum)}}}
    }
  }
  private func finish(_ job:Job,url:String?,hash:String?,image:CGImage?,epoch:UUID){
    guard valid(job,epoch)else{return}
    let demand=job.force || (jobs[job.key]?.priority ?? job.priority)>0 || refreshers[job.key] != nil
    tasks.removeValue(forKey:job.key);active.remove(job.key);jobs.removeValue(forKey:job.key);warmFinished.insert(job.key)
    if let image,let url,let hash,var record=index.roles[job.key]{
      let oldHash=record.hash,absent=memory(job.role).object(forKey:memoryKey(hash,job.role)as NSString)==nil,waiting=refreshers[job.key] != nil
      record.hash=hash;record.preferredURL=url;index.roles[job.key]=record;changedIndex()
      if demand && absent{memory(job.role).setObject(CachedArtwork(image),forKey:memoryKey(hash,job.role)as NSString,cost:image.bytesPerRow*image.height)}
      if demand && (oldHash != hash || (!job.force && (absent || waiting))){notify(gameID:job.gameID,role:job.role,url:url,changed:oldHash != hash,loaded:!job.force)}else{refreshers.removeValue(forKey:job.key)}
    }else{refreshers.removeValue(forKey:job.key)}
    if let next=deferred.removeValue(forKey:job.key){jobs[next.key]=next;pending.append(next.key)}
    drain()
  }
  private func notify(gameID:String,role:GameArtwork.Role,url:String,changed:Bool,loaded:Bool){
    let id=key(gameID,role);revisions[id,default:0]+=1;refreshers.removeValue(forKey:id)?()
    NotificationCenter.default.post(name:.readyArtworkChanged,object:self,userInfo:["address":url,"gameID":gameID,"role":role.rawValue,"revision":revisions[id] ?? 0,"changed":changed,"loaded":loaded])
  }
  private func changedIndex(){indexRevision &+= 1;persist()}
  private func persist(){
    guard !workSuspended,loaded,!persisting else{return};persisting=true;let snapshot=index,version=indexRevision
    io.async{[weak self]in
      guard let self else{return};self.backgroundWriteGate?();_=self.store.save(snapshot)
      Self.publish{[weak self]in guard let self else{return};self.persisting=false
        if self.indexRevision != version{self.persist()}
        // A failed commit keeps URL receipts/backup recoverable. Do not spin
        // retrying a read-only or unavailable volume on the interactive path.
      }
    }
  }
  private static func header(_ value:String?)->String?{guard let value,value.utf8.count<=4096,!value.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)})else{return nil};return value}
  private static func decode(_ data:Data,maximumPixelSize:Int)->CGImage?{guard !data.isEmpty,data.count<=10_000_000,let source=CGImageSourceCreateWithData(data as CFData,nil)else{return nil};return CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:maximumPixelSize,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceShouldCacheImmediately:true]as CFDictionary)}
  private static func png(_ image:CGImage)->Data?{NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])}
}
