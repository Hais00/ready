// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CoreImage

// The test runner inserts the production main.swift auth methods verbatim into
// this file before compiling. Only store/network/browser/model edges are fake.
enum Store:String { case steam,epic,gog,amazon; var title:String{rawValue.capitalized} }
enum LauncherError:Error { case failed(String),invalid(String) }
enum ControllerNavigation {
  enum Direction:Equatable{case up,down,left,right}
  enum Action:Equatable{case cancel,activate,move(Direction)}
  static func handleModal(_ action:Action,window:NSWindow){}
}
final class MetalCanvas:NSView {
  enum Section { case library,utility,settings }
  var section:Section = .settings,interactionEnabled=true,message=""
  func refresh(){}
}
final class FixtureSession { var running=false }
final class FixtureStoreClient {
  struct Request { let id:UUID,operation:String;let callback:([String:Any])->Void;var terminal=false }
  var requests=[Request](),cancelled=[UUID]()
  func request(operation:String,store:Store,profile:UUID,options:[String:Any]=[:],event:@escaping([String:Any])->Void)->UUID {
    let id=UUID();requests.append(.init(id:id,operation:operation,callback:event));return id
  }
  func cancel(_ id:UUID){if let request=requests.first(where:{$0.id==id}),!request.terminal,!cancelled.contains(id){cancelled.append(id)}}
  func emit(_ id:UUID,_ event:[String:Any],delay:Double=0.03){
    DispatchQueue.main.asyncAfter(deadline:.now()+delay){[self]in
      guard let index=requests.firstIndex(where:{$0.id==id})else{return}
      if ["auth_url","result","error"].contains(event["type"]as?String ?? ""){requests[index].terminal=true}
      requests[index].callback(event) // Deliberately deliver even cancelled/stale events.
    }
  }
}
final class FixtureSteamAccounts {
  func cancel(_ id:UUID){}
  func authenticate(profile:UUID,event:@escaping([String:Any])->Void)->UUID{UUID()}
}
final class AppDelegate:NSObject {
  var window:NSWindow!,canvas:MetalCanvas!,session:FixtureSession?=FixtureSession()
  var authenticationSession:UUID?,authenticationRequest:UUID?,steamAuthenticationRequest:UUID?,qrDialog:UUID?
  var qrImage:NSImageView?
  var storeClient:FixtureStoreClient! = FixtureStoreClient()
  var steamAccounts:FixtureSteamAccounts! = FixtureSteamAccounts()
  var openedURLs=[URL](),synced=[Store](),errors=[Error](),landings=[Store?](),automaticLandingCount=0
  var navigating=false
  lazy var dialogs=ReadyDialogPresenter(window:{[weak self]in self?.window})
  lazy var pages:ReadyPagePresenter = {
    let result=ReadyPagePresenter(window:{[weak self]in self?.window},host:{[weak self]in self?.canvas})
    result.onNeedsLanding={[weak self]in
      guard let self,!self.navigating,!self.pages.isPresenting else{return}
      self.automaticLandingCount+=1
      // Reproduce Root's settings landing, which cancels a stranded auth flight.
      self.beginPage(.settings)
      _=self.presentDialog(title:"Settings landing",message:"",actions:[]){_ in}
    }
    return result
  }()
  override init(){
    super.init()
    window=NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:1000,height:700),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;canvas=MetalCanvas(frame:NSRect(x:0,y:0,width:1000,height:700));window.contentView=canvas
  }
  func beginPage(_ section:MetalCanvas.Section){
    navigating=true;pages.cancelCurrent();if authenticationSession != nil{cancelAuthentication()};navigating=false
    canvas.section=section
    pages.configureNavigation(title:"Settings",tabs:[],selected:nil,onBack:{[weak self]in self?.navigateToLibrary()})
  }
  func navigateToLibrary(store:Store?=nil){
    navigating=true;pages.cancelCurrent();_=pages.detachForSession();cancelAuthentication();navigating=false
    canvas.section = .library;landings.append(store)
  }
  func showSteamAccount(){}
  func syncStore(_ store:Store,profile:UUID){synced.append(store)}
  func showError(_ error:Error){
    errors.append(error)
    if pages.isPresenting{pages.showNotice("Controlled fixture validation error");return}
    _=presentDialog(title:"Controlled error",message:"",actions:[.init("Close",role:.cancel)]){_ in}
  }
  func setPresentationActionEnabled(_ id:UUID,index:Int,enabled:Bool){pages.setActionEnabled(id,index:index,enabled:enabled)}
  func activatePresentationPrimary(_ id:UUID){pages.activatePrimary(id)}
  // PRODUCTION_AUTH_METHODS
  func fixtureStart(_ store:Store,profile:UUID)->UUID {
    beginPage(.settings)
    let page=presentDialog(title:"Accounts",message:"",actions:[.init("Start fixture login",role:.primary)]){[weak self]choice in
      guard let self,choice==0 else{return}
      self.beginStoreConnection(store,profile:profile,synchronize:false,openAuthorizationURL:{[weak self]url in self?.openedURLs.append(url)})
    }
    return page
  }
  func fixtureStaleCancellation(_ id:UUID){cancelStoreAuthentication(id)}
}
private enum FixtureFailure:Error { case check(String),deadline }
private func all(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(all)}
@main struct ReadyStoreAuthenticationPagesProbe {
  @MainActor static func main()throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let app=AppDelegate(),profile=UUID();var checks=[String:Bool]()
    func check(_ condition:Bool,_ name:String)throws{if !condition{throw FixtureFailure.check(name)};checks[name]=true}
    func spin(_ condition:()->Bool)throws {
      let deadline=Date().addingTimeInterval(3)
      while !condition(),Date()<deadline{app.window.contentView?.layoutSubtreeIfNeeded();RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
      if !condition(){throw FixtureFailure.deadline}
    }
    func settle(){for _ in 0..<8{app.window.contentView?.layoutSubtreeIfNeeded();RunLoop.current.run(until:Date().addingTimeInterval(0.01))}}
    func start(_ store:Store)throws->UUID {
      let id=app.fixtureStart(store,profile:profile);app.pages.activatePrimary(id);settle()
      guard let request=app.authenticationRequest else{throw FixtureFailure.check("begin-request-present")};return request
    }
    func button(_ title:String)throws->NSButton {
      guard let button=all(app.canvas).compactMap({$0 as?NSButton}).first(where:{$0.title==title})else{throw FixtureFailure.check("button-present")};return button
    }
    let begin=try start(.epic),authentication=app.authenticationSession!,progress=app.qrDialog!
    let oldCancel=try button("Annulla accesso")
    try check(app.pages.isShowing(progress)&&app.storeClient.cancelled.isEmpty&&app.automaticLandingCount==0,"delayed-auth-begin-retains-progress-without-landing-or-cancellation")
    app.storeClient.emit(begin,["type":"auth_url","url":"https://example.invalid/fixture-auth","authState":["fixture":true]])
    try spin{app.openedURLs.count==1&&app.qrDialog != progress}
    try check(app.authenticationSession==authentication&&app.storeClient.cancelled.isEmpty,"progress-to-browser-input-is-silent-internal-transition")
    let input=all(app.canvas).compactMap{$0 as?NSSecureTextField}.first!
    let inputPage=app.qrDialog!
    try button("Collega").performClick(nil);settle()
    try check(app.pages.isShowing(inputPage)&&app.authenticationSession==authentication&&app.storeClient.requests.count==1,"empty-input-retains-form-and-auth-flight")
    input.stringValue="fixture_private_callback_code"
    try button("Collega").performClick(nil);settle()
    let complete=app.authenticationRequest!
    try check(app.storeClient.requests.last?.operation=="auth_complete"&&complete != begin&&app.qrDialog != inputPage&&app.pages.isPresenting&&input.stringValue.isEmpty,"delayed-auth-complete-retains-progress-and-clears-submitted-field")
    oldCancel.performClick(nil);app.fixtureStaleCancellation(UUID());settle()
    try check(app.authenticationSession==authentication&&app.storeClient.cancelled.isEmpty,"detached-old-button-and-foreign-UUID-cannot-cancel-current-flight")
    app.storeClient.emit(complete,["type":"result"]);try spin{app.synced==[.epic]}
    try check(app.canvas.section == .library&&app.landings.last! == .epic&&app.authenticationSession==nil&&app.qrDialog==nil && !app.pages.isPresenting,"successful-completion-explicitly-lands-in-target-store-library-once")

    let qrBegin=try start(.gog),qrAuthentication=app.authenticationSession!,qrProgress=app.qrDialog!
    app.storeClient.emit(qrBegin,["type":"qr","url":"https://example.invalid/fixture-qr"])
    try spin{app.qrImage != nil}
    let image=app.qrImage!,qrPage=app.qrDialog!
    try check(qrPage != qrProgress&&app.authenticationSession==qrAuthentication&&app.storeClient.cancelled.isEmpty,"progress-to-QR-does-not-cancel-authentication")
    app.storeClient.emit(qrBegin,["type":"qr","url":"https://example.invalid/rotated-qr"]);settle()
    try check(app.qrImage===image&&app.qrDialog==qrPage&&app.pages.isShowing(qrPage),"QR-rotation-updates-same-page")
    app.storeClient.emit(qrBegin,["type":"result"]);try spin{app.synced==[.epic,.gog]}

    let cancelledBegin=try start(.amazon),cancelledAuthentication=app.authenticationSession!
    app.navigateToLibrary();let urls=app.openedURLs.count,syncs=app.synced.count
    try check(app.storeClient.cancelled==[cancelledBegin]&&app.authenticationSession==nil,"explicit-navigation-cancels-delayed-begin-once")
    let replacement=try start(.epic),replacementAuthentication=app.authenticationSession!,replacementPage=app.qrDialog!
    app.fixtureStaleCancellation(cancelledAuthentication)
    app.storeClient.emit(cancelledBegin,["type":"auth_url","url":"https://example.invalid/stale","authState":[:]])
    app.storeClient.emit(cancelledBegin,["type":"result"]);settle()
    try check(app.authenticationSession==replacementAuthentication&&app.pages.isShowing(replacementPage)&&app.openedURLs.count==urls&&app.synced.count==syncs,"cancelled-flight-late-events-and-old-UUID-do-not-replace-new-page")
    app.storeClient.emit(replacement,["type":"auth_url","url":"https://example.invalid/second","authState":[:]])
    try spin{app.openedURLs.count==urls+1}
    all(app.canvas).compactMap{$0 as?NSSecureTextField}.first!.stringValue="fixture_second_code"
    try button("Collega").performClick(nil);let cancelledComplete=app.authenticationRequest!
    app.navigateToLibrary();app.storeClient.emit(cancelledComplete,["type":"result"]);settle()
    try check(app.storeClient.cancelled.contains(cancelledComplete)&&app.synced.count==syncs&&app.authenticationSession==nil && !app.pages.isPresenting,"explicit-navigation-cancels-delayed-complete-and-drops-late-success")
    let errorBegin=try start(.amazon)
    app.storeClient.emit(errorBegin,["type":"error","message":"Controlled fixture failure"]);try spin{!app.errors.isEmpty&&app.authenticationSession==nil}
    try check(app.qrDialog==nil&&app.pages.isPresenting,"terminal-error-replaces-progress-with-visible-error-page")
    // Secure field editors/CoreImage may allocate hidden AppKit helper windows.
    // The fixture never orders any window on screen, including those helpers.
    try check(NSApplication.shared.windows.allSatisfy{!$0.isVisible},"offscreen-system-helper-windows-remain-hidden")
    try check(app.window.isVisible==false,"offscreen-fixture-never-shows-window")
    try check(app.openedURLs.allSatisfy{$0.host=="example.invalid"},"authorization-URL-opener-is-injected-and-never-launches-browser")
    let report:[String:Any]=["passed":checks.values.allSatisfy{$0},"count":checks.count,"checks":checks,"fixtureOnly":true,"realAccountUsed":false,"networkOrKeychainUsed":false,"browserOpened":false,"windowsShown":false]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
    print(String(decoding:try JSONSerialization.data(withJSONObject:["passed":true,"count":checks.count]),as:UTF8.self))
    app.window.close()
  }
}
