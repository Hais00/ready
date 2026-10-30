// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import LauncherCore

extension AppDelegate {
  @MainActor func requestGameStoragePlan(game:Game,variant:GameVariant,completion:@escaping(GameStorageInfo,String?)->Void){
    let profile=state.activeProfile
    let options:[String:Any]=["gameID":game.storeID,"platform":variant.platform.rawValue,"branch":"public","language":game.store == .steam ? "english":"en","architecture":"64","includeDLC":false,"metadata":game.metadata?.mapValues{$0.foundation} ?? [:]]
    let receive:([String:Any])->Void={ [weak self]event in
      MainActor.assumeIsolated{
        guard let self,self.state.activeProfile==profile else{return}
        guard ["result","error"].contains(event["type"]as?String ?? "")else{return}
        if let plan=event["plan"]as?[String:Any],let bytes=try?JSONSerialization.data(withJSONObject:plan),let metadata=try?JSONDecoder().decode([String:JSONValue].self,from:bytes){
          var info=GameStorageInfo(metadata:metadata,platform:variant.platform)
          if info.hasSize,let index=self.state.games.firstIndex(where:{$0.id==game.id}){
            var all=[String:JSONValue]();if case .object(let old)=self.state.games[index].metadata?["platformSizes"]{all=old}
            all[variant.platform.rawValue] = .object(metadata)
            if self.state.games[index].metadata==nil{self.state.games[index].metadata=[:]}
            self.state.games[index].metadata?["platformSizes"] = .object(all)
            self.repository.saveAsync(self.state){_ in}
          }
          // A transient authorization/metadata failure must not erase useful
          // catalog estimates. Its status and verification remain failed.
          if !info.hasSize{
            let current=self.state.games.first(where:{$0.id==game.id}) ?? game
            let cached=GameStorageInfo(metadata:current.metadata ?? [:],platform:variant.platform)
            info.installedBytes=cached.installedBytes;info.downloadBytes=cached.downloadBytes;info.requiredBytes=cached.requiredBytes
          }
          completion(info,nil)
        }else{
          let code=event["code"]as?String ?? "size_unavailable"
          completion(GameStorageInfo(metadata:game.metadata ?? [:],platform:variant.platform),code)
        }
      }
    }
    if game.store == .steam{
      if steamNetwork==nil{configureSteamNetwork()}
      guard let network=steamNetwork,network.state.online,network.accountReadyForGame()else{completion(GameStorageInfo(metadata:game.metadata ?? [:],platform:variant.platform),"authentication_required");return}
      network.request("install_size_plan",options:options,event:receive)
    }else if game.store != .local{storeClient.request(operation:"install_size_plan",store:game.store,profile:profile,options:options,event:receive)}
    else{completion(GameStorageInfo(),"local_import_only")}
  }
  @MainActor func refreshGameStorageDetails(){
    guard let view=gameDetailView,let id=gameDetailID,let game=state.games.first(where:{$0.id==id}),let variant=view.selectedVariant else{return}
    let profile=state.activeProfile,epoch=UUID();gameStorageRequest=epoch
    let configured=state.configured(game),info=GameStorageInfo(metadata:game.metadata ?? [:],platform:variant.platform)
    view.updateStorage(variantID:variant.id,installedBytes:info.installedBytes,downloadBytes:info.downloadBytes,location:variant.installationRoot,requiredBytes:info.requiredBytes)
    if variant.installed{
      gameStorageSizes.measure(game:configured,variant:variant){[weak self,weak view]bytes in
        MainActor.assumeIsolated{guard let self,let view,self.gameDetailView===view,self.gameStorageRequest==epoch,self.state.activeProfile==profile else{return};view.updateStorage(variantID:variant.id,installedBytes:bytes ?? info.installedBytes,downloadBytes:info.downloadBytes,location:variant.installationRoot,requiredBytes:info.requiredBytes)}
      }
    }else if info.installedBytes==nil,game.store != .local,(game.store != .steam || steamNetwork?.state.online==true){
      requestGameStoragePlan(game:configured,variant:variant){[weak self,weak view]size,_ in
        guard let self,let view,self.gameDetailView===view,self.gameStorageRequest==epoch,self.state.activeProfile==profile else{return}
        view.updateStorage(variantID:variant.id,installedBytes:size.installedBytes,downloadBytes:size.downloadBytes,requiredBytes:size.requiredBytes)
      }
    }
  }
  @MainActor func showGameInstallation(index:Int,variant:GameVariant,showDownloads:Bool=true){
    guard !maintenanceInProgress,session?.running != true,pendingLaunch==nil,state.games.indices.contains(index)else{return}
    let game=state.configured(state.games[index]),profile=state.activeProfile
    guard !variant.installed,game.profileIDs==nil || game.profileIDs!.contains(profile)else{return}
    beginPage(.utility);gameDetailView=nil;gameDetailID=nil
    let id=UUID(),view=GameInstallationView(game:game,variant:variant);installationPickerID=id;installationPickerView=view
    var options=[GameInstallationOption](),selected:UUID?,info=GameStorageInfo(metadata:game.metadata ?? [:],platform:variant.platform),loading=true,planUsable=false,authRequired=false,message:String?
    let valid:()->Bool={ [weak self,weak view] in guard let self,let view else{return false};return self.installationPickerID==id && self.state.activeProfile==profile && self.installationPickerView===view && self.session?.running != true}
    let render:()->Void={ [weak view] in guard valid(),let view else{return};view.update(options:options,selected:selected,info:info,loading:loading,message:message,canInstall:planUsable,authorizationRequired:authRequired)}
    let back={ [weak self]in guard let self else{return};self.installationPickerView=nil;self.installationPickerID=nil;self.showGameDetails(id:game.id)}
    view.onCancel=back
    view.onLibraryChanged={value in selected=value;render()}
    view.onManage={[weak self]in
      guard let self,valid()else{return};self.installationPickerView=nil;self.installationPickerID=nil
      self.showStorageSettings(returnToGameID:game.id,onReturn:{[weak self]in guard let self,self.state.activeProfile==profile,let i=self.state.games.firstIndex(where:{$0.id==game.id})else{return};self.showGameInstallation(index:i,variant:variant,showDownloads:showDownloads)})
    }
    let calculate:()->Void={ [weak self] in
      guard let self,valid()else{return};loading=true;message=nil;render()
      self.requestGameStoragePlan(game:game,variant:variant){size,code in
        guard valid()else{return};loading=false;info=size;authRequired=["authentication_required","not_online","auth_required","credentials_missing"].contains(code ?? "")
        planUsable=code==nil && size.installedBytes != nil && size.verified && size.status=="available"
        if let code{message=authRequired ? "Accedi allo store per verificare dimensione e installazione.":"Dimensione non verificata: ricalcola quando lo store è disponibile (\(code))."}
        else if !planUsable{
          let reason=size.reason ?? size.status
          switch reason{
          case "ownership_unavailable","ownership_package_missing","ownership_package_invalid_id","ownership_package_response_incomplete":message="Steam non ha completato la lettura delle licenze. Questo non significa che il gioco non sia acquistato. Riprova il calcolo (\(reason))."
          case "size_plan_timeout":message="Steam non ha completato il calcolo in tempo. Riprova quando la connessione è stabile."
          case "depot_access_unconfirmed":message="Steam non ha confermato l’accesso ai contenuti di questa versione. Riprova il calcolo con l’account proprietario."
          case "platform_unavailable":message="Lo store non pubblica questa versione per la piattaforma selezionata."
          default:message="Il piano di installazione non è ancora verificato (\(reason)). Riprova il calcolo."
          }
        }
        render()
      }
    }
    view.onPlan={[weak self]in
      guard let self,valid()else{return}
      if authRequired,game.store == .steam{
        self.installationPickerView=nil;self.installationPickerID=nil
        self.steamLaunchContinuation={[weak self]in guard let self,let i=self.state.games.firstIndex(where:{$0.id==game.id})else{return};self.showGameInstallation(index:i,variant:variant,showDownloads:showDownloads)}
        self.steamLaunchCancellation=back;self.showSteamAccount()
      }else if authRequired{self.connectStore()}
      else{calculate()}
    }
    view.onInstall={[weak self,weak view]in
      guard let self,let view,valid(),let selected,planUsable,let bytes=info.reservationBytes else{return}
      view.setWorking("Prenotazione dello spazio e verifica della cartella…")
      let registry=self.storageLibraries
      DispatchQueue.global(qos:.utility).async{
        let result=Result{()->(StorageReservation,URL)in
          let reservation=try registry.reserve(libraryID:selected,store:game.store,gameID:game.storeID,platform:variant.platform,bytes:bytes,profileID:profile)
          do{return(reservation,try registry.installationURL(for:reservation))}catch{try?registry.release(reservationID:reservation.id);throw error}
        }
        DispatchQueue.main.async{[weak self]in MainActor.assumeIsolated{
          guard let self else{return}
          guard valid()else{if case .success(let value)=result{try?registry.release(reservationID:value.0.id)};return}
          switch result{
          case .failure(let error):loading=false;message=error.localizedDescription;render()
          case .success(let (reservation,target)):
            self.installationPickerView=nil;self.installationPickerID=nil
            if game.store == .steam{
              if self.steamDownloads==nil{self.configureSteamNetwork()}
              self.steamDownloads?.enqueue(game:self.state.configured(self.state.games.first(where:{$0.id==game.id}) ?? game),variant:variant,installation:target,reservationID:reservation.id){[weak self]result in
                guard let self else{return}
                DispatchQueue.global(qos:.utility).async{
                  if case .failure=result{try?registry.release(reservationID:reservation.id)}
                }
                if case .failure(let error)=result{self.showError(error)}
              }
              if showDownloads{self.showSteamDownloads()}else{self.showGameDetails(id:game.id)}
            }else{self.performOtherStoreInstallation(game:game,variant:variant,profile:profile,base:target,reservation:reservation)}
          }
        }}
      }
    }
    pages.configureNavigation(title:"Installazione",tabs:[],selected:nil,onBack:back)
    pages.present(title:"Installa",message:"Scegli una libreria giochi. Le installazioni restano condivise tra profili; ambienti Windows e salvataggi personali rimangono separati.",content:view,actions:[],onCancel:{[weak self]in if self?.installationPickerID==id{self?.installationPickerView=nil;self?.installationPickerID=nil}}){_ in}
    render()
    let registry=storageLibraries
    DispatchQueue.global(qos:.utility).async{
      let result=Result{try registry.list()}
      DispatchQueue.main.async{guard valid()else{return};switch result{
      case .success(let values):options=values.map{GameInstallationOption(id:$0.id,title:$0.library.name+($0.isDefault ? " · Predefinita":""),path:$0.library.rootPath,availableBytes:$0.availableBytes,usable:$0.availability == .online,issue:$0.availability == .online ? nil:"Volume non disponibile o non scrivibile")};selected=values.first{$0.isDefault}?.id;render();calculate()
      case .failure(let error):loading=false;message=error.localizedDescription;render()
      }}
    }
  }
}
