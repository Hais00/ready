// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CoreFoundation

// Layout-only model/host stubs. The actual production dialog presenter and
// SteamAccountView are compiled unchanged; no network/vault/runtime is present.
struct SteamFriendState {let id:String;var displayName:String;var presence:String;var gameID:String?;var gameName:String?;var relationship="Friend"}
struct SteamClientState {
  var connection="offline",reason="",accountName="",displayName="",steamID="",presence="offline",warning=""
  var friends=[SteamFriendState]();var retryAfter:Double?
  var online:Bool{connection=="online"}
}
final class MetalCanvas:NSView {
  enum Section {case library,utility}
  var interactionEnabled=true
  var section:Section = .library
}
final class LayoutSession {var running=false}
final class AppDelegate:NSObject {
  var dialogs:ReadyDialogPresenter!,pages:ReadyPagePresenter!,canvas:MetalCanvas!,session:LayoutSession?
  func beginPage(_ section:MetalCanvas.Section){canvas?.section=section}
  func setPresentationActionEnabled(_ id:UUID,index:Int,enabled:Bool){}
  func activatePresentationPrimary(_ id:UUID){}
}
enum ControllerNavigation {
  enum Direction{case up,down,left,right}
  enum Action:Equatable{case cancel,activate,move(Direction)}
  static func handleModal(_ action:Action,window:NSWindow){}
}
private func descendants(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(descendants)}
private func rect(_ value:NSRect)->[String:Double]{["x":value.minX,"y":value.minY,"width":value.width,"height":value.height]}
private func settle(_ window:NSWindow){
  for _ in 0..<5{window.contentView?.layoutSubtreeIfNeeded();RunLoop.current.run(until:Date().addingTimeInterval(0.02))}
}
@main private struct ReadySteamAccountLayoutProbe {
  @MainActor static func main()throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let output=URL(fileURLWithPath:CommandLine.arguments[1]),baseline=CommandLine.arguments.contains("--observe")
    var results=[[String:Any]](),checks=[String:Bool]()
    for width:CGFloat in [556,460] {
      let window=NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:width+128,height:920),styleMask:[.titled],backing:.buffered,defer:false)
      window.title="ready isolated layout fixture";window.isReleasedWhenClosed=false
      window.contentView=NSView(frame:NSRect(x:0,y:0,width:width+128,height:920))
      let presenter=ReadyDialogPresenter(window:{window})
      let content=SteamAccountView(frame:NSRect(x:0,y:0,width:660,height:710))
      var state=SteamClientState();content.update(state)
      let id=presenter.present(title:"Steam · account, amici e attività",message:"Un solo accesso per questo profilo, condiviso da giochi macOS e Windows. La password non viene salvata.",content:content,actions:[.init("Chiudi",role:.cancel)]){_ in}
      func capture(_ phase:String)->[String:Any] {
        settle(window)
        let form=content.subviews.compactMap{$0 as?NSStackView}.first!
        let scroll=content.enclosingScrollView!,document=scroll.documentView!
        let image=descendants(content).compactMap{$0 as?NSImageView}.first!
        let guardRow=descendants(content).first{$0.identifier?.rawValue=="steam.guard"}!
        let ownControls=descendants(form).compactMap{$0 as?NSControl}.filter{!$0.isHiddenOrHasHiddenAncestor && !($0 is NSScroller)}
        let clipped=ownControls.filter{control in
          let aligned=content.convert(control.alignmentRect(forFrame:control.frame),from:control.superview)
          return control.bounds.height<16 || aligned.minX < -1 || aligned.maxX>content.bounds.width+1
        }
        let imageRect=document.convert(image.bounds,from:image),visible=scroll.documentVisibleRect
        let qrVisible=image.image != nil && !image.isHiddenOrHasHiddenAncestor && visible.insetBy(dx:-1,dy:-1).contains(imageRect)
        return ["width":width,"phase":phase,"content":rect(content.frame),"form":rect(form.frame),"formFitting":rect(NSRect(origin:.zero,size:form.fittingSize)),
          "document":rect(document.frame),"viewport":rect(visible),"qr":rect(imageRect),"qrVisible":qrVisible,
          "qrShown":image.image != nil && !image.isHiddenOrHasHiddenAncestor,"guardShown":!guardRow.isHiddenOrHasHiddenAncestor,
          "guardHeight":guardRow.frame.height,"clippedControlCount":clipped.count,"clippedTitles":clipped.map{($0 as?NSButton)?.title ?? ($0 as?NSTextField)?.placeholderString ?? "label"},
          "clippedGeometry":clipped.map{["class":NSStringFromClass(type(of:$0)),"frame":rect($0.frame),"intrinsic":rect(NSRect(origin:.zero,size:$0.intrinsicContentSize)),"text":($0 as?NSTextField)?.stringValue ?? ""]}]
      }
      let offline=capture("offline");results.append(offline)
      state.connection="authenticating";content.update(state)
      content.authenticationEvent(["type":"qr","url":"https://example.invalid/isolated-layout-fixture"])
      let qr=capture("qr");results.append(qr)
      if let host=window.contentView,let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds){host.cacheDisplay(in:host.bounds,to:bitmap);if let png=bitmap.representation(using:.png,properties:[:]){try png.write(to:output.deletingLastPathComponent().appendingPathComponent("qr-\(Int(width)).png"))}}
      let outer=content.enclosingScrollView!
      outer.contentView.scroll(to:.zero);outer.reflectScrolledClipView(outer.contentView)
      let away=capture("qr-scrolled-to-top");results.append(away)
      content.authenticationEvent(["type":"qr","url":"https://example.invalid/isolated-layout-rotation"])
      let rotated=capture("qr-rotated");results.append(rotated)
      for _ in 0..<25{content.update(state)}
      let repeated=capture("qr-repeated-state");results.append(repeated)
      content.authenticationEvent(["type":"guard","method":"device_code","challengeID":"fixture-layout-challenge"])
      let guardLayout=capture("guard");results.append(guardLayout)
      state.connection="online";state.accountName="fixture_account";state.displayName="Fixture Public Name";state.presence="online"
      state.friends=(1...40).map{SteamFriendState(id:String(76561198000000000+$0),displayName:"Fixture friend \($0)",presence:$0%2==0 ? "offline":"online",gameID:nil,gameName:nil)}
      content.update(state)
      let online=capture("online");results.append(online)
      state.connection="authenticating";content.update(state)
      content.authenticationEvent(["type":"guard","method":"device_confirmation"])
      let mobile=capture("mobile-confirmation");results.append(mobile)
      let key=String(Int(width))
      checks[key+"-QR-auto-scroll-visible"]=(qr["qrVisible"]as?Bool)==true
      checks[key+"-QR-controls-unclipped"]=(qr["clippedControlCount"]as?Int)==0
      checks[key+"-guard-controls-unclipped"]=(guardLayout["clippedControlCount"]as?Int)==0 && (guardLayout["guardHeight"]as?CGFloat ?? 0)>=16
      checks[key+"-online-controls-unclipped"]=(online["clippedControlCount"]as?Int)==0
      checks[key+"-online-hides-QR-and-guard"]=(online["qrShown"]as?Bool)==false && (online["guardShown"]as?Bool)==false
      checks[key+"-offline-controls-unclipped"]=(offline["clippedControlCount"]as?Int)==0
      checks[key+"-rotation-reveals-QR-after-user-scroll"]=(away["qrVisible"]as?Bool)==false && (rotated["qrVisible"]as?Bool)==true
      checks[key+"-repeated-state-keeps-QR-and-controls"]=(repeated["qrVisible"]as?Bool)==true && (repeated["clippedControlCount"]as?Int)==0
      checks[key+"-mobile-confirmation-hides-code-and-QR"]=(mobile["guardShown"]as?Bool)==false && (mobile["qrShown"]as?Bool)==false
      let phases=[offline,qr,rotated,repeated,guardLayout,online,mobile]
      checks[key+"-content-and-document-follow-natural-height"]=phases.allSatisfy{row in
        let body=row["content"]as![String:Double],fitting=row["formFitting"]as![String:Double],document=row["document"]as![String:Double]
        return abs(body["height"]!-fitting["height"]!)<=1 && document["height"]!>=body["height"]!
      }
      let qh=(qr["content"]as![String:Double])["height"]!,oh=(online["content"]as![String:Double])["height"]!
      checks[key+"-online-collapses-QR-space"]=qh-oh>=250 && oh<710
      presenter.dismiss(id)
      let next=SteamAccountView(frame:NSRect(x:0,y:0,width:660,height:710))
      let nextID=presenter.present(title:"Fixture next dialog",message:"Independent content",content:next,actions:[.init("Close",role:.cancel)]){_ in}
      settle(window);let before=next.enclosingScrollView!.documentView!.frame
      content.authenticationEvent(["type":"qr","url":"https://example.invalid/old-detached-content"])
      settle(window)
      checks[key+"-detached-content-cannot-resize-next-dialog"]=next.enclosingScrollView!.documentView!.frame==before
      presenter.dismiss(nextID);window.close()
    }
    let passed=checks.values.allSatisfy{$0}
    let report:[String:Any] = ["passed":passed,"observationalBaseline":baseline,"count":checks.count,"checks":checks,"geometry":results,
      "realSteamAccountView":true,"realReadyDialogPresenter":true,"fixtureOnly":true,"windowsShown":false,"realAccountUsed":false,"networkOrKeychainUsed":false]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output)
    print(String(decoding:try JSONSerialization.data(withJSONObject:["passed":passed,"observationalBaseline":baseline,"checks":checks],options:[.sortedKeys]),as:UTF8.self))
    if !baseline && !passed{exit(1)}
  }
}
