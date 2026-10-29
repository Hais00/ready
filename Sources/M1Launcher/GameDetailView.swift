// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import LauncherCore

private func detailColor(_ hex:Int)->NSColor{NSColor(srgbRed:CGFloat((hex>>16)&255)/255,green:CGFloat((hex>>8)&255)/255,blue:CGFloat(hex&255)/255,alpha:1)}
private final class GameDetailButton:NSButton {
  var invoke:(()->Void)?
  var primary=false
  private var hover=false
  init(_ title:String,primary:Bool=false,invoke:@escaping()->Void){super.init(frame:.zero);self.title=title;self.primary=primary;self.invoke=invoke;target=self;action=#selector(clicked);isBordered=false;focusRingType = .none;setButtonType(.momentaryPushIn)}
  required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
  @objc private func clicked(){invoke?()}
  override func updateTrackingAreas(){trackingAreas.forEach(removeTrackingArea);addTrackingArea(NSTrackingArea(rect:bounds,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil));super.updateTrackingAreas()}
  override func mouseEntered(with event:NSEvent){hover=true;needsDisplay=true}
  override func mouseExited(with event:NSEvent){hover=false;needsDisplay=true}
  override func resetCursorRects(){super.resetCursorRects();if isEnabled{addCursorRect(bounds,cursor:.pointingHand)}}
  override func draw(_ dirtyRect:NSRect){
    let fill=primary ? (isHighlighted ? 0x75cba2:hover ? 0xc5ffdd:0x9ce9bd):(isHighlighted ? 0x405651:hover ? 0x35494b:0x263539)
    detailColor(fill).withAlphaComponent(isEnabled ? 1:0.45).setFill();let path=NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:9,yRadius:9);path.fill()
    if window?.firstResponder===self{detailColor(0xd2ffe6).setStroke();path.lineWidth=2;path.stroke()}
    let font=NSFont.systemFont(ofSize:14,weight:.semibold),paragraph=NSMutableParagraphStyle();paragraph.alignment = .center;paragraph.lineBreakMode = .byTruncatingTail
    let text=NSAttributedString(string:title,attributes:[.font:font,.foregroundColor:(primary ? detailColor(0x112d22):.white).withAlphaComponent(isEnabled ? 1:0.5),.paragraphStyle:paragraph])
    text.draw(in:NSRect(x:12,y:(bounds.height-text.size().height)/2,width:bounds.width-24,height:text.size().height))
  }
}
private final class GameHeroView:NSView {
  var image:CGImage?{didSet{needsDisplay=true}}
  var fallback=""
  var role:GameArtwork.Role = .banner
  override var isFlipped:Bool{true}
  override func draw(_ dirtyRect:NSRect){
    detailColor(0x203738).setFill();NSBezierPath(roundedRect:bounds,xRadius:12,yRadius:12).fill()
    guard let context=NSGraphicsContext.current?.cgContext else{return}
    context.saveGState();context.addPath(CGPath(roundedRect:bounds,cornerWidth:12,cornerHeight:12,transform:nil));context.clip()
    if let image{
      context.translateBy(x:0,y:bounds.height);context.scaleBy(x:1,y:-1)
      context.draw(image,in:GameArtwork.imageRect(imageSize:CGSize(width:image.width,height:image.height),in:bounds,role:role))
    }else{
      let title=NSAttributedString(string:fallback,attributes:[.font:NSFont.systemFont(ofSize:32,weight:.bold),.foregroundColor:detailColor(0x8bb8aa)])
      title.draw(in:bounds.insetBy(dx:25,dy:25))
    }
    context.restoreGState()
  }
}

@MainActor final class GameDetailView:NSView,ReadyDialogContentSizing {
  nonisolated var maximumViewportHeight:CGFloat{900}
  var onPlay:((GameVariant)->Void)?
  var onInstall:((GameVariant)->Void)?
  var onOptions:(()->Void)?
  var onDownloadControl:((String,String)->Void)?
  var onDetach:(()->Void)?
  private let artwork:ArtworkCache
  let profile:UUID
  private var game:Game
  private var jobs=[SteamDownloadJob]()
  private var selectedID:String?
  private var userSelectedID:String?
  private var transferStatus:String?,transferVariantID:String?,transferFraction:Double?
  private let hero=GameHeroView(),titleLabel=NSTextField(wrappingLabelWithString:""),summary=NSTextField(wrappingLabelWithString:"")
  private let versionLabel=NSTextField(labelWithString:"Versione"),picker=NSPopUpButton(frame:.zero,pullsDown:false)
  private let status=NSTextField(wrappingLabelWithString:""),progress=NSProgressIndicator()
  private let aboutHeading=NSTextField(labelWithString:"Informazioni sul gioco"),about=NSTextField(wrappingLabelWithString:""),facts=NSTextField(wrappingLabelWithString:"")
  private var play:GameDetailButton!,options:GameDetailButton!,control:GameDetailButton!
  private var observer:NSObjectProtocol?,hadWindow=false,layoutQueued=false
  private var lastWidth:CGFloat = -1
  private var presentedVariants:[GameVariant]{
    game.variants.filter{variant in
      if variant.id==game.selectedVariant || variant.id==userSelectedID{return true}
      let placeholder=variant.id==variant.platform.rawValue && !variant.installed && variant.architecture == .unknown
        && variant.executable==nil && variant.workingDirectory==nil && variant.installationRoot==nil && variant.arguments.isEmpty
      guard placeholder else{return true}
      return !game.variants.contains{other in other.id != variant.id && other.platform==variant.platform
        && (other.installed || other.architecture != .unknown || (other.executable.map{!$0.isEmpty} ?? false))}
    }
  }
  var selectedVariant:GameVariant?{
    let choices=presentedVariants
    return choices.first{$0.id==selectedID} ?? choices.first{$0.id==game.currentVariant?.id} ?? choices.first
  }
  var artworkSnapshot:(role:GameArtwork.Role,hasImage:Bool){(hero.role,hero.image != nil)}
  var detailSnapshot:(gameID:String,variantID:String?,primaryTitle:String,primaryEnabled:Bool,contentHeight:CGFloat){(game.id,selectedVariant?.id,play.title,play.isEnabled,frame.height)}
  override var isFlipped:Bool{true}
  override var isOpaque:Bool{true}
  override func draw(_ dirtyRect:NSRect){detailColor(0x111a1e).setFill();dirtyRect.fill()}
  init(game:Game,artwork:ArtworkCache,profile:UUID){
    self.game=game;self.artwork=artwork;self.profile=profile;selectedID=game.currentVariant?.id
    super.init(frame:NSRect(x:0,y:0,width:800,height:600))
    appearance=NSAppearance(named:.darkAqua)
    titleLabel.font = .systemFont(ofSize:28,weight:.bold);titleLabel.textColor = .white
    summary.font = .systemFont(ofSize:14);summary.textColor=detailColor(0xc2d1cf)
    versionLabel.font = .systemFont(ofSize:12,weight:.semibold);versionLabel.textColor=detailColor(0x9db7ad)
    status.font = .systemFont(ofSize:12);status.textColor=detailColor(0xb5cdca)
    aboutHeading.font = .systemFont(ofSize:20,weight:.semibold);aboutHeading.textColor = .white
    about.font = .systemFont(ofSize:14);about.textColor=detailColor(0xc9d3d3);about.isSelectable=true
    facts.font = .systemFont(ofSize:12);facts.textColor=detailColor(0x9fb9af);facts.isSelectable=true
    picker.target=self;picker.action=#selector(versionChanged);picker.font = .systemFont(ofSize:13)
    progress.style = .bar;progress.minValue=0;progress.maxValue=1
    play=GameDetailButton("Installa",primary:true){[weak self]in self?.activatePrimary()}
    options=GameDetailButton("Opzioni"){[weak self]in self?.onOptions?()}
    control=GameDetailButton("Metti in pausa"){[weak self]in self?.controlDownload()}
    for view:NSView in [hero,titleLabel,summary,versionLabel,picker,play,options,status,progress,control,aboutHeading,about,facts]{addSubview(view)}
    observer=NotificationCenter.default.addObserver(forName:.readyArtworkChanged,object:artwork,queue:.main){[weak self]note in MainActor.assumeIsolated{guard let self,note.userInfo?["gameID"]as?String==self.game.id else{return};self.updateHero()}}
    render()
  }
  required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
  deinit{if let observer{NotificationCenter.default.removeObserver(observer)}}
  override func viewDidMoveToWindow(){super.viewDidMoveToWindow();if window != nil{hadWindow=true}else if hadWindow{hadWindow=false;onDetach?()}}
  func update(game:Game,jobs:[SteamDownloadJob]){
    self.game=game;self.jobs=jobs
    if !game.variants.contains(where:{$0.id==userSelectedID}){userSelectedID=nil}
    if !game.variants.contains(where:{$0.id==selectedID}){selectedID=game.currentVariant?.id}
    render()
  }
  func setTransferStatus(_ message:String?,fraction:Double?=nil){
    transferStatus=message.map{String($0.prefix(1000))};transferVariantID=selectedVariant?.id
    transferFraction=fraction.flatMap{$0.isFinite && (0...1).contains($0) ? $0:nil};render()
  }
  private var currentJob:SteamDownloadJob? {
    guard let variant=selectedVariant else{return nil}
    return jobs.filter{$0.gameID==game.storeID && $0.platform==variant.platform.rawValue && !["completed","cancelled"].contains($0.state)}.max{$0.sequence<$1.sequence}
  }
  @objc private func versionChanged(){selectedID=picker.selectedItem?.representedObject as?String;userSelectedID=selectedID;render()}
  private func activatePrimary(){
    guard let variant=selectedVariant else{return}
    if variant.installed{onPlay?(variant)}
    else if let job=currentJob,["paused","interrupted","failed","retry_wait"].contains(job.state){onDownloadControl?(job.id,["failed","retry_wait"].contains(job.state) ? "retry":"resume")}
    else if currentJob==nil{onInstall?(variant)}
  }
  private func controlDownload(){
    guard let job=currentJob else{return}
    onDownloadControl?(job.id,["paused","interrupted","failed","retry_wait"].contains(job.state) ? (["failed","retry_wait"].contains(job.state) ? "retry":"resume"):"pause")
  }
  private func value(_ key:String)->String?{(game.metadata?[key]?.foundation as?String).flatMap{$0.isEmpty ? nil:$0}}
  private func values(_ key:String)->String?{(game.metadata?[key]?.foundation as?[String]).flatMap{$0.isEmpty ? nil:$0.joined(separator:", ")}}
  private static func plain(_ text:String)->String {
    var result=String(text.prefix(24000)).replacingOccurrences(of:"(?i)<(?:br\\s*/?|/p|/div)>",with:"\n",options:.regularExpression)
    result=result.replacingOccurrences(of:"<[^>]*>",with:"",options:.regularExpression)
    for (a,b) in [("&amp;","&"),("&quot;","\""),("&#39;","’"),("&lt;","<"),("&gt;",">"),("&nbsp;"," ")]{result=result.replacingOccurrences(of:a,with:b)}
    return result.trimmingCharacters(in:.whitespacesAndNewlines)
  }
  private func updateHero(){
    let refresh:()->Void={ [weak self] in MainActor.assumeIsolated{if let self{self.updateHero()}} }
    if let image=artwork.image(for:game,role:.banner,refresh:refresh){hero.role = .banner;hero.image=image}
    else if !artwork.hasCachedImage(gameID:game.id,role:.banner){hero.role = .icon;hero.image=artwork.image(for:game,role:.icon,refresh:refresh)}
  }
  private func render(){
    titleLabel.stringValue=LibraryEntryPresentation.title(game);hero.fallback=LibraryEntryPresentation.title(game);updateHero()
    summary.stringValue=Self.plain(value("shortDescription") ?? game.store.title+" · "+MetalCanvas.platformLabels(game).joined(separator:" / "))
    about.stringValue=[value("description"),value("shortDescription")].compactMap{$0}.map(Self.plain).first(where:{!$0.isEmpty}) ?? LibraryEntryPresentation.unavailableDescription(game)
    var details=[String]()
    if let text=values("developers"){details.append("SVILUPPATORE   "+text)}
    if let text=values("publishers"){details.append("EDITORE   "+text)}
    if let text=values("genres"){details.append("GENERI   "+text)}
    if let text=value("releaseDate"){details.append("USCITA   "+text)}
    details.append("LIBRERIA   "+game.store.title);facts.stringValue=details.joined(separator:"\n\n")
    let choices=presentedVariants
    if !choices.contains(where:{$0.id==selectedID}){selectedID=selectedVariant?.id}
    picker.removeAllItems()
    for variant in choices{
      let name=variant.platform == .windows ? "Windows":(variant.installed && (variant.architecture == .arm64 || variant.architecture == .universal) ? "macOS · Apple Silicon":variant.architecture == .x86_64 ? "macOS · Intel":(variant.architecture == .arm64 || variant.architecture == .universal) ? "macOS · ARM64":"macOS")
      picker.addItem(withTitle:name+(variant.installed ? " · Installato":" · Da installare"));picker.lastItem?.representedObject=variant.id
      if variant.id==selectedID{picker.select(picker.lastItem)}
    }
    picker.isEnabled=choices.count>1
    let variant=selectedVariant,job=currentJob,installed=variant?.installed==true
    if installed || job != nil{transferStatus=nil}
    let external=transferVariantID==variant?.id ? transferStatus:nil
    play.title=installed ? "Gioca":job==nil ? "Installa":["paused","interrupted"].contains(job!.state) ? "Riprendi":["failed","retry_wait"].contains(job!.state) ? "Riprova":"Download in corso"
    play.isEnabled=variant != nil && (installed || job==nil || ["paused","interrupted","failed","retry_wait"].contains(job!.state))
    if external != nil{play.title="Download in corso";play.isEnabled=false}
    options.isEnabled=variant != nil
    progress.isHidden=job==nil && external==nil;control.isHidden=job==nil
    if let job{
      let names=["queued":"In coda","preparing":"Preparazione","running":"Download in corso","downloading":"Download in corso","verifying":"Verifica dei file","paused":"In pausa","interrupted":"Interrotto","failed":"Download non riuscito","retry_wait":"Attesa della rete","authorization_required":"Accedi a Steam per continuare"]
      var description=names[job.state] ?? "Download"
      if let fraction=job.fraction{description += " · "+String(format:"%.0f%%",fraction*100)}
      if let completed=job.completed{description += " · "+ByteCountFormatter.string(fromByteCount:completed,countStyle:.file);if let total=job.total{description += " / "+ByteCountFormatter.string(fromByteCount:total,countStyle:.file)}}
      status.stringValue=description;progress.isIndeterminate=job.fraction==nil
      if let fraction=job.fraction{progress.doubleValue=fraction}else{progress.startAnimation(nil)}
      control.title=["paused","interrupted"].contains(job.state) ? "Riprendi":["failed","retry_wait"].contains(job.state) ? "Riprova":"Metti in pausa"
    }else if let external{
      status.stringValue=external;progress.isIndeterminate=transferFraction==nil
      if let transferFraction{progress.stopAnimation(nil);progress.doubleValue=transferFraction}else{progress.startAnimation(nil)}
    }else{progress.stopAnimation(nil);status.stringValue=variant.map{$0.installed ? $0.verification:"Scegli la versione da scaricare. L’architettura macOS verrà verificata sui file installati."} ?? "Nessuna versione disponibile per questo titolo."}
    scheduleLayout()
  }
  override func layout(){super.layout();if abs(lastWidth-bounds.width)>0.5{performLayout()}}
  private func scheduleLayout(){
    guard !layoutQueued else{return};layoutQueued=true
    DispatchQueue.main.async{[weak self]in guard let self else{return};self.layoutQueued=false;self.performLayout()}
  }
  private func labelHeight(_ label:NSTextField,_ width:CGFloat)->CGFloat{ceil(label.attributedStringValue.boundingRect(with:NSSize(width:max(1,width),height:100000),options:[.usesLineFragmentOrigin,.usesFontLeading]).height)}
  private func performLayout(){
    let width=max(280,bounds.width);lastWidth=bounds.width
    var y:CGFloat=0
    let heroHeight=min(300,max(150,width*0.34));hero.frame=NSRect(x:0,y:y,width:width,height:heroHeight);y+=heroHeight+22
    let titleHeight=max(34,labelHeight(titleLabel,width));titleLabel.frame=NSRect(x:0,y:y,width:width,height:titleHeight);y+=titleHeight+10
    let summaryHeight=max(22,labelHeight(summary,width));summary.frame=NSRect(x:0,y:y,width:width,height:summaryHeight);y+=summaryHeight+24
    versionLabel.frame=NSRect(x:0,y:y,width:width,height:18);y+=24
    picker.frame=NSRect(x:0,y:y,width:min(480,width),height:30);y+=44
    let primaryWidth=min(190,(width-12)*0.6);play.frame=NSRect(x:0,y:y,width:primaryWidth,height:44);options.frame=NSRect(x:primaryWidth+12,y:y,width:min(120,width-primaryWidth-12),height:44);y+=58
    let statusHeight=max(19,labelHeight(status,width));status.frame=NSRect(x:0,y:y,width:width,height:statusHeight);y+=statusHeight+10
    if !progress.isHidden{progress.frame=NSRect(x:0,y:y,width:width,height:10);y+=22;if currentJob != nil{control.frame=NSRect(x:0,y:y,width:170,height:32);y+=46}}
    y+=18;aboutHeading.frame=NSRect(x:0,y:y,width:width,height:27);y+=38
    let aboutHeight=max(24,labelHeight(about,width));about.frame=NSRect(x:0,y:y,width:width,height:aboutHeight);y+=aboutHeight+28
    let factsHeight=max(20,labelHeight(facts,width));facts.frame=NSRect(x:0,y:y,width:width,height:factsHeight);y+=factsHeight+18
    if abs(frame.height-y)>0.5{setFrameSize(NSSize(width:bounds.width,height:y));NotificationCenter.default.post(name:.readyDialogContentLayoutChanged,object:self)}
  }
}
