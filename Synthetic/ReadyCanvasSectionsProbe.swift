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
    _ = NSApplication.shared
    guard CommandLine.arguments.count == 2, let device = MTLCreateSystemDefaultDevice() else { throw NSError(domain: "ArgumentsOrMetal", code: 1) }
    let root = URL(fileURLWithPath: CommandLine.arguments[1]);try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
    let canvas = MetalCanvas(frame: NSRect(x:0,y:0,width:1240,height:760),device:device)
    canvas.state.games = [Game(id:"section-a",store:.steam,storeID:"fixture-a",title:"Fixture A"),Game(id:"section-b",store:.steam,storeID:"fixture-b",title:"Fixture B")]
    canvas.filter = .steam;canvas.query = "Fixture"
    let window = OffscreenCanvasWindow(contentRect:NSRect(x:-8192,y:-8192,width:1240,height:760),styleMask:[.borderless],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.contentView=canvas;window.orderBack(nil);window.makeFirstResponder(canvas)
    defer { canvas.releaseGraphics();window.close() }
    var actions=[CanvasAction]();canvas.onAction={actions.append($0)}
    func key(_ code:UInt16,_ flags:NSEvent.ModifierFlags = []) {
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
    let original=canvas.interactionSnapshot.hits
    let inactiveRGB=rgb(library,original.first{$0.id=="nav.home"}!)
    let gameHit=original.first{if case .game=$0.action{return true};return false}!
    let gamePoint=CGPoint(x:gameHit.rect.midX,y:gameHit.rect.midY)
    canvas.mouseDown(with:mouse(.leftMouseDown,gamePoint))
    canvas.section = .settings
    canvas.mouseUp(with:mouse(.leftMouseUp,gamePoint))
    try require(actions.isEmpty,"StaleLibraryPressActivatedAfterPageChange");checks["pageChangeCancelsInFlightGamePress"]=true
    var firstPage:Data?
    let pages:[(CanvasSection,String,String?)]=[(.settings,"settings","nav.settings"),(.steamAccount,"steamAccount","toolbar.steam.account"),(.downloads,"downloads","nav.downloads"),(.profiles,"profiles","nav.profiles"),(.utility,"utility",nil)]
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
      let refresh=hits.first{$0.id=="toolbar.refresh"}!,point=CGPoint(x:refresh.rect.midX,y:refresh.rect.midY)
      canvas.mouseDown(with:mouse(.leftMouseDown,point));canvas.mouseUp(with:mouse(.leftMouseUp,point));if case .refresh=actions.last! {}else{throw NSError(domain:"RefreshMissing",code:1)}
      // Pixel-check active fills outside glyphs, using the same production scene.
      for hit in hits where hit.id=="nav.home"||hit.id.hasPrefix("nav.store.")||["nav.settings","nav.profiles","nav.downloads","toolbar.steam.account"].contains(hit.id) {
        let actual=rgb(image,hit)
        let matchesInactive=zip(actual,inactiveRGB).allSatisfy{abs($0.0-$0.1)<=2}
        try require(hit.id==active ? (!matchesInactive && actual[1]>actual[0]+15):matchesInactive,"WrongSectionHighlight:"+name+":"+hit.id+":"+String(describing:actual))
      }
      checks[name+"ShellBodyHitsKeyboardAndHighlights"]=true
      // Clear focus through a real page transition before the next nil-focus test.
      canvas.section = .library
    }
    canvas.section = .utility;canvas.filter=nil;let utility=try preview("utility-no-filter");let home=canvas.interactionSnapshot.hits.first{$0.id=="nav.home"}!
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
