// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import LauncherCore

extension AppDelegate {
  /// Only the actual interface mounted by the hosted controller enables UI
  /// navigation while a game is live. Merely having a running process does not.
  var gameInterfaceVisible:Bool {
    guard Thread.isMainThread else{return false}
    return MainActor.assumeIsolated{hostedPresentation?.interfaceVisible==true}
  }
  var canNavigateInterfaceWhilePlaying:Bool {session?.running != true || gameInterfaceVisible}

  @MainActor func beginGameInterface(gameID:String){
    guard session?.running==true,let game=state.games.first(where:{$0.id==gameID}) else{return}
    pageNavigationTransition=true
    pages.cancelCurrent();_ = pages.detachForSession()
    pageNavigationTransition=false
    canvas.gameInterfaceMode=true;canvas.currentGameID=game.id;canvas.currentGameName=LibraryEntryPresentation.title(game)
    canvas.runningGames=[ReadyShellRunningGame(id:game.id,title:LibraryEntryPresentation.title(game))]
    canvas.section = .game;canvas.pageTitle=LibraryEntryPresentation.title(game)
    canvas.interactionEnabled=true
    canvas.artworkCache.resumeForGameInterface()
    canvas.resumeGraphics();canvas.refresh()
  }

  @MainActor func endGameInterface(){
    guard canvas != nil else{return}
    pageNavigationTransition=true
    pages.cancelCurrent();_ = pages.detachForSession()
    pageNavigationTransition=false
    gameDetailView=nil;gameDetailID=nil;installationPickerView=nil;installationPickerID=nil
    steamAccountView=nil;steamDownloadsView=nil
    // Retire all real UI graphics and decoded artwork while the game remains
    // open. Release first, then reset mode, avoiding an opaque intermediate UI.
    canvas.releaseGraphics()
    canvas.artworkCache.beginGameplay();canvas.artworkCache.setMaintenanceSuspended(true)
    canvas.gameInterfaceMode=false;canvas.currentGameName=nil;canvas.currentGameID=nil
    canvas.section = .library;canvas.pageTitle=nil
  }
}

extension AppDelegate {
  @MainActor @discardableResult func handleGameInterfaceController(_ action:ControllerNavigation.Action)->Bool {
    guard gameInterfaceVisible,!maintenanceInProgress,NSApp.isActive else{return false}
    if dialogs.isPresenting{dialogs.handleController(action);return true}
    if pages.isPresenting{
      if let detail=gameDetailView,detail.window===window,detail.handleController(action){return true}
      if let install=installationPickerView,install.window===window,install.handleController(action){return true}
      if action == .cancel{navigateToLibrary(preservingSelection:true);return true}
      if action == .previousStore || action == .nextStore{navigateToLibrary();return true}
      if !pages.handleController(action){canvas.handleShellController(action)}
      return true
    }
    if action == .cancel{session.resume();return true}
    if canvas.section != .library{canvas.handleShellController(action);return true}
    switch action{
    case .move(let direction):canvas.moveLibrarySelection(direction);canvas.refresh()
    case .activate:if canvas.visibleGames.indices.contains(canvas.selected){showGameDetails(id:canvas.visibleGames[canvas.selected].id)}
    case .previousStore,.nextStore:canvas.filter=nil;canvas.refresh()
    case .profiles:showSteamAccount()
    case .cancel:break
    }
    return true
  }
  @MainActor func moveGameInterfaceSelection(_ delta:Int){
    guard delta != 0 else{return};_ = handleGameInterfaceController(.move(delta>0 ? .down:.up))
  }
  @MainActor func activateGameInterfaceSelection(){_ = handleGameInterfaceController(.activate)}
}
