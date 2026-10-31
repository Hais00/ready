// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import LauncherCore
import Metal

private final class OffscreenCanvasWindow: NSWindow {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
@main struct ReadyCanvasSectionsProbe {
  static func require(_ value: Bool, _ name: String) throws { if !value { throw NSError(domain: name, code: 1) } }
  static func main() throws {
    _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    guard CommandLine.arguments.count == 2, let device = MTLCreateSystemDefaultDevice() else { throw NSError(domain: "ArgumentsOrMetal", code: 1) }
    let root = URL(fileURLWithPath: CommandLine.arguments[1]);try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
    let canvas = MetalCanvas(frame: NSRect(x:0,y:0,width:1240,height:760),device:device)
    canvas.state.games = [Game(id:"section-a",store:.steam,storeID:"fixture-a",title:"Fixture A"),Game(id:"section-b",store:.steam,storeID:"fixture-b",title:"Fixture B")]
    canvas.filter = .steam;canvas.query = "Fixture"
    let window = OffscreenCanvasWindow(contentRect:NSRect(x:-8192,y:-8192,width:1240,height:760),styleMask:[.borderless],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.contentView=canvas;window.makeFirstResponder(canvas)
    defer { canvas.releaseGraphics();window.close() }
    var actions=[CanvasAction]();canvas.onAction={actions.append($0)}
    func key(_ code:UInt16,_ flags:NSEvent.ModifierFlags = []) {
      canvas.renderDisplayTick() // Service the coalesced frame in this hidden fixture.
      let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!
      canvas.keyDown(with:event)
    }
    func mouse(_ type:NSEvent.EventType,_ point:CGPoint)->NSEvent {
      NSEvent.mouseEvent(with:type,location:canvas.convert(point,to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:type == .leftMouseDown ? 1:0)!
    }
    func preview(_ name:String)throws->NSBitmapImageRep {
      let path=root.appendingPathComponent(name+".png");try canvas.writePreview(path)
      return NSBitmapImageRep(data:try Data(contentsOf:path))!
    }
    func body(_ image:NSBitmapImageRep)->Data {
      let crop=image.cgImage!.cropping(to:CGRect(x:112,y:88,width:1092,height:648))!
      let raster=CanvasRaster(width:1092,height:648)!
      raster.context.draw(crop,in:CGRect(x:0,y:0,width:1092,height:648))
      return Data(bytes:raster.data,count:raster.bytesPerRow*raster.height)
    }
    func rgb(_ image:NSBitmapImageRep,_ hit:CanvasHit)->[Int] {
      let color=image.colorAt(x:Int(hit.rect.minX+9),y:Int(hit.rect.midY))!.usingColorSpace(.sRGB)!
      return [color.redComponent,color.greenComponent,color.blueComponent].map{Int(($0*255).rounded())}
    }
    func isGame(_ action:CanvasAction)->Bool {switch action {case .game,.gameOptions:return true;default:return false}}
    func actionKey(_ action:CanvasAction)->String {
      switch action {
      case .game(let id):return "game:"+id
      case .gameOptions(let id):return "options:"+id
      case .resumeGame(let id):return "resume:"+id
      case .librarySection(let flag):return "section:"+String(flag)
      case .store(let store):return "store:"+(store?.rawValue ?? "all")
      case .profiles:return "profiles"
      case .importGame:return "import"
      case .settings:return "settings"
      case .search:return "search"
      case .fullscreen:return "fullscreen"
      case .refresh:return "refresh"
      case .steamAccount:return "steamAccount"
      case .downloads:return "downloads"
      }
    }
    var checks=[String:Bool]();let library=try preview("library")
    try require(!canvas.interactionSnapshot.hits.contains{$0.id=="toolbar.refresh" || $0.id.hasPrefix("nav.store.") || $0.id.hasPrefix("library.section.")},"ObsoleteStoreOrContentOrRefreshTargetsRemain")
    checks["unifiedShellOmitsStoreSelectorsContentTabsAndRefresh"]=true
    var extraGame=Game(id:"other-store",store:.epic,storeID:"fixture-c",title:"Fixture C")
    var dlc=Game(id:"dlc",store:.steam,storeID:"fixture-dlc",title:"Fixture DLC");dlc.metadata=["libraryKind":.string("dlc")]
    canvas.state.games += [extraGame,dlc];canvas.query="Fixture";canvas.filter = .steam
    try require(canvas.visibleGames.count==3 && !canvas.visibleGames.contains{$0.id=="dlc"},"UnifiedGameOnlyFilterBroken")
    canvas.query="DLC";try require(canvas.visibleGames.isEmpty,"SearchReintroducesDLC")
    canvas.query="Fixture";canvas.state.games.removeAll{$0.id=="dlc" || $0.id=="other-store"}
    checks["allStoreGamesStayUnifiedAndSearchExcludesOtherContent"]=true
    canvas.runningGames=[ReadyShellRunningGame(id:"section-a",title:"Fixture A")];_ = try preview("running-game-dock")
    try require(canvas.interactionSnapshot.hits.contains{if case .resumeGame("section-a")=$0.action{return true};return false},"ActualRunningGameMissingFromDock")
    let model=canvas.shellSnapshot
    try require(model.activeGameIds==["section-a"] && model.resumeActionId=="resume:section-a" && model.boundedJSONData() != nil,"InjectedShellModelMismatch")
    canvas.runningGames=[];_ = try preview("no-running-game-dock")
    try require(!canvas.interactionSnapshot.hits.contains{if case .resumeGame=$0.action{return true};return false},"ClosedGameRetainedInDock")
    checks["runningDockUsesExplicitLifecycleAndBoundedMetadataSnapshot"]=true
    canvas.runningGames=[ReadyShellRunningGame(id:"section-a",title:"Fixture A")]
    canvas.gameInterfaceMode=true;canvas.currentGameID="section-a";canvas.currentGameName="Fixture A";canvas.section = .game
    let gameInterface=try preview("actual-game-interface")
    try require(gameInterface.colorAt(x:620,y:380)!.alphaComponent==0,"GameInterfacePaintedOverLiveGameCenter")
    try require(!canvas.interactionSnapshot.hits.contains{isGame($0.action)} && canvas.interactionSnapshot.hits.contains{if case .resumeGame("section-a")=$0.action{return true};return false},"GameInterfaceDidNotReuseActualDock")
    try require(canvas.shellSnapshot.title=="Fixture A","GameInterfaceHeaderLostActualGameName")
    checks["actualGameInterfaceUsesTransparentCenterAndSameDock"]=true
    canvas.section = .library
    let gameLibrary=try preview("actual-game-interface-library")
    try require(canvas.interactionSnapshot.hits.contains{isGame($0.action)} && gameLibrary.pixelsWide==1240 && gameLibrary.pixelsHigh==760,"GameInterfaceLibraryDidNotUseActualGridAtWindowResolution")
    checks["actualGameInterfaceLibraryUsesRealGridAndResolution"]=true
    canvas.gameInterfaceMode=false;canvas.currentGameID=nil;canvas.currentGameName=nil;canvas.runningGames=[]
    canvas.showStatus("123 contenuti sincronizzati da Steam");let normalStatus=try preview("normal-status-suppressed")
    canvas.showStatus("");let quietStatus=try preview("quiet-status")
    func footerBytes(_ image:NSBitmapImageRep)->Data {let crop=image.cgImage!.cropping(to:CGRect(x:112,y:705,width:1092,height:55))!;let raster=CanvasRaster(width:1092,height:55)!;raster.context.draw(crop,in:CGRect(x:0,y:0,width:1092,height:55));return Data(bytes:raster.data,count:raster.bytesPerRow*raster.height)}
    try require(footerBytes(normalStatus)==footerBytes(quietStatus),"InformationalFooterStillDrawn")
    canvas.showErrorNotice("Errore di prova");let errorStatus=try preview("error-status")
    try require(footerBytes(errorStatus) != footerBytes(quietStatus),"ErrorFooterNotVisible")
    canvas.showStatus("");checks["footerOnlyRendersErrors"]=true
    _ = try preview("library-reset")
    let original=canvas.interactionSnapshot.hits
    let inactiveRGB=rgb(library,original.first{$0.id=="nav.settings"}!)
    let gameHit=original.first{if case .game=$0.action{return true};return false}!
    let gamePoint=CGPoint(x:gameHit.rect.midX,y:gameHit.rect.midY)
    canvas.mouseDown(with:mouse(.leftMouseDown,gamePoint))
    canvas.section = .settings
    canvas.mouseUp(with:mouse(.leftMouseUp,gamePoint))
    try require(actions.isEmpty,"StaleLibraryPressActivatedAfterPageChange");checks["pageChangeCancelsInFlightGamePress"]=true
    var firstPage:Data?
    let pages:[(CanvasSection,String,String?)]=[(.settings,"settings","nav.settings"),(.steamAccount,"steamAccount","nav.friends"),(.downloads,"downloads","nav.downloads"),(.profiles,"profiles",nil),(.utility,"utility",nil)]
    for(section,name,active)in pages {
      canvas.section = .library;canvas.selected=1;canvas.section=section;canvas.selected=0
      let image=try preview(name);let hits=canvas.interactionSnapshot.hits
      try require(!hits.contains{isGame($0.action)||$0.id.hasPrefix("feature.")||$0.id.hasPrefix("empty.")},"PageContainsLibraryTargets:"+name)
      let pixels=body(image);if let firstPage {try require(firstPage==pixels,"NonLibraryBodyDrawn:"+name)}else{firstPage=pixels}
      try require(body(library) != pixels,"LibraryBodyWasNotRemoved")
      let controllerBefore=actions.count,controllerSelected=canvas.selected
      try require(canvas.interactionSnapshot.focus==nil,"PageRetainedGameFocus:"+name)
      canvas.handleShellController(.activate)
      try require(actions.count==controllerBefore,"NilFocusControllerALaunchedGame:"+name)
      var controllerIndex:Int?
      for direction:ControllerNavigation.Direction in [.right,.down,.left,.up] {
        let step=direction == .left || direction == .up ? -1:1
        let previous=controllerIndex ?? (step>0 ? -1:0)
        controllerIndex=(previous+step+hits.count)%hits.count
        let target=hits[controllerIndex!]
        canvas.handleShellController(.move(direction))
        try require(canvas.interactionSnapshot.focus==target.id && !isGame(target.action),"DpadDidNotChooseVisibleShellTarget:"+name)
        let count=actions.count;canvas.handleShellController(.activate)
        try require(actions.count==count+1 && actionKey(actions.last!)==actionKey(target.action) && !isGame(actions.last!),"ControllerADidNotActivateFocusedShell:"+name)
      }
      try require(canvas.selected==controllerSelected && !canvas.interactionSnapshot.hits.contains{isGame($0.action)},"ControllerSelectedHiddenGame:"+name)
      checks[name+"ShellControllerNilFocusDpadAndA"]=true
      // Reset to a nil page focus before the independent keyboard checks.
      canvas.section = .library;canvas.selected=1;canvas.selected=0;canvas.section=section
      let before=actions.count,selected=canvas.selected
      key(123);key(124);key(36);key(49)
      try require(actions.count==before && canvas.selected==selected,"PageKeyboardLaunchedOrSelectedGame:"+name)
      key(48);key(36)
      try require(actions.count==before+1 && !isGame(actions.last!),"PageTabNavigationCannotActivate:"+name)
      key(48,.shift);key(49);try require(actions.count==before+2 && !isGame(actions.last!),"PageSpaceCannotActivateNavigation:"+name)
      let account=hits.first{$0.id=="toolbar.steam.account"}!,point=CGPoint(x:account.rect.midX,y:account.rect.midY)
      canvas.mouseDown(with:mouse(.leftMouseDown,point));canvas.mouseUp(with:mouse(.leftMouseUp,point));if case .steamAccount=actions.last! {}else{throw NSError(domain:"AccountMissing",code:1)}
      // Pixel-check active fills outside glyphs, using the same production scene.
      for hit in hits where hit.id=="nav.library"||["nav.settings","nav.downloads","nav.friends"].contains(hit.id) {
        let actual=rgb(image,hit)
        let matchesInactive=zip(actual,inactiveRGB).allSatisfy{abs($0.0-$0.1)<=2}
        let neutral=abs(actual[0]-actual[1])<=2 && abs(actual[1]-actual[2])<=2
        try require(hit.id==active ? (neutral && !matchesInactive && actual[0]>inactiveRGB[0]+10):matchesInactive,"WrongSectionHighlight:"+name+":"+hit.id+":"+String(describing:actual))
      }
      checks[name+"ShellBodyHitsKeyboardAndHighlights"]=true
      // Clear focus through a real page transition before the next nil-focus test.
      canvas.section = .library
    }
    canvas.section = .utility;canvas.filter=nil;let utility=try preview("utility-no-filter");let home=canvas.interactionSnapshot.hits.first{$0.id=="nav.library"}!
    try require(zip(rgb(utility,home),inactiveRGB).allSatisfy{abs($0.0-$0.1)<=2},"UtilityHomeStillActive");checks["utilityNeverHighlightsLibraryEvenWithoutFilter"]=true
    canvas.section = .library;canvas.filter = .steam;canvas.selected=1;_ = try preview("library-return")
    try require(canvas.interactionSnapshot.hits.contains{isGame($0.action)},"LibraryTargetsNotRestored");let before=actions.count;key(36);try require(actions.count==before+1&&isGame(actions.last!),"LibraryReturnKeyNoLongerLaunches")
    checks["libraryBehaviorRestoredAfterNavigation"]=true
    let libraryControllerCount=actions.count,librarySelection=canvas.selected,libraryFocus=canvas.interactionSnapshot.focus
    canvas.handleShellController(.move(.right));canvas.handleShellController(.activate)
    try require(actions.count==libraryControllerCount && canvas.selected==librarySelection && canvas.interactionSnapshot.focus==libraryFocus,"ShellControllerInterceptedLibrary")
    checks["shellControllerIgnoresLibrary"]=true
    canvas.section = .settings;canvas.handleShellController(.move(.right))
    canvas.interactionEnabled=false
    let disabledCount=actions.count,disabledFocus=canvas.interactionSnapshot.focus
    canvas.handleShellController(.move(.down));canvas.handleShellController(.activate)
    try require(actions.count==disabledCount && canvas.interactionSnapshot.focus==disabledFocus,"DisabledCanvasControllerActivated")
    canvas.interactionEnabled=true;checks["disabledCanvasBlocksShellController"]=true
    canvas.releaseGraphics();canvas.section = .settings
    let releasedCount=actions.count,releasedFocus=canvas.interactionSnapshot.focus
    canvas.handleShellController(.move(.right));canvas.handleShellController(.activate)
    try require(actions.count==releasedCount && canvas.interactionSnapshot.focus==releasedFocus && canvas.interactionSnapshot.hits.isEmpty,"SuspendedControllerActivatedOrRepopulatedHits")
    checks["releasedGraphicsBlocksShellController"]=true
    try require(canvas.allocatedTextureBytes==0,"PageChangeReallocatedSuspendedGraphics");canvas.resumeGraphics();_ = try preview("settings-resumed")
    try require(!canvas.interactionSnapshot.hits.contains{isGame($0.action)},"ResumeRestoredStaleLibraryTargets");checks["graphicsReleaseResumePreservesSectionIsolation"]=true
    let resumedCount=actions.count;canvas.handleShellController(.move(.down));canvas.handleShellController(.activate)
    try require(actions.count==resumedCount+1 && !isGame(actions.last!),"ResumedControllerFailedVisibleShellActivation")
    checks["resumedGraphicsRestoresOnlyShellControllerTargets"]=true
    let result:[String:Any]=["passed":true,"checks":checks,"count":checks.count,"ownOffscreenWindow":true,"windowActivated":false,"globalInputInjected":false,"CUAInteractionVerified":false]
    print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys,.prettyPrinted]),as:UTF8.self))
  }
}
