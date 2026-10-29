// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import LauncherCore

extension AppDelegate {
  @MainActor func showLaunchSplash(game:Game,variant:GameVariant,launchID:UUID){
    finishLaunchSplash()
    let profile=state.activeProfile
    let splash=GameLaunchSplash(game:game)
    launchSplash=splash;launchSplashID=launchID
    splash.onCancel = {[weak self] in
      guard let self,self.launchSplashID==launchID,self.state.activeProfile==profile else{return}
      self.pendingLaunch=nil
      let stopping=self.session?.running==true
      if stopping{self.launchReturnGame=(game.id,profile);self.session.quit()}
      self.cancelSteamGamePreparation();self.finishLaunchSplash()
      self.canvas.message=""
      if !stopping{self.showGameDetails(id:game.id)}
    }
    splash.onRetry = {[weak self] in
      guard let self,self.launchSplashID==launchID,self.state.activeProfile==profile else{return}
      self.pendingLaunch=nil;self.cancelSteamGamePreparation();self.finishLaunchSplash()
      guard let current=self.state.games.first(where:{$0.id==game.id}),
        let selected=self.state.configured(current).variants.first(where:{$0.id==variant.id}) else{return}
      self.launchGame(self.state.configured(current),variant:selected)
    }
    resumeLaunchSplash()
    if game.store == .steam {
      requestSteamGameDetails(gameID:game.storeID){[weak self,weak splash] _ in
        guard let self,let splash,self.launchSplashID==launchID,
          let fresh=self.state.games.first(where:{$0.id==game.id}) else{return}
        splash.update(game:self.state.configured(fresh))
      }
    }
  }
  @MainActor func suspendLaunchSplashForAccount(){launchSplash?.removeFromSuperview()}
  @MainActor func resumeLaunchSplash(){
    guard let splash=launchSplash,let parent=window?.contentView else{return}
    splash.frame=parent.bounds;splash.autoresizingMask=[.width,.height]
    if splash.superview !== parent{parent.addSubview(splash,positioned:.above,relativeTo:nil)}
    window.makeFirstResponder(splash)
  }
  @MainActor func finishLaunchSplash(){
    launchSplash?.finish();launchSplash=nil;launchSplashID=nil
  }
}
