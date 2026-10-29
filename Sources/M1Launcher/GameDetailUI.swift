// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import LauncherCore

extension AppDelegate {
  @MainActor func showGameDetails(id:String){
    guard !maintenanceInProgress,session?.running != true,pendingLaunch==nil,
      let stored=state.games.first(where:{$0.id==id}),stored.profileIDs==nil || stored.profileIDs!.contains(state.activeProfile)else{return}
    let game=state.configured(stored),profile=state.activeProfile
    beginPage(.utility)
    let view=GameDetailView(game:game,artwork:canvas.artworkCache,profile:profile)
    gameDetailView=view;gameDetailID=id
    view.onPlay={[weak self,weak view] variant in
      guard let self,let view,self.gameDetailView===view,self.state.activeProfile==profile,
        !self.maintenanceInProgress,self.session?.running != true,self.pendingLaunch==nil,
        let stored=self.state.games.first(where:{$0.id==id}),stored.profileIDs==nil || stored.profileIDs!.contains(profile)else{return}
      let current=self.state.configured(stored)
      guard let selected=current.variants.first(where:{$0.id==variant.id}),selected.installed else{return}
      self.launchGame(current,variant:selected)
    }
    view.onInstall={[weak self,weak view] variant in
      guard let self,let view,self.gameDetailView===view,self.state.activeProfile==profile,
        !self.maintenanceInProgress,self.session?.running != true,self.pendingLaunch==nil,
        let index=self.state.games.firstIndex(where:{$0.id==id})else{return}
      let current=self.state.configured(self.state.games[index])
      guard current.profileIDs==nil || current.profileIDs!.contains(profile),
        let selected=current.variants.first(where:{$0.id==variant.id}),!selected.installed else{return}
      self.installGame(index:index,variant:selected,showDownloads:false)
    }
    view.onOptions={[weak self,weak view]in
      guard let self,let view,self.gameDetailView===view,self.state.activeProfile==profile else{return}
      self.gameOptions(id)
    }
    view.onDownloadControl={[weak self,weak view]jobID,action in
      guard let self,let view,self.gameDetailView===view,self.state.activeProfile==profile,
        self.steamDownloads?.profile==profile else{return}
      self.steamDownloads?.control(jobID,action:action)
    }
    view.onDetach={[weak self,weak view]in
      guard let self,let view,self.gameDetailView===view else{return}
      self.gameDetailView=nil;self.gameDetailID=nil
    }
    pages.configureNavigation(title:"Libreria",tabs:[],selected:nil,onBack:{[weak self]in self?.navigateToLibrary(store:self?.canvas.filter,preservingSelection:true)})
    pages.present(title:"",message:"",content:view,actions:[],onCancel:{[weak self,weak view]in
      guard let self,self.gameDetailView===view else{return};self.gameDetailView=nil;self.gameDetailID=nil
    }){_ in}
    view.update(game:game,jobs:steamDownloads?.snapshot ?? [])
    canvas.artworkCache.prefetch(game:game)
    if game.store == .steam {
      canvas.artworkCache.revalidate(game:game)
      requestSteamGameDetails(gameID:game.storeID,refresh:true){[weak self,weak view]_ in
        guard let self,let view,self.gameDetailView===view,self.state.activeProfile==profile else{return}
        self.refreshGameDetails()
        if let stored=self.state.games.first(where:{$0.id==id}) {
          let updated=self.state.configured(stored)
          if GameArtwork.Role.allCases.contains(where:{GameArtwork.candidates(for:game,role:$0) != GameArtwork.candidates(for:updated,role:$0)}){self.canvas.artworkCache.revalidate(game:updated)}
        }
      }
    }
  }
  @MainActor func refreshGameDetails(){
    guard let view=gameDetailView,let id=gameDetailID,session?.running != true,pendingLaunch==nil else{return}
    guard view.profile==state.activeProfile,let game=state.games.first(where:{$0.id==id}),game.profileIDs==nil || game.profileIDs!.contains(state.activeProfile)else{
      navigateToLibrary(store:canvas.filter,preservingSelection:true);return
    }
    view.update(game:state.configured(game),jobs:steamDownloads?.snapshot ?? [])
  }
}
