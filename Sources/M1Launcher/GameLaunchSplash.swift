// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import LauncherCore
import QuartzCore

private final class LaunchActionButton:NSButton {
  var actionBody:(()->Void)?
  var primary=false
  private var hovered=false
  convenience init(_ title:String,primary:Bool=false,action:@escaping()->Void){
    self.init(frame:.zero);self.title=title;self.primary=primary;actionBody=action
    target=self;self.action=#selector(invoke);isBordered=false
    setAccessibilityLabel(title)
  }
  @objc private func invoke(){actionBody?()}
  override func updateTrackingAreas(){
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect:bounds,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil))
    super.updateTrackingAreas()
  }
  override func mouseEntered(with event:NSEvent){hovered=true;needsDisplay=true}
  override func mouseExited(with event:NSEvent){hovered=false;needsDisplay=true}
  override func resetCursorRects(){super.resetCursorRects();addCursorRect(bounds,cursor:.pointingHand)}
  override func draw(_ dirtyRect:NSRect){
    let fill:CGFloat=isHighlighted ? 0.38:hovered ? 0.3:0.22
    (primary ? NSColor(srgbRed:0.64,green:0.94,blue:0.76,alpha:1):NSColor(white:fill,alpha:0.9)).setFill()
    NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:9,yRadius:9).fill()
    let p=NSMutableParagraphStyle();p.alignment = .center
    let text=NSAttributedString(string:title,attributes:[.font:NSFont.systemFont(ofSize:14,weight:.semibold),.foregroundColor:primary ? NSColor.black:.white,.paragraphStyle:p])
    text.draw(in:NSRect(x:8,y:(bounds.height-text.size().height)/2,width:bounds.width-16,height:text.size().height))
  }
}

/// A continuously animated, ordinary in-window view. It creates no window,
/// modal loop, renderer runtime or game process. Core Animation keeps moving
/// while asynchronous account and launch work completes.
final class GameLaunchSplash:NSView {
  let gameID:String
  var onCancel:(()->Void)?
  var onRetry:(()->Void)?
  private let artwork:ArtworkCache
  private let picture=CALayer(),shade=CAGradientLayer(),spinner=CAShapeLayer()
  private let titleLabel=NSTextField(labelWithString:"")
  private let placeholder=NSImageView()
  private let loadingLabel=NSTextField(labelWithString:"Caricamento")
  private let errorLabel=NSTextField(wrappingLabelWithString:"")
  private var cancelButton:LaunchActionButton!
  private var retryButton:LaunchActionButton!
  private var candidates=[String](),bannerCandidates=Set<String>()
  private var loadedAddress:String?,fullBleed=false,finished=false,failed=false
  private var loadedImageSize=CGSize.zero
  override var isFlipped:Bool{true}
  override var acceptsFirstResponder:Bool{true}
  init(game:Game,artwork:ArtworkCache=ArtworkCache(maximumPixelSize:2048)){
    gameID=game.id;self.artwork=artwork
    super.init(frame:.zero)
    wantsLayer=true;layer?.backgroundColor=NSColor.black.cgColor
    picture.masksToBounds=true;layer?.addSublayer(picture)
    shade.colors=[NSColor.black.withAlphaComponent(0.15).cgColor,NSColor.black.withAlphaComponent(0.35).cgColor,NSColor.black.withAlphaComponent(0.95).cgColor]
    shade.locations=[0,0.48,1];shade.startPoint=CGPoint(x:0.5,y:0);shade.endPoint=CGPoint(x:0.5,y:1)
    layer?.addSublayer(shade)
    placeholder.image=NSImage(systemSymbolName:"gamecontroller.fill",accessibilityDescription:"Gioco")
    placeholder.imageScaling = .scaleProportionallyUpOrDown
    placeholder.contentTintColor=NSColor(srgbRed:0.64,green:0.94,blue:0.76,alpha:1)
    addSubview(placeholder)
    for label in [titleLabel,loadingLabel,errorLabel]{label.textColor = .white;label.alignment = .center;label.isSelectable=false;addSubview(label)}
    titleLabel.font = .systemFont(ofSize:32,weight:.bold);titleLabel.lineBreakMode = .byTruncatingTail
    loadingLabel.font = .systemFont(ofSize:15,weight:.medium)
    errorLabel.font = .systemFont(ofSize:14);errorLabel.maximumNumberOfLines=4;errorLabel.isHidden=true
    spinner.fillColor=NSColor.clear.cgColor;spinner.strokeColor=NSColor(srgbRed:0.64,green:0.94,blue:0.76,alpha:1).cgColor
    spinner.lineWidth=3;spinner.lineCap = .round;spinner.strokeStart=0.08;spinner.strokeEnd=0.78
    layer?.addSublayer(spinner)
    cancelButton=LaunchActionButton("Annulla"){[weak self]in self?.onCancel?()}
    retryButton=LaunchActionButton("Riprova",primary:true){[weak self]in self?.onRetry?()}
    addSubview(cancelButton);addSubview(retryButton);retryButton.isHidden=true
    update(game:game)
    loadingLabel.wantsLayer=true
    setAccessibilityLabel("Avvio di "+game.title)
  }
  required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
  override func viewDidMoveToWindow(){
    super.viewDidMoveToWindow()
    if window != nil && !finished{startAnimations()}
    else{stopAnimations()}
  }
  private func startAnimations(){
    guard window != nil,!finished else{return}
    if !failed {
      let rotation=CABasicAnimation(keyPath:"transform.rotation.z")
      rotation.fromValue=0;rotation.toValue=Double.pi*2;rotation.duration=1;rotation.repeatCount = .infinity
      spinner.add(rotation,forKey:"loading.rotation")
      let pulse=CABasicAnimation(keyPath:"opacity")
      pulse.fromValue=0.55;pulse.toValue=1;pulse.duration=1.1;pulse.autoreverses=true;pulse.repeatCount = .infinity
      loadingLabel.layer?.add(pulse,forKey:"loading.pulse")
    }
    if fullBleed {
      let motion=CABasicAnimation(keyPath:"transform")
      motion.fromValue=NSValue(caTransform3D:CATransform3DMakeScale(1.04,1.04,1))
      motion.toValue=NSValue(caTransform3D:CATransform3DTranslate(CATransform3DMakeScale(1.13,1.13,1),18,-10,0))
      motion.duration=18;motion.autoreverses=true;motion.repeatCount = .infinity
      picture.add(motion,forKey:"artwork.motion")
    }else{picture.removeAnimation(forKey:"artwork.motion")}
  }
  private func stopAnimations(){
    picture.removeAllAnimations();spinner.removeAllAnimations();loadingLabel.layer?.removeAllAnimations()
  }
  func update(game:Game){
    guard !finished,game.id==gameID else{return}
    titleLabel.stringValue=game.title
    let banners=GameArtwork.candidates(for:game,role:.banner)
    bannerCandidates=Set(banners)
    var seen=Set<String>()
    candidates=(banners+GameArtwork.candidates(for:game,role:.icon)).filter{seen.insert($0).inserted}
    refreshArtwork()
  }
  private func refreshArtwork(){
    guard !finished else{return}
    for address in candidates {
      guard let image=artwork.image(address,refresh:{[weak self]in self?.refreshArtwork()}) else{continue}
      guard loadedAddress != address else{return}
      loadedAddress=address;loadedImageSize=CGSize(width:image.width,height:image.height)
      fullBleed=bannerCandidates.contains(address) && !GameArtwork.shouldAspectFit(imageSize:loadedImageSize,role:.banner)
      placeholder.isHidden=true
      CATransaction.begin();CATransaction.setAnimationDuration(0.45)
      picture.contents=image;picture.contentsGravity=fullBleed ? .resizeAspectFill:.resizeAspect
      CATransaction.commit();needsLayout=true
      startAnimations()
      return
    }
  }
  override func layout(){
    super.layout()
    CATransaction.begin();CATransaction.setDisableActions(true)
    shade.frame=bounds
    placeholder.frame=NSRect(x:bounds.midX-70,y:max(40,bounds.height*0.23),width:140,height:140)
    if fullBleed{picture.frame=bounds}else{
      let size=min(360,max(120,min(bounds.width*0.45,bounds.height*0.42)))
      let area=CGRect(x:(bounds.width-size)/2,y:max(30,bounds.height*0.14),width:size,height:size)
      picture.frame=GameArtwork.imageRect(imageSize:loadedImageSize,in:area,role:.icon)
    }
    let bottom=max(270,bounds.height*0.38),textWidth=max(100,bounds.width-80)
    titleLabel.frame=NSRect(x:40,y:bounds.height-bottom,width:textWidth,height:48)
    spinner.frame=CGRect(x:bounds.midX-14,y:bounds.height-bottom+73,width:28,height:28)
    spinner.path=CGPath(ellipseIn:CGRect(x:2,y:2,width:24,height:24),transform:nil)
    loadingLabel.frame=NSRect(x:40,y:bounds.height-bottom+111,width:textWidth,height:26)
    errorLabel.frame=NSRect(x:max(40,bounds.midX-340),y:bounds.height-bottom+62,width:min(textWidth,680),height:82)
    cancelButton.frame=NSRect(x:failed ? bounds.midX-138:bounds.midX-66,y:bounds.height-bottom+159,width:128,height:38)
    retryButton.frame=NSRect(x:bounds.midX+10,y:bounds.height-bottom+159,width:128,height:38)
    CATransaction.commit()
  }
  func showError(_ message:String){
    failed=true;spinner.isHidden=true;loadingLabel.isHidden=true
    spinner.removeAllAnimations();loadingLabel.layer?.removeAllAnimations()
    errorLabel.stringValue=String(message.prefix(800));errorLabel.isHidden=false
    cancelButton.title="Indietro";retryButton.isHidden=false;needsLayout=true
  }
  func finish(){
    guard !finished else{return};finished=true
    artwork.purge();stopAnimations()
    picture.contents=nil;removeFromSuperview()
  }
  override func mouseDown(with event:NSEvent){} // The whole launch surface owns its input.
  override func keyDown(with event:NSEvent){
    if event.keyCode==53{onCancel?()}
    else if failed && (event.keyCode==36||event.keyCode==76){onRetry?()}
  }
}

