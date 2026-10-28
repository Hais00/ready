// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherCore

struct SteamDownloadJob: Identifiable {
  let id: String
  let gameID: String
  let platform: String
  var state: String
  var phase: String
  var completed: Int64?
  var total: Int64?
  var fraction: Double?
  var error: String?
  var retryable: Bool
  var sequence: UInt64
  var raw: [String: Any]
  init?(_ value: [String: Any]) {
    guard let id=value["jobID"]as?String, UUID(uuidString:id) != nil,
      let game=value["gameID"]as?String, let platform=value["platform"]as?String,
      ["macOS","windows"].contains(platform),let state=value["state"]as?String else{return nil}
    self.id=id;gameID=game;self.platform=platform;self.state=state;phase=value["phase"]as?String ?? state
    completed=(value["bytesCompleted"]as?NSNumber)?.int64Value;total=(value["bytesTotal"]as?NSNumber)?.int64Value
    if let number=value["fraction"]as?Double,number.isFinite,(0...1).contains(number){fraction=number}else{fraction=nil}
    error=value["errorCode"]as?String;retryable=value["retryable"]as?Bool ?? false
    sequence=(value["sequence"]as?NSNumber)?.uint64Value ?? 0;raw=value
  }
}

@MainActor
final class SteamDownloads {
  let profile: UUID
  private let client: StoreClient
  private(set) var jobs=[String:SteamDownloadJob]()
  var onChange: (([SteamDownloadJob])->Void)?
  var onInstalled: ((SteamDownloadJob)->Void)?
  var onError: ((String)->Void)?
  private var active: (String,UUID)?
  private var generation=UUID()
  private var poll:Timer?
  private var attempts=[String:Int]()
  private var retriesScheduled=Set<String>()
  private var delivered=Set<String>()
  private var stopped=false
  private var authorizationPaused=false
  init(profile:UUID,client:StoreClient){self.profile=profile;self.client=client}
  var snapshot:[SteamDownloadJob]{jobs.values.sorted{$0.id<$1.id}}
  func restore() {
    stopped=false;let epoch=generation
    client.request(operation:"download_list",store:.steam,profile:profile){[weak self]event in
      MainActor.assumeIsolated {
        guard let self,self.generation==epoch,!self.stopped else{return}
        if let values=event["jobs"]as?[[String:Any]] {for value in values{self.accept(value)}}
        for job in self.snapshot where job.state=="retry_wait"&&job.retryable{self.retry(job)}
        self.changed();self.next()
      }
    }
    poll?.invalidate();poll=Timer.scheduledTimer(withTimeInterval:2,repeats:true){[weak self]_ in
      MainActor.assumeIsolated {self?.refreshActive()}
    }
  }
  func enqueue(game:Game,variant:GameVariant,installation:URL) {
    let epoch=generation
    client.request(operation:"download_prepare",store:.steam,profile:profile,options:["gameID":game.storeID,"platform":variant.platform.rawValue,"installDir":installation.path,"metadata":game.metadata?.mapValues{$0.foundation} ?? [:]]){[weak self]event in
      MainActor.assumeIsolated {
        guard let self,self.generation==epoch,!self.stopped else{return}
        if let job=event["job"]as?[String:Any]{self.accept(job);self.changed();self.next()}
        else if event["type"]as?String=="error"{self.onError?(event["message"]as?String ?? "Preparazione download non riuscita.")}
      }
    }
  }
  func control(_ id:String,action:String,resetRetryBudget:Bool=true) {
    guard jobs[id] != nil,["pause","resume","cancel","retry"].contains(action)else{return}
    let epoch=generation
    client.request(operation:"download_control",store:.steam,profile:profile,options:["jobID":id,"action":action]){[weak self]event in
      MainActor.assumeIsolated {
        guard let self,self.generation==epoch,!self.stopped else{return}
        if let job=event["job"]as?[String:Any]{self.accept(job)}
        // The backend's durable control record owns the engine stop, not just
        // cancellation of this frontend request. Wait for its terminal event.
        if resetRetryBudget&&(action=="resume"||action=="retry"){self.attempts[id]=0}
        self.changed();self.next()
      }
    }
  }
  private func refreshActive() {
    guard !stopped,let current=active else{return}
    let epoch=generation
    client.request(operation:"download_status",store:.steam,profile:profile,options:["jobID":current.0]){[weak self]event in
      MainActor.assumeIsolated {
        guard let self,self.generation==epoch,!self.stopped else{return}
        if let job=event["job"]as?[String:Any]{self.accept(job);self.changed()}
      }
    }
  }
  private func next() {
    guard !stopped,!authorizationPaused,active==nil,let job=snapshot.first(where:{$0.state=="queued"})else{return}
    let epoch=generation
    // Reserve synchronously before StoreClient schedules any callbacks.
    active=(job.id,UUID())
    let request=client.request(operation:"download_run",store:.steam,profile:profile,options:["jobID":job.id]){[weak self]event in
      MainActor.assumeIsolated {
        guard let self,self.generation==epoch,!self.stopped,self.active?.0==job.id else{return}
        if let value=event["job"]as?[String:Any]{self.accept(value)}
        else if event["type"]as?String=="error",var failed=self.jobs[job.id] {
          let code=event["code"]as?String ?? "download_failed"
          let auth=["authentication_required","auth_required","credentials_changed","steam_login_failed"].contains(code)
          failed.state=auth ? "authorization_required":"failed";failed.error=code;failed.retryable=false
          self.jobs[job.id]=failed
          if auth{self.authorizationPaused=true}
        }
        self.changed()
        if ["result","error"].contains(event["type"]as?String ?? "") {
          self.active=nil
          if let failed=self.jobs[job.id],failed.retryable,["failed","retry_wait"].contains(failed.state){self.retry(failed)}
          self.next()
        }
      }
    }
    active=(job.id,request)
  }
  private func retry(_ job:SteamDownloadJob) {
    guard retriesScheduled.insert(job.id).inserted else{return}
    let count=(attempts[job.id] ?? 0)+1;attempts[job.id]=count
    guard count<=5 else{retriesScheduled.remove(job.id);return}
    let epoch=generation
    DispatchQueue.main.asyncAfter(deadline:.now()+min(60,pow(2,Double(count)))){[weak self]in
      guard let self else{return}
      self.retriesScheduled.remove(job.id)
      guard self.generation==epoch,!self.stopped,
        let current=self.jobs[job.id],["failed","retry_wait"].contains(current.state),current.retryable else{return}
      self.control(job.id,action:"retry",resetRetryBudget:false)
    }
  }
  private func accept(_ value:[String:Any]) {
    guard let job=SteamDownloadJob(value),UUID(uuidString:value["profileID"]as?String ?? "")==profile,
      jobs[job.id].map({job.sequence >= $0.sequence}) ?? true else{return}
    jobs[job.id]=job
    if job.state=="completed",job.raw["installedVariant"] != nil,delivered.insert(job.id).inserted {onInstalled?(job)}
  }
  private func changed(){onChange?(snapshot)}
  func resumeAfterAuthorization(){authorizationPaused=false;restore()}
  func stop() {
    stopped=true;generation=UUID();poll?.invalidate();poll=nil
    if let current=active {
      // Preserve files/cache and durable paused state across profile/UI changes.
      client.request(operation:"download_control",store:.steam,profile:profile,options:["jobID":current.0,"action":"pause"]){_ in}
      client.cancel(current.1)
    }
    active=nil
    retriesScheduled.removeAll()
  }
}
