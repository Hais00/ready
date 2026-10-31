// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// A full-content page may inherit the launcher background instead of drawing a panel.
protocol ReadyPageTransparentContent {}

struct ReadyPageTab {
  let id:String
  let title:String
  let action:()->Void
  init(id:String,title:String,action:@escaping()->Void){self.id=id;self.title=title;self.action=action}
}
private func pageColor(_ hex:Int)->NSColor {
  let gray=(0.2126*CGFloat((hex>>16)&255)+0.7152*CGFloat((hex>>8)&255)+0.0722*CGFloat(hex&255))/255
  return NSColor(srgbRed:gray,green:gray,blue:gray,alpha:1)
}
private final class PageSurface:NSView {
  var changed:(()->Void)?
  private var reportedSize=NSSize.zero
  override var isFlipped:Bool{true}
  override func layout(){super.layout();if reportedSize != bounds.size{reportedSize=bounds.size;changed?()}}
  override func mouseDown(with event:NSEvent){} // Only this main-content rectangle.
}
private final class PageDocument:NSView {override var isFlipped:Bool{true}}
private final class PageActionButton:NSButton {
  var role:ReadyDialogRole = .normal
  var requestID:UUID?
  var navigationID:UUID?
  private var hover=false
  private var labelFont:NSFont{.systemFont(ofSize:14,weight:.semibold)}
  override var intrinsicContentSize:NSSize {
    let measured=(title as NSString).size(withAttributes:[.font:labelFont])
    return NSSize(width:ceil(measured.width)+20,height:max(32,ceil(measured.height)+12))
  }
  override var acceptsFirstResponder:Bool{isEnabled}
  override func becomeFirstResponder()->Bool{needsDisplay=true;return super.becomeFirstResponder()}
  override func resignFirstResponder()->Bool{needsDisplay=true;return super.resignFirstResponder()}
  override func updateTrackingAreas(){
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect:bounds,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil))
    super.updateTrackingAreas()
  }
  override func mouseEntered(with event:NSEvent){hover=true;needsDisplay=true}
  override func mouseExited(with event:NSEvent){hover=false;needsDisplay=true}
  override func resetCursorRects(){super.resetCursorRects();addCursorRect(bounds,cursor:isEnabled ? .pointingHand:.arrow)}
  override func draw(_ dirtyRect:NSRect){
    let primary=role == .primary,pressed=isEnabled && isHighlighted
    let fill=primary ? (pressed ? 0x76cda0:hover ? 0xc5ffdc:0xa2eec2):(pressed ? 0x45625c:hover ? 0x35484b:0x263237)
    pageColor(fill).withAlphaComponent(isEnabled ? 1:0.4).setFill()
    let border=NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:8,yRadius:8);border.fill()
    if window?.firstResponder===self{pageColor(0xc7ffe0).setStroke();border.lineWidth=2;border.stroke()}
    let paragraph=NSMutableParagraphStyle();paragraph.alignment = .center;paragraph.lineBreakMode = .byTruncatingMiddle
    let color=primary ? pageColor(0x10291f):(role == .destructive ? pageColor(0xffc5b4):.white)
    let text=NSAttributedString(string:title,attributes:[.font:labelFont,.foregroundColor:color.withAlphaComponent(isEnabled ? 1:0.4),.paragraphStyle:paragraph])
    text.draw(in:NSRect(x:10,y:(bounds.height-text.size().height)/2,width:max(0,bounds.width-20),height:text.size().height))
  }
}

/// Nonmodal main-content pages. Sidebar/topbar outside the page rectangle keep
/// their native event/focus routing; no window, shade or keyboard monitor exists.
final class ReadyPagePresenter:NSObject {
  private struct Request {
    let id:UUID
    let title:String
    let message:String
    let content:NSView?
    var actions:[ReadyDialogAction]
    let onCancel:(()->Void)?
    let completion:(Int)->Void
  }
  private let windowProvider:()->NSWindow?
  private let hostProvider:()->NSView?
  private var active:Request?
  private var finishing:Request?
  private var keepFinishing=false
  private var silentFinishing=Set<UUID>()
  private var page:PageSurface?
  private var scroll:NSScrollView?
  private var document:PageDocument?
  private var messageLabel:NSTextField?
  private var titleLabel:NSTextField?
  private var noticeLabel:NSTextField?
  private var navigationLabel:NSTextField?
  private var tabScroll:NSScrollView?
  private var tabDocument:PageDocument?
  private var backButton:PageActionButton?
  private var tabButtons=[PageActionButton]()
  private var actionButtons=[PageActionButton]()
  private var navigationTitle=""
  private var tabs=[ReadyPageTab]()
  private var selected:String?
  private var onBack:(()->Void)?
  private var inlineNotice:String?
  private var navigationID=UUID(),revision=UUID()
  private var observer:NSObjectProtocol?
  private var layoutScheduled=false,layingOut=false
  private weak var pendingFocus:NSView?
  private weak var previousResponder:NSResponder?
  private var changeDepth=0,landingPending=false
  var onNeedsLanding:(()->Void)?
  var canNavigate:(()->Bool)?
  var isPresenting:Bool{active != nil || finishing != nil}

  init(window:@escaping()->NSWindow?,host:@escaping()->NSView?){windowProvider=window;hostProvider=host}
  deinit{if let observer{NotificationCenter.default.removeObserver(observer)}}
  func configureNavigation(title:String,tabs:[ReadyPageTab],selected:String?,onBack:(()->Void)?=nil){
    precondition(Thread.isMainThread)
    navigationTitle=title;self.tabs=tabs;self.selected=selected;self.onBack=onBack;navigationID=UUID()
    if page != nil{buildNavigation();scheduleLayout()}
  }
  @discardableResult func present(title:String,message:String,content:NSView?,actions:[ReadyDialogAction],
    onCancel:(()->Void)?=nil,completion:@escaping(Int)->Void)->UUID {
    precondition(Thread.isMainThread)
    let request=Request(id:UUID(),title:title,message:message,content:content,actions:actions,onCancel:onCancel,completion:completion)
    let intent=UUID();revision=intent
    changeDepth+=1;defer{changeDepth-=1;flushLanding()}
    removeFinishingSilently()
    if active != nil{finish(cancelIndex,notify:true,cancelled:true,landing:false)}
    // A cancellation completion may itself choose a newer page. The newest
    // explicit present wins; the former page is never called a second time.
    guard revision==intent else{return request.id}
    active=request;inlineNotice=nil;landingPending=false
    attach()
    return request.id
  }
  func attach(){
    precondition(Thread.isMainThread)
    guard page==nil,let request=active,let host=hostProvider(),windowProvider() != nil else{return}
    previousResponder=windowProvider()?.firstResponder
    let surface=PageSurface(frame:pageRect(host.bounds));surface.identifier=NSUserInterfaceItemIdentifier("ready.page.surface")
    surface.autoresizingMask=[.width,.height];surface.wantsLayer=true;surface.layer?.backgroundColor=(request.content is ReadyPageTransparentContent ? NSColor.clear:pageColor(0x111a1e)).cgColor
    surface.appearance=NSAppearance(named:.darkAqua);host.addSubview(surface);page=surface
    surface.changed={[weak self]in self?.scheduleLayout()}
    let title=NSTextField(wrappingLabelWithString:request.title);title.font = .systemFont(ofSize:25,weight:.bold);title.textColor = .white
    surface.addSubview(title);titleLabel=title
    let notice=NSTextField(wrappingLabelWithString:"");notice.font = .systemFont(ofSize:13,weight:.medium);notice.textColor=pageColor(0xffd2ad)
    notice.isSelectable=true;surface.addSubview(notice);noticeLabel=notice
    let scroll=NSScrollView();scroll.identifier=NSUserInterfaceItemIdentifier("ready.page.scroll")
    scroll.drawsBackground=false;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true
    let document=PageDocument();document.identifier=NSUserInterfaceItemIdentifier("ready.page.document")
    let message=NSTextField(wrappingLabelWithString:request.message);message.font = .systemFont(ofSize:14);message.textColor=pageColor(0xc3d0ce);message.isSelectable=true
    document.addSubview(message);messageLabel=message
    if let content=request.content{document.addSubview(content)}
    scroll.documentView=document;surface.addSubview(scroll);self.scroll=scroll;self.document=document
    actionButtons=request.actions.enumerated().map{index,action in
      let button=PageActionButton(title:action.title,target:self,action:#selector(actionClicked(_:)))
      button.role=action.role;button.tag=index;button.isEnabled=action.enabled;button.requestID=request.id
      button.isBordered=false;button.setButtonType(.momentaryPushIn);button.focusRingType = .none
      surface.addSubview(button);return button
    }
    buildNavigation()
    if let content=request.content,content is ReadyDialogContentSizing {
      let requestID=request.id
      observer=NotificationCenter.default.addObserver(forName:.readyDialogContentLayoutChanged,object:content,queue:.main){[weak self] notification in
        guard let self,self.active?.id==requestID else{return}
        self.scheduleLayout(focus:notification.userInfo?["focus"]as?NSView)
      }
    }
    scheduleLayout()
    let requestID=request.id
    DispatchQueue.main.async{[weak self]in
      guard let self,self.active?.id==requestID,let surface=self.page,let window=self.windowProvider()else{return}
      window.recalculateKeyViewLoop() // Standard window loop, never a closed modal cycle.
      let controls=self.controls(in:surface)
      if let first=controls.first(where:{($0 as?NSTextField)?.isEditable==true}) ?? controls.first{window.makeFirstResponder(first)}
    }
  }
  func isShowing(_ id:UUID)->Bool{active?.id==id || finishing?.id==id}
  func setActionEnabled(_ id:UUID,index:Int,enabled:Bool){
    precondition(Thread.isMainThread)
    guard let request=active ?? finishing,request.id==id,request.actions.indices.contains(index)else{return}
    if active?.id==id{active?.actions[index].enabled=enabled}else{finishing?.actions[index].enabled=enabled}
    if actionButtons.indices.contains(index){actionButtons[index].isEnabled=enabled;actionButtons[index].needsDisplay=true}
  }
  func activatePrimary(_ id:UUID){
    precondition(Thread.isMainThread)
    guard active?.id==id,let request=active,
      let index=request.actions.firstIndex(where:{$0.role == .primary && $0.enabled}),actionButtons.indices.contains(index)else{return}
    actionButtons[index].performClick(nil)
  }
  func showNotice(_ message:String?){
    precondition(Thread.isMainThread)
    guard active != nil || finishing != nil else{return};inlineNotice=message.flatMap{$0.isEmpty ? nil:$0}
    if finishing != nil{keepFinishing=inlineNotice != nil}
    noticeLabel?.stringValue=inlineNotice ?? "";scheduleLayout()
  }
  func dismiss(_ id:UUID){
    precondition(Thread.isMainThread)
    if finishing?.id==id{removeFinishingSilently();return}
    guard active?.id==id else{return};changeDepth+=1
    finish(-1,notify:false,cancelled:false,landing:false)
    changeDepth-=1;landingPending=false
  }
  func cancelCurrent(){
    precondition(Thread.isMainThread)
    if finishing != nil{removeFinishingSilently();return}
    guard active != nil else{return};changeDepth+=1
    finish(cancelIndex,notify:true,cancelled:true,landing:true)
    changeDepth-=1;flushLanding()
  }
  func detachForSession()->[String]{
    precondition(Thread.isMainThread)
    let notices=(active ?? finishing).map{[$0.title+($0.message.isEmpty ? "":": "+$0.message)]} ?? []
    removeFinishingSilently()
    if active != nil{finish(-1,notify:false,cancelled:false,landing:false)}
    landingPending=false;return notices
  }
  private var cancelIndex:Int{active?.actions.firstIndex(where:{$0.role == .cancel && $0.enabled}) ?? -1}
  private func finish(_ index:Int,notify:Bool,cancelled:Bool,landing:Bool){
    guard let request=active else{return}
    active=nil
    if notify && !cancelled{finishing=request;keepFinishing=false}else{removeSurface()}
    if notify {
      if cancelled{request.onCancel?()}
      request.completion(index)
    }
    if finishing?.id==request.id {
      let retained=finishing!;finishing=nil
      if keepFinishing{keepFinishing=false;active=retained;scheduleLayout();return}
      removeSurface()
    }
    if landing && silentFinishing.remove(request.id)==nil{landingPending=true}
  }
  /// A primary completion already owns its callback. Navigation/dismiss/detach
  /// inside it remove the old surface without a second onCancel/completion.
  private func removeFinishingSilently(){
    guard let request=finishing else{return}
    silentFinishing.insert(request.id);finishing=nil;keepFinishing=false;removeSurface()
  }
  private func flushLanding(){
    guard changeDepth==0 else{return}
    guard active==nil else{landingPending=false;return}
    if landingPending{landingPending=false;onNeedsLanding?()}
  }
  private func removeSurface(){
    if let observer{NotificationCenter.default.removeObserver(observer)};observer=nil
    pendingFocus=nil;layoutScheduled=false
    page?.changed=nil;page?.removeFromSuperview();page=nil;scroll=nil;document=nil
    messageLabel=nil;titleLabel=nil;noticeLabel=nil;navigationLabel=nil;tabScroll=nil;tabDocument=nil
    actionButtons=[];tabButtons=[];backButton=nil
    if let window=windowProvider(){window.recalculateKeyViewLoop();window.makeFirstResponder(previousResponder ?? hostProvider())}
    previousResponder=nil
  }
  private func buildNavigation(){
    guard let surface=page,let request=active else{return}
    navigationLabel?.removeFromSuperview();tabScroll?.removeFromSuperview();backButton?.removeFromSuperview()
    let heading=NSTextField(labelWithString:navigationTitle);heading.font = .systemFont(ofSize:13,weight:.semibold);heading.textColor=pageColor(0xa2eec2)
    surface.addSubview(heading);navigationLabel=heading
    if onBack != nil {
      let back=PageActionButton(title:"← Indietro",target:self,action:#selector(backClicked(_:)))
      back.isBordered=false;back.focusRingType = .none;back.requestID=request.id;back.navigationID=navigationID;surface.addSubview(back);backButton=back
    }
    let strip=NSScrollView();strip.drawsBackground=false;strip.hasHorizontalScroller=true;strip.autohidesScrollers=true
    let row=PageDocument();strip.documentView=row;surface.addSubview(strip);tabScroll=strip;tabDocument=row
    tabButtons=tabs.enumerated().map{index,tab in
      let button=PageActionButton(title:tab.title,target:self,action:#selector(tabClicked(_:)))
      button.tag=index;button.requestID=request.id;button.navigationID=navigationID;button.role=tab.id==selected ? .primary:.normal
      button.isBordered=false;button.focusRingType = .none;button.setButtonType(.momentaryPushIn);row.addSubview(button);return button
    }
  }
  private func scheduleLayout(focus:NSView?=nil){
    if let focus{pendingFocus=focus}
    guard !layoutScheduled,let id=active?.id else{return};layoutScheduled=true
    DispatchQueue.main.async{[weak self]in
      guard let self,self.active?.id==id else{return}
      self.layoutScheduled=false;self.layoutPage()
    }
  }
  private func layoutPage(){
    guard !layingOut,let request=active,let surface=page,let scroll,let document,let messageLabel,let titleLabel else{return}
    layingOut=true;defer{layingOut=false}
    let padding:CGFloat=20,gap:CGFloat=12,width=max(0,surface.bounds.width-padding*2)
    var y=padding
    if !navigationTitle.isEmpty || onBack != nil {
      let backWidth:CGFloat=onBack==nil ? 0:110
      navigationLabel?.frame=NSRect(x:padding,y:y+7,width:max(0,width-backWidth-12),height:20)
      backButton?.frame=NSRect(x:padding+max(0,width-backWidth),y:y,width:backWidth,height:32)
      y+=36
    }
    if !tabs.isEmpty {
      tabScroll?.isHidden=false;tabScroll?.frame=NSRect(x:padding,y:y,width:width,height:38)
      var x:CGFloat=0
      for button in tabButtons{let w=max(82,button.intrinsicContentSize.width+12);button.frame=NSRect(x:x,y:0,width:w,height:32);x+=w+8}
      tabDocument?.frame=NSRect(x:0,y:0,width:max(width,x-8),height:32);y+=46
    }else{tabScroll?.isHidden=true}
    let titleHeight=height(of:titleLabel,width:width)
    titleLabel.frame=NSRect(x:padding,y:y,width:width,height:titleHeight);y+=titleHeight+gap
    if let noticeLabel {
      noticeLabel.stringValue=inlineNotice ?? "";noticeLabel.isHidden=inlineNotice==nil
      if inlineNotice != nil{let h=height(of:noticeLabel,width:width);noticeLabel.frame=NSRect(x:padding,y:y,width:width,height:h);y+=h+gap}
    }
    let minimum=actionButtons.map{max(84,$0.intrinsicContentSize.width+24)}.max() ?? 84
    let columns=max(1,min(actionButtons.count,Int((width+8)/(minimum+8))))
    let rows=actionButtons.isEmpty ? 0:Int(ceil(Double(actionButtons.count)/Double(columns)))
    let footer=CGFloat(rows)*36+CGFloat(max(0,rows-1))*8
    let footerY=max(y,surface.bounds.height-padding-footer)
    for (index,button) in actionButtons.enumerated(){
      let w=max(0,(width-CGFloat(columns-1)*8)/CGFloat(columns))
      button.frame=NSRect(x:padding+CGFloat(index%columns)*(w+8),y:footerY+CGFloat(index/columns)*44,width:w,height:36)
    }
    let viewport=max(0,footerY-(actionButtons.isEmpty ? 0:gap)-y)
    scroll.frame=NSRect(x:padding,y:y,width:width,height:viewport)
    let documentWidth=max(0,width-16)
    let textHeight=request.message.isEmpty ? 0:height(of:messageLabel,width:documentWidth)+8
    messageLabel.isHidden=request.message.isEmpty;messageLabel.frame=NSRect(x:0,y:0,width:documentWidth,height:textHeight)
    var total=textHeight
    if let content=request.content {
      if content is ReadyDialogContentSizing{content.setFrameSize(NSSize(width:documentWidth,height:content.frame.height))}
      content.frame.origin=NSPoint(x:0,y:textHeight+(textHeight>0 ? 12:0))
      total=content.frame.maxY
    }
    document.setFrameSize(NSSize(width:max(documentWidth,request.content?.frame.width ?? 0),height:max(viewport,total)))
    surface.layoutSubtreeIfNeeded()
    let limited=scroll.contentView.constrainBoundsRect(scroll.contentView.bounds);scroll.contentView.scroll(to:limited.origin)
    if let focus=pendingFocus,let content=request.content,focus===content||focus.isDescendant(of:content),!focus.isHiddenOrHasHiddenAncestor {
      _=document.scrollToVisible(document.convert(focus.bounds,from:focus).insetBy(dx:-8,dy:-8))
    }
    pendingFocus=nil;scroll.reflectScrolledClipView(scroll.contentView)
  }
  private func height(of label:NSTextField,width:CGFloat)->CGFloat {
    max(16,ceil(label.attributedStringValue.boundingRect(with:NSSize(width:max(1,width),height:100000),options:[.usesLineFragmentOrigin,.usesFontLeading]).height))
  }
  private func pageRect(_ bounds:NSRect)->NSRect{NSRect(x:112,y:88,width:max(0,bounds.width-148),height:max(0,bounds.height-112))}
  @objc private func actionClicked(_ sender:PageActionButton){
    guard sender.isEnabled,let request=active,sender.requestID==request.id,request.actions.indices.contains(sender.tag)else{return}
    changeDepth+=1
    let cancelled=request.actions[sender.tag].role == .cancel
    finish(sender.tag,notify:true,cancelled:cancelled,landing:true)
    changeDepth-=1;flushLanding()
  }
  @objc private func tabClicked(_ sender:PageActionButton){
    guard let request=active,sender.requestID==request.id,sender.navigationID==navigationID,tabs.indices.contains(sender.tag),tabs[sender.tag].id != selected else{return}
    navigate(tabs[sender.tag].action)
  }
  @objc private func backClicked(_ sender:PageActionButton){
    guard let request=active,sender.requestID==request.id,sender.navigationID==navigationID,let onBack else{return};navigate(onBack)
  }
  private func navigate(_ action:()->Void){
    guard canNavigate?() ?? true else{return}
    changeDepth+=1
    if active != nil{finish(cancelIndex,notify:true,cancelled:true,landing:false)}
    action();if active==nil{landingPending=true}
    changeDepth-=1;flushLanding()
  }
  private func controls(in view:NSView)->[NSView]{
    if view.isHiddenOrHasHiddenAncestor{return []}
    if let control=view as?NSControl,control.isEnabled,
      control is NSButton || control is NSTableView || (control as?NSTextField)?.isEditable==true{return[control]}
    return view.subviews.flatMap{controls(in:$0)}
  }
  private func focusedControl()->NSView?{
    if let editor=windowProvider()?.firstResponder as?NSTextView,editor.isFieldEditor{return editor.delegate as?NSView}
    return windowProvider()?.firstResponder as?NSView
  }
  @discardableResult func handleController(_ action:ControllerNavigation.Action)->Bool {
    precondition(Thread.isMainThread)
    guard active != nil,let surface=page,let window=windowProvider()else{return false}
    guard let focused=focusedControl(),focused===surface||focused.isDescendant(of:surface)else{return false}
    if action == .cancel{cancelCurrent();return true}
    if let table=focused as?NSTableView,case .move(let direction)=action,direction == .up || direction == .down {
      if table.numberOfRows>0{let row=max(0,min(table.numberOfRows-1,table.selectedRow+(direction == .up ? -1:1)));table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false);table.scrollRowToVisible(row)};return true
    }
    if action == .activate {
      if let button=focused as?NSButton{button.performClick(nil);return true}
      if let table=focused as?NSTableView,let selector=table.doubleAction{_=table.sendAction(selector,to:table.target);return true}
      if let field=focused as?NSTextField,let selector=field.action,let target=field.target{_=field.sendAction(selector,to:target);return true}
      if let id=active?.id{activatePrimary(id)}
      return true // Page focus must never activate a canvas item behind it.
    }
    if case .move(let direction)=action {
      let all=controls(in:surface);guard !all.isEmpty else{return false}
      let index=all.firstIndex(where:{$0===focused}) ?? 0,delta=direction == .up || direction == .left ? -1:1
      let next=max(0,min(all.count-1,index+delta));window.makeFirstResponder(all[next]);_=all[next].scrollToVisible(all[next].bounds);return true
    }
    return false
  }
}
