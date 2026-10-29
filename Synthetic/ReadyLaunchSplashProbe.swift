// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import LauncherCore
import QuartzCore
import SplashAnimationObserver

private final class SplashArtworkProtocol:URLProtocol {
  static let lock=NSLock()
  static var banner=Data(),icon=Data(),calls=[String:Int](),cancelled=0
  private var ended=false
  override class func canInit(with request:URLRequest)->Bool{request.url?.scheme=="https"}
  override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
  override func startLoading(){
    let path=request.url!.path;Self.lock.lock();Self.calls[path,default:0]+=1;Self.lock.unlock()
    DispatchQueue.global().asyncAfter(deadline:.now()+(path.contains("slow") ? 0.3:0.02)){[self]in
      Self.lock.lock();guard !ended else{Self.lock.unlock();return};ended=true;Self.lock.unlock()
      let code=path.contains("missing") ? 404:200
      client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:code,httpVersion:nil,headerFields:["Content-Type":"image/png"])!,cacheStoragePolicy:.notAllowed)
      client?.urlProtocol(self,didLoad:path.contains("icon") ? Self.icon:Self.banner);client?.urlProtocolDidFinishLoading(self)
    }
  }
  override func stopLoading(){Self.lock.lock();if !ended{ended=true;Self.cancelled+=1};Self.lock.unlock()}
  static func requestCount()->Int{lock.lock();defer{lock.unlock()};return calls.values.reduce(0,+)}
}
private final class HiddenSplashWindow:NSWindow {
  override func constrainFrameRect(_ frameRect:NSRect,to screen:NSScreen?)->NSRect{frameRect}
  override func makeKeyAndOrderFront(_ sender:Any?){}
  override func orderFront(_ sender:Any?){}
  override func orderBack(_ sender:Any?){}
}
@main struct ReadyLaunchSplashProbe {
  static func pump(_ duration:TimeInterval=0.035){let end=Date().addingTimeInterval(duration);while Date()<end{RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.002))}}
  static func makePNG(width:Int,height:Int)->Data{
    let space=CGColorSpaceCreateDeviceRGB(),context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor(srgbRed:0.05,green:0.2,blue:0.22,alpha:1).cgColor);context.fill(CGRect(x:0,y:0,width:width,height:height))
    context.setFillColor(NSColor(srgbRed:0.25,green:0.65,blue:0.45,alpha:1).cgColor);context.fillEllipse(in:CGRect(x:width/3,y:height/4,width:height/2,height:height/2))
    return NSBitmapImageRep(cgImage:context.makeImage()!).representation(using:.png,properties:[:])!
  }
  static func labels(_ view:NSView)->[NSTextField]{view.subviews.compactMap{$0 as?NSTextField}}
  static func buttons(_ view:NSView)->[NSButton]{view.subviews.compactMap{$0 as?NSButton}}
  static func picture(_ view:GameLaunchSplash)->CALayer{view.layer!.sublayers!.first!}
  static func spinner(_ view:GameLaunchSplash)->CAShapeLayer{view.layer!.sublayers!.compactMap{$0 as?CAShapeLayer}.first!}
  static func main()throws{
    _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    guard CommandLine.arguments.count==2 else{exit(64)}
    let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
    SplashArtworkProtocol.banner=makePNG(width:1600,height:600);SplashArtworkProtocol.icon=makePNG(width:96,height:96)
    let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[SplashArtworkProtocol.self];let session=URLSession(configuration:configuration)
    defer{session.invalidateAndCancel()}
    func cache(_ name:String)->ArtworkCache{ArtworkCache(directory:root.appendingPathComponent(name,isDirectory:true),session:session,maximumPixelSize:2048)}
    func game(_ id:String,hero:String?=nil,icon:String?=nil)->Game{
      var game=Game(id:id,store:.local,storeID:id,title:"Gioco sintetico · anteprima di caricamento")
      var metadata=[String:JSONValue]();if let hero{metadata["heroURL"] = .string(hero)};if let icon{metadata["iconURL"] = .string(icon)};game.metadata=metadata;return game
    }
    ReadySplashAnimationObserverStart();defer{ReadySplashAnimationObserverStop()}
    var checks=[String:Bool]()
    func animationFacts(_ value:CABasicAnimation?)->[String:Any]{
      guard let value else{return ["available":false]}
      return ["available":true,"keyPath":value.keyPath ?? "","duration":value.duration,"autoreverses":value.autoreverses,"repeatIsInfinite":value.repeatCount.isInfinite,"repeatCount":value.repeatCount.isFinite ? Double(value.repeatCount):NSNull()]
    }
    func check(_ name:String,_ value:Bool){checks[name]=value}
    let window=HiddenSplashWindow(contentRect:NSRect(x:-8192,y:-8192,width:900,height:620),styleMask:[.borderless],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;defer{window.close()}
    let container=NSView(frame:NSRect(x:0,y:0,width:900,height:620));window.contentView=container
    let empty=GameLaunchSplash(game:game("empty"),artwork:cache("empty-cache"));empty.frame=NSRect(x:0,y:0,width:900,height:620)
    check("detached-splash-does-not-start-indicator-animations",ReadySplashAdditionCount(spinner(empty),"loading.rotation")==0)
    container.addSubview(empty);empty.layoutSubtreeIfNeeded();pump()
    check("attach-starts-indicator-animations",ReadySplashAdditionCount(spinner(empty),"loading.rotation")>=1)
    let loading=labels(empty).first{$0.stringValue=="Caricamento"}!
    check("loading-label-is-exactly-Caricamento",loading.stringValue=="Caricamento" && !loading.isHidden)
    check("missing-artwork-has-proportional-placeholder",empty.subviews.compactMap{$0 as?NSImageView}.contains{!$0.isHidden && $0.image != nil && $0.imageScaling == .scaleProportionallyUpOrDown})
    let rotation=ReadySplashRecordedAnimation(spinner(empty),"loading.rotation") as?CABasicAnimation,pulse=loading.layer.flatMap{ReadySplashRecordedAnimation($0,"loading.pulse") as?CABasicAnimation}
    check("spinner-configures-continuous-full-rotation",rotation?.keyPath=="transform.rotation.z" && rotation?.repeatCount.isInfinite==true && rotation?.duration==1)
    check("loading-configures-continuous-autoreverse-pulse",pulse?.keyPath=="opacity" && pulse?.repeatCount.isInfinite==true && pulse?.autoreverses==true && (pulse?.duration ?? 0)>0)
    let p1=spinner(empty).presentation()?.value(forKeyPath:"transform.rotation.z") as?NSNumber;pump(0.1)
    let p2=spinner(empty).presentation()?.value(forKeyPath:"transform.rotation.z") as?NSNumber
    let presentationAvailable=p1 != nil && p2 != nil,presentationChanged=presentationAvailable && abs(p1!.doubleValue-p2!.doubleValue)>0.001
    var retries=0,cancels=0;empty.onRetry={retries+=1};empty.onCancel={cancels+=1}
    empty.showError("Errore sintetico "+String(repeating:"x",count:1000));empty.layoutSubtreeIfNeeded()
    check("errors-are-inline-with-retry-and-back",buttons(empty).contains{$0.title=="Riprova" && !$0.isHidden} && buttons(empty).contains{$0.title=="Indietro" && !$0.isHidden} && labels(empty).contains{!$0.isHidden && $0.stringValue.hasPrefix("Errore sintetico")})
    check("error-text-is-bounded",labels(empty).first{$0.stringValue.hasPrefix("Errore sintetico")}?.stringValue.count==800)
    check("error-hides-loading-indicators",spinner(empty).isHidden && loading.isHidden)
    buttons(empty).first{$0.title=="Riprova"}?.performClick(nil);buttons(empty).first{$0.title=="Indietro"}?.performClick(nil)
    check("buttons-invoke-only-owned-callbacks",retries==1 && cancels==1)
    func key(_ code:UInt16){let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!;empty.keyDown(with:event)}
    key(53);key(36);check("escape-and-error-return-have-explicit-actions",retries==2 && cancels==2)
    let errorRotations=ReadySplashAdditionCount(spinner(empty),"loading.rotation"),errorPulses=loading.layer.map{ReadySplashAdditionCount($0,"loading.pulse")} ?? 0
    empty.removeFromSuperview();container.addSubview(empty);pump()
    check("error-state-survives-detach-and-reattach-without-loading-restart",ReadySplashAdditionCount(spinner(empty),"loading.rotation")==errorRotations && loading.layer.map{ReadySplashAdditionCount($0,"loading.pulse")}==errorPulses && loading.isHidden && spinner(empty).isHidden)
    empty.finish();empty.finish()
    check("finish-is-idempotent-and-clears-indicator-animations",ReadySplashRemovalCount(spinner(empty))>=1 && loading.layer.map{ReadySplashRemovalCount($0)>=1}==true && (spinner(empty).animationKeys() ?? []).isEmpty && (loading.layer?.animationKeys() ?? []).isEmpty)
    let heroGame=game("hero",hero:"https://splash.ready.invalid/hero.png"),hero=GameLaunchSplash(game:heroGame,artwork:cache("hero-cache"))
    let until=Date().addingTimeInterval(3);while picture(hero).contents==nil && Date()<until{pump()}
    check("banner-arrives-through-controlled-artwork-cache",picture(hero).contents != nil)
    check("artwork-arriving-before-attachment-does-not-start-motion",ReadySplashAdditionCount(picture(hero),"artwork.motion")==0)
    hero.frame=container.bounds;container.addSubview(hero);hero.layoutSubtreeIfNeeded();pump()
    check("banner-preserves-aspect-with-cover-gravity",picture(hero).contentsGravity == .resizeAspectFill)
    let motion=ReadySplashRecordedAnimation(picture(hero),"artwork.motion") as?CABasicAnimation
    check("banner-configures-continuous-panzoom",motion?.keyPath=="transform" && motion?.repeatCount.isInfinite==true && motion?.autoreverses==true && motion?.duration==18)
    for size in [NSSize(width:620,height:620),NSSize(width:900,height:620),NSSize(width:1920,height:1080)]{
      window.setContentSize(size);container.frame=NSRect(origin:.zero,size:size);hero.frame=NSRect(origin:.zero,size:size);hero.needsLayout=true;hero.layoutSubtreeIfNeeded();pump()
      check("responsive-\(Int(size.width))-\(Int(size.height))-controls-inside-surface",hero.subviews.allSatisfy{$0.isHidden || ($0.frame.minX>=0 && $0.frame.minY>=0 && $0.frame.maxX<=size.width && $0.frame.maxY<=size.height && $0.frame.height>0)})
      check("responsive-\(Int(size.width))-\(Int(size.height))-banner-covers-surface",picture(hero).frame==hero.bounds)
      if let bitmap=hero.bitmapImageRepForCachingDisplay(in:hero.bounds){hero.cacheDisplay(in:hero.bounds,to:bitmap);if let png=bitmap.representation(using:.png,properties:[:]){try png.write(to:root.appendingPathComponent("loading-\(Int(size.width))-\(Int(size.height)).png"))}}
    }
    let healthyRotations=ReadySplashAdditionCount(spinner(hero),"loading.rotation"),healthyMotion=ReadySplashAdditionCount(picture(hero),"artwork.motion")
    let removals=ReadySplashRemovalCount(spinner(hero));hero.removeFromSuperview()
    check("detaching-healthy-splash-stops-animations",ReadySplashRemovalCount(spinner(hero))>removals)
    container.addSubview(hero);pump()
    check("reattach-restarts-healthy-spinner-and-banner",ReadySplashAdditionCount(spinner(hero),"loading.rotation")==healthyRotations+1 && ReadySplashAdditionCount(picture(hero),"artwork.motion")==healthyMotion+1)
    let previousTitle=labels(hero).first{$0.stringValue==heroGame.title}?.stringValue;hero.update(game:game("different",hero:"https://splash.ready.invalid/unrelated.png"));pump()
    check("different-game-update-is-ignored",labels(hero).contains{$0.stringValue==previousTitle} && SplashArtworkProtocol.calls["/unrelated.png"]==nil)
    hero.finish();check("finish-detaches-and-clears-artwork-animation-and-contents",hero.superview==nil && picture(hero).contents==nil && ReadySplashRemovalCount(picture(hero))>=1 && (picture(hero).animationKeys() ?? []).isEmpty)
    let finishedRotations=ReadySplashAdditionCount(spinner(hero),"loading.rotation");container.addSubview(hero);pump()
    check("finished-splash-does-not-restart-on-reattach",ReadySplashAdditionCount(spinner(hero),"loading.rotation")==finishedRotations && picture(hero).contents==nil);hero.removeFromSuperview()
    let fallback=GameLaunchSplash(game:game("fallback",hero:"https://splash.ready.invalid/missing.png",icon:"https://splash.ready.invalid/icon.png"),artwork:cache("fallback-cache"));fallback.frame=NSRect(x:0,y:0,width:900,height:620)
    let fallbackDeadline=Date().addingTimeInterval(3);while picture(fallback).contents==nil && Date()<fallbackDeadline{pump()};fallback.layoutSubtreeIfNeeded()
    check("failed-banner-falls-back-to-icon",picture(fallback).contents != nil && picture(fallback).contentsGravity == .resizeAspect)
    check("icon-has-no-cover-panzoom-or-stretch",ReadySplashAdditionCount(picture(fallback),"artwork.motion")==0 && picture(fallback).frame.width==picture(fallback).frame.height)
    fallback.finish()
    let slow=GameLaunchSplash(game:game("slow",hero:"https://splash.ready.invalid/slow.png"),artwork:cache("slow-cache"));pump(0.03);slow.finish();pump(0.4)
    check("finish-cancels-pending-cache-tasks",SplashArtworkProtocol.cancelled>0)
    check("late-artwork-cannot-repopulate-finished-splash",picture(slow).contents==nil && (picture(slow).animationKeys() ?? []).isEmpty)
    let calls=SplashArtworkProtocol.requestCount();slow.update(game:game("slow",hero:"https://splash.ready.invalid/new.png"));pump()
    check("finished-splash-does-not-start-new-requests",SplashArtworkProtocol.requestCount()==calls)
    check("own-hidden-window-never-activates",!NSApp.isActive && !window.isKeyWindow && !window.isVisible)
    let result:[String:Any]=["passed":checks.values.allSatisfy{$0},"count":checks.count,"checks":checks,"animationFacts":["rotation":animationFacts(rotation),"pulse":animationFacts(pulse),"banner":animationFacts(motion)],"fixtureOnly":true,"ownHiddenWindowCreated":true,"windowActivated":NSApp.isActive || window.isKeyWindow,"externalNetworkUsed":false,"accountsKeychainGamesOrBenchmarkUsed":false,"CoreAnimationConfigurationVerified":true,"presentationLayerAvailable":presentationAvailable,"presentationLayerChangeObserved":presentationChanged,"continuousOnScreenAnimationVerified":false,"previewRoot":root.path]
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys,.prettyPrinted]));if !checks.values.allSatisfy({$0}){exit(1)}
  }
}
