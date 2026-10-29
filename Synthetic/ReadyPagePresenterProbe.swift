// SPDX-License-Identifier: GPL-3.0-only
import AppKit

// Only model/host stubs; production page/dialog presenters and SteamAccountView
// are compiled verbatim. This executable has no network, vault or game runtime.
struct SteamFriendState {let id:String;var displayName:String;var presence:String;var gameID:String?;var gameName:String?;var relationship="Friend"}
struct SteamClientState {var connection="offline",reason="",accountName="",displayName="",steamID="",presence="offline",warning="";var friends=[SteamFriendState]();var retryAfter:Double?;var online:Bool{connection=="online"}}
final class MetalCanvas:NSView{enum Section{case library,utility};var interactionEnabled=true;var section:Section = .library}
final class FixtureSession{var running=false}
final class AppDelegate:NSObject{
  var dialogs:ReadyDialogPresenter!,pages:ReadyPagePresenter!,canvas:MetalCanvas!,session:FixtureSession?
  func beginPage(_ section:MetalCanvas.Section){canvas?.section=section}
  func setPresentationActionEnabled(_ id:UUID,index:Int,enabled:Bool){}
  func activatePresentationPrimary(_ id:UUID){}
}
enum ControllerNavigation{enum Direction:Equatable{case up,down,left,right};enum Action:Equatable{case cancel,activate,move(Direction)};static func handleModal(_ action:Action,window:NSWindow){}}
private enum Failure:Error{case check(String)}
private func all(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(all)}
private func settle(_ window:NSWindow){for _ in 0..<8{window.contentView?.layoutSubtreeIfNeeded();RunLoop.current.run(until:Date().addingTimeInterval(0.015))}}
private final class ClickCounter:NSObject{var count=0;@objc func clicked(_ sender:Any?){count+=1}}
@main private struct ReadyPagePresenterProbe {
  @MainActor static func main()throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    var checks=[String:Bool](),geometry=[[String:Any]]()
    func check(_ value:Bool,_ name:String)throws{guard value else{throw Failure.check(name)};checks[name]=true}
    for size in [NSSize(width:900,height:620),NSSize(width:1240,height:760)] {
      let window=NSWindow(contentRect:NSRect(origin:NSPoint(x:-10000,y:-10000),size:size),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
      window.isReleasedWhenClosed=false
      let host=MetalCanvas(frame:NSRect(origin:.zero,size:size));window.contentView=host
      let counter=ClickCounter(),sidebar=NSButton(title:"Sidebar fixture",target:counter,action:#selector(ClickCounter.clicked(_:)))
      sidebar.frame=NSRect(x:4,y:220,width:100,height:36);host.addSubview(sidebar)
      let search=NSTextField(frame:NSRect(x:200,y:size.height-22,width:140,height:18));search.placeholderString="Topbar fixture";host.addSubview(search)
      window.makeFirstResponder(search)
      let presenter=ReadyPagePresenter(window:{window},host:{host})
      var landing=0,cancelled=0,completions=[Int]()
      presenter.onNeedsLanding={landing+=1}
      let field=NSTextField(frame:NSRect(x:0,y:20,width:320,height:24));field.stringValue="retained form input"
      let content=NSView(frame:NSRect(x:0,y:0,width:500,height:100));content.addSubview(field)
      let originalDefault=window.defaultButtonCell,originalWindows=NSApplication.shared.windows.count
      var nextID:UUID?,initialBackCalls=0
      presenter.configureNavigation(title:"Settings",tabs:[
        .init(id:"profile",title:"Profiles fixture",action:{}),
        .init(id:"downloads",title:"Downloads fixture",action:{nextID=presenter.present(title:"Downloads",message:"",content:NSView(frame:NSRect(x:0,y:0,width:300,height:100)),actions:[.init("Close",role:.cancel)]){_ in}})
      ],selected:"profile",onBack:{initialBackCalls+=1})
      let id=presenter.present(title:"Profile settings",message:"Edit the form without leaving the sidebar.",content:content,actions:[.init("Save fixture",role:.primary),.init("Cancel fixture",role:.cancel)],onCancel:{cancelled+=1}){completions.append($0)}
      settle(window)
      func surface()->NSView{host.subviews.first{$0.identifier?.rawValue=="ready.page.surface"}!}
      func button(_ title:String)->NSButton{all(host).compactMap{$0 as?NSButton}.first{$0.title==title}!}
      let key="\(Int(size.width))x\(Int(size.height))"
      try check(surface().frame==NSRect(x:112,y:88,width:size.width-148,height:size.height-112),key+"-full-maincontent-rect")
      try check(host.interactionEnabled&&NSApplication.shared.windows.count==originalWindows&&window.defaultButtonCell===originalDefault,key+"-no-new-window-or-modal-host-disable [interaction=\(host.interactionEnabled), windows=\(originalWindows)/\(NSApplication.shared.windows.count), sameDefault=\(window.defaultButtonCell===originalDefault)]")
      let sidebarHit=host.hitTest(NSPoint(x:40,y:232)),searchHit=host.hitTest(NSPoint(x:220,y:size.height-12))
      try check(sidebarHit===sidebar||sidebarHit?.isDescendant(of:sidebar)==true,key+"-sidebar-hit-testing-preserved")
      try check(searchHit===search||searchHit?.isDescendant(of:search)==true,key+"-topbar-hit-testing-preserved")
      window.makeFirstResponder(search)
      try check(!presenter.handleController(.activate)&&presenter.isShowing(id),key+"-controller-outside-page-not-captured")
      sidebar.performClick(nil);try check(counter.count==1,key+"-sidebar-native-action-remains-usable")
      try check(button("Save fixture").keyEquivalent.isEmpty&&button("Cancel fixture").keyEquivalent.isEmpty,key+"-no-global-return-escape-equivalents")
      presenter.showNotice("Safe fixture error; correct the existing field.");settle(window)
      try check(presenter.isShowing(id)&&field.stringValue=="retained form input"&&cancelled==0&&completions.isEmpty,key+"-inline-notice-preserves-current-form")
      presenter.showNotice(nil);settle(window)
      window.setContentSize(NSSize(width:size.width+100,height:size.height+60));settle(window)
      try check(surface().frame==NSRect(x:112,y:88,width:size.width+100-148,height:size.height+60-112),key+"-window-resize-keeps-sidebar-and-maincontent-insets")
      window.setContentSize(size);settle(window)
      var navigationAllowed=false
      presenter.canNavigate={navigationAllowed}
      button("Downloads fixture").performClick(nil);settle(window)
      try check(presenter.isShowing(id)&&cancelled==0&&completions.isEmpty&&nextID==nil&&landing==0&&field.stringValue=="retained form input",key+"-blocked-tab-preserves-page-before-any-cancellation")
      button("← Indietro").performClick(nil);settle(window)
      try check(presenter.isShowing(id)&&cancelled==0&&completions.isEmpty&&initialBackCalls==0&&landing==0,key+"-blocked-back-preserves-page-before-any-callback")
      navigationAllowed=true
      button("Downloads fixture").performClick(nil);settle(window)
      try check(cancelled==1&&completions==[1]&&nextID.map(presenter.isShowing)==true&&landing==0,key+"-tab-navigation-cancels-once-without-intermediate-landing")
      presenter.canNavigate=nil
      presenter.dismiss(nextID!);settle(window)
      try check(!presenter.isPresenting&&host.subviews.allSatisfy{$0.identifier?.rawValue != "ready.page.surface"}&&landing==0,key+"-programmatic-dismiss-silent-and-nonblocking")
      var actionCalls=0,callbackPage:UUID?
      let primary=presenter.present(title:"Actions",message:"",content:nil,actions:[.init("Commit fixture",role:.primary)]){_ in
        actionCalls+=1;callbackPage=presenter.present(title:"Next callback page",message:"",content:nil,actions:[.init("Back fixture",role:.cancel)]){_ in}
      }
      settle(window);presenter.setActionEnabled(primary,index:0,enabled:false);presenter.activatePrimary(primary)
      try check(actionCalls==0&&presenter.isShowing(primary),key+"-disabled-primary-not-activated")
      presenter.setActionEnabled(primary,index:0,enabled:true);presenter.activatePrimary(primary);settle(window)
      try check(actionCalls==1&&callbackPage.map(presenter.isShowing)==true&&landing==0,key+"-completion-replacement-not-cancelled-again")
      presenter.cancelCurrent();settle(window);try check(!presenter.isPresenting&&landing==1,key+"-finish-needs-landing-only-without-replacement")
      var validationCalls=0,validationCancel=0
      let validationID=presenter.present(title:"Validate existing field",message:"",content:content,actions:[.init("Validate fixture",role:.primary),.init("Cancel validation",role:.cancel)],onCancel:{validationCancel+=1}){index in
        if index==0{validationCalls+=1;presenter.showNotice("Fix the existing input; keep this form.")}
      }
      settle(window);presenter.activatePrimary(validationID);settle(window)
      try check(presenter.isShowing(validationID)&&field.stringValue=="retained form input"&&validationCalls==1&&validationCancel==0&&landing==1,key+"-primary-validation-notice-keeps-form-and-input")
      window.makeFirstResponder(field);let activatedInPage=presenter.handleController(.activate);settle(window)
      try check(activatedInPage,key+"-controller-page-focus-never-falls-through-to-canvas")
      try check(validationCalls==2&&validationCancel==0&&presenter.isShowing(validationID),key+"-retained-validation-can-be-submitted-again")
      presenter.dismiss(validationID)
      var fromCallback=0,callbackCancel=0,callbackNext:UUID?
      let transitionID=presenter.present(title:"Callback navigation",message:"",content:nil,actions:[.init("Navigate fixture",role:.primary)],onCancel:{callbackCancel+=1}){_ in
        fromCallback+=1;presenter.cancelCurrent()
        callbackNext=presenter.present(title:"New route",message:"",content:nil,actions:[]){_ in}
      }
      settle(window);presenter.activatePrimary(transitionID);settle(window)
      try check(fromCallback==1&&callbackCancel==0&&callbackNext.map(presenter.isShowing)==true&&landing==1,key+"-callback-cancelThenPresent-never-calls-old-completion-twice")
      presenter.dismiss(callbackNext!)
      var dismissCalls=0,dismissID:UUID?
      dismissID=presenter.present(title:"Callback dismissal",message:"",content:nil,actions:[.init("Dismiss fixture",role:.primary)]){_ in
        dismissCalls+=1;presenter.dismiss(dismissID!)
      }
      settle(window);presenter.activatePrimary(dismissID!);settle(window)
      try check(dismissCalls==1 && !presenter.isPresenting && landing==1,key+"-callback-programmatic-dismiss-does-not-render-landing")
      var detachCalls=0
      let detachedID=presenter.present(title:"Callback session",message:"",content:nil,actions:[.init("Begin session fixture",role:.primary)],onCancel:{detachCalls+=100}){_ in
        detachCalls+=1;_=presenter.detachForSession()
      }
      settle(window);presenter.activatePrimary(detachedID);settle(window)
      try check(detachCalls==1 && !presenter.isPresenting && landing==1,key+"-callback-detach-does-not-reenter-cancel-or-landing")

      let account=SteamAccountView(frame:NSRect(x:0,y:0,width:660,height:710));var state=SteamClientState();account.update(state)
      var backCalls=0
      presenter.configureNavigation(title:"Account",tabs:[.init(id:"steam",title:"Steam fixture",action:{}),.init(id:"epic",title:"Epic fixture",action:{})],selected:"steam",onBack:{backCalls+=1})
      var accountCancel=0
      let accountID=presenter.present(title:"Steam account",message:"Private layout fixture only.",content:account,actions:[],onCancel:{accountCancel+=1}){_ in}
      settle(window)
      state.connection="authenticating";account.update(state);account.authenticationEvent(["type":"qr","url":"https://example.invalid/page-layout-only"])
      settle(window)
      let image=all(account).compactMap{$0 as?NSImageView}.first!,scroll=account.enclosingScrollView!,document=scroll.documentView!
      let qrRect=document.convert(image.bounds,from:image),viewport=scroll.documentVisibleRect
      try check(!image.isHiddenOrHasHiddenAncestor&&viewport.insetBy(dx:-1,dy:-1).contains(qrRect),key+"-dynamic-QR-auto-scroll-visible")
      try check(all(host).filter{$0.identifier?.rawValue=="ready.page.surface"}.count==1&&presenter.isShowing(accountID),key+"-QR-update-remains-same-page")
      let qrHeight=document.frame.height
      state.connection="online";state.displayName="Fixture public name";account.update(state);settle(window)
      try check(document.frame.height<qrHeight-200,key+"-online-shrinks-natural-document")
      let header=button("Epic fixture"),headerFrame=surface().convert(header.bounds,from:header)
      try check(headerFrame.minY>=0 && headerFrame.maxY<=surface().bounds.height && !header.isHiddenOrHasHiddenAncestor,key+"-tabs-stay-visible-above-scrolling-form")
      geometry.append(["windowWidth":size.width,"windowHeight":size.height,"pageWidth":surface().frame.width,"pageHeight":surface().frame.height,"viewportHeight":viewport.height,"QRVisible":true,"onlineDocumentHeight":document.frame.height])
      button("← Indietro").performClick(nil);settle(window)
      try check(backCalls==1 && accountCancel==1 && !presenter.isPresenting && landing==2,key+"-header-back-cancels-page-once")
      var silentCallbacks=0
      _=presenter.present(title:"Session detach",message:"Retain this notice",content:NSView(frame:NSRect(x:0,y:0,width:300,height:100)),actions:[.init("Cancel",role:.cancel)],onCancel:{silentCallbacks+=1}){_ in silentCallbacks+=1}
      let notices=presenter.detachForSession();settle(window)
      try check(notices==["Session detach: Retain this notice"] && silentCallbacks==0 && landing==2 && !presenter.isPresenting && host.subviews.allSatisfy{$0.identifier?.rawValue != "ready.page.surface"},key+"-session-detach-releases-hit-surface-without-callbacks")
      // A dismissed responsive view can no longer mutate a replacement page.
      let replacement=NSView(frame:NSRect(x:0,y:0,width:300,height:70))
      let replacementID=presenter.present(title:"Independent",message:"",content:replacement,actions:[]){_ in};settle(window)
      let currentScroll=replacement.enclosingScrollView!,before=currentScroll.documentView!.frame
      account.authenticationEvent(["type":"qr","url":"https://example.invalid/detached-page"]);settle(window)
      try check(currentScroll.documentView!.frame==before,key+"-stale-responsive-view-cannot-resize-new-page")
      for titles in [["Generali","Account","Motori","Dati e ripristino","Toolkit Apple"],["Libreria","Account e amici","Download"]] {
        presenter.configureNavigation(title:"Production title fixture",tabs:titles.map{.init(id:$0,title:$0,action:{})},selected:titles.first,onBack:{})
        settle(window)
        for title in titles {
          let tab=button(title),ink=(title as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:14,weight:.semibold)])
          try check(tab.bounds.width-20>=ceil(ink.width)&&tab.bounds.height>=ceil(ink.height),key+"-production-tab-text-fits-"+title)
        }
        try check(titles.allSatisfy{button($0).focusRingType == .none},key+"-navigation-no-native-focus-ring-"+titles[0])
      }
      let back=button("← Indietro"),backInk=(back.title as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:14,weight:.semibold)])
      try check(back.bounds.width-20>=ceil(backInk.width)&&back.focusRingType == .none,key+"-back-label-fits-without-double-focus-ring")
      presenter.dismiss(replacementID);window.close()
    }
    let report:[String:Any]=["passed":checks.values.allSatisfy{$0},"count":checks.count,"checks":checks,"geometry":geometry,"fixtureOnly":true,"realAccountUsed":false,"networkOrKeychainUsed":false,"windowsShown":false]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
    print(String(decoding:try JSONSerialization.data(withJSONObject:["passed":true,"count":checks.count],options:[.sortedKeys]),as:UTF8.self))
  }
}
