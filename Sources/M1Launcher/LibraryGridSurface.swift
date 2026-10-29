// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import QuartzCore

private final class LibraryGridDocument:NSView {
  weak var canvas:MetalCanvas?
  var inputEnabled=true
  var cardRects=[CGRect]()
  override var isFlipped:Bool{true}
  override var acceptsFirstResponder:Bool{false}
  override func resetCursorRects(){super.resetCursorRects();if inputEnabled{for rect in cardRects{addCursorRect(rect,cursor:.pointingHand)}}}
  override func mouseDown(with event:NSEvent){if inputEnabled{canvas?.mouseDown(with:event)}}
  override func mouseUp(with event:NSEvent){if inputEnabled{canvas?.mouseUp(with:event)}}
  override func rightMouseDown(with event:NSEvent){if inputEnabled{canvas?.rightMouseDown(with:event)}}
  override func mouseMoved(with event:NSEvent){if inputEnabled{canvas?.mouseMoved(with:event)}}
  override func mouseDragged(with event:NSEvent){if inputEnabled{canvas?.mouseDragged(with:event)}}
}
/// A sparse layer-hosted document: no document-sized backing bitmap exists.
/// Core Animation scrolls immutable card images through the native clip view.
final class LibraryGridSurface:NSScrollView {
  struct Tile {let id:String;let frame:CGRect;let image:CGImage?;let installed:Bool}
  private let grid=LibraryGridDocument()
  private var layers=[String:CALayer](),pool=[CALayer]()
  private let selection=CAShapeLayer(),hover=CAShapeLayer(),focus=CAShapeLayer()
  private var observer:NSObjectProtocol?
  private var settingOffset=false
  var didScroll:((CGFloat)->Void)?
  var inputEnabled=true{didSet{grid.inputEnabled=inputEnabled}}
  var tileLayerCount:Int{layers.count}
  var offset:CGFloat{contentView.bounds.minY}
  init(canvas:MetalCanvas){
    super.init(frame:.zero);grid.canvas=canvas
    drawsBackground=false;hasVerticalScroller=true;autohidesScrollers=true;scrollerStyle = .overlay;borderType = .noBorder
    grid.layer=CALayer();grid.wantsLayer=true;grid.layerContentsRedrawPolicy = .never
    grid.layer?.isGeometryFlipped=true;grid.layer?.backgroundColor=NSColor.clear.cgColor
    for overlay in [selection,hover,focus]{overlay.fillColor=NSColor.clear.cgColor;overlay.isHidden=true;grid.layer?.addSublayer(overlay)}
    documentView=grid;contentView.postsBoundsChangedNotifications=true
    observer=NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:contentView,queue:.main){[weak self]_ in
      guard let self,!self.settingOffset else{return};self.didScroll?(self.offset)
    }
  }
  required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
  deinit{if let observer{NotificationCenter.default.removeObserver(observer)}}
  override func scrollWheel(with event:NSEvent){if inputEnabled{super.scrollWheel(with:event)}}
  func configure(frame:NSRect,documentSize:NSSize,offset:CGFloat){
    CATransaction.begin();CATransaction.setDisableActions(true)
    self.frame=frame;grid.setFrameSize(NSSize(width:max(1,documentSize.width),height:max(frame.height,documentSize.height)))
    grid.layer?.frame=grid.bounds
    setOffset(offset);CATransaction.commit()
  }
  func setOffset(_ offset:CGFloat){
    guard abs(contentView.bounds.minY-offset)>0.01 else{return}
    settingOffset=true;contentView.scroll(to:NSPoint(x:0,y:offset));reflectScrolledClipView(contentView);settingOffset=false
  }
  func update(_ tiles:[Tile],selected:String?,hovered:String?,focused:String?,pressed:String?,showFocus:Bool){
    CATransaction.begin();CATransaction.setDisableActions(true)
    let retained=Set(tiles.map(\.id))
    for id in Array(layers.keys) where !retained.contains(id){
      if let layer=layers.removeValue(forKey:id){layer.contents=nil;layer.removeFromSuperlayer();if pool.count<96{pool.append(layer)}}
    }
    for tile in tiles{
      let layer:CALayer
      if let existing=layers[tile.id]{layer=existing}else{layer=pool.popLast() ?? CALayer();layer.contentsGravity = .resize;layer.minificationFilter = .linear;layer.magnificationFilter = .linear;grid.layer?.insertSublayer(layer,at:0);layers[tile.id]=layer}
      layer.frame=tile.frame;layer.contents=tile.image
      layer.backgroundColor=NSColor(srgbRed:tile.installed ? 0.14:0.14,green:tile.installed ? 0.2:0.16,blue:0.17,alpha:1).cgColor
      layer.cornerRadius=11;layer.masksToBounds=true
    }
    grid.cardRects=tiles.map(\.frame)
    func overlay(_ layer:CAShapeLayer,_ id:String?,_ color:NSColor,_ width:CGFloat,_ inset:CGFloat,_ fill:NSColor?=nil){
      guard let id,let tile=tiles.first(where:{$0.id==id})else{layer.isHidden=true;return}
      layer.isHidden=false;layer.frame=tile.frame.insetBy(dx:inset,dy:inset);layer.path=CGPath(roundedRect:layer.bounds,cornerWidth:13,cornerHeight:13,transform:nil)
      layer.strokeColor=color.cgColor;layer.fillColor=(fill ?? .clear).cgColor;layer.lineWidth=width
    }
    overlay(selection,selected,NSColor(srgbRed:0.71,green:1,blue:0.82,alpha:1),2,-3)
    overlay(hover,hovered,.white.withAlphaComponent(pressed==hovered ? 0.5:0.28),1.5,0.75,.white.withAlphaComponent(pressed==hovered ? 0.02:0.065))
    overlay(focus,showFocus ? focused:nil,NSColor(srgbRed:0.71,green:1,blue:0.82,alpha:1),2,-3)
    for overlay in [selection,hover,focus]{grid.layer?.addSublayer(overlay)}
    CATransaction.commit();window?.invalidateCursorRects(for:grid)
  }
  func clear(){
    CATransaction.begin();CATransaction.setDisableActions(true)
    layers.values.forEach{$0.contents=nil;$0.removeFromSuperlayer()};layers.removeAll();pool.removeAll();grid.cardRects=[]
    for layer in [selection,hover,focus]{layer.isHidden=true;layer.path=nil}
    CATransaction.commit();removeFromSuperview()
  }
  func renderVisible(in context:CGContext){
    guard !isHidden else{return}
    context.saveGState();context.clip(to:frame);context.translateBy(x:frame.minX,y:frame.minY-offset)
    grid.layer?.render(in:context);context.restoreGState()
  }
}

final class LibraryTileCache {
  struct Key:Equatable {let title:String,store:String,platforms:String;let installed:Bool;let revision:UInt64;let pixelWidth:Int,pixelHeight:Int}
  private struct Entry {let key:Key,image:CGImage,bytes:Int;var used:UInt64}
  private var entries=[String:Entry](),clock:UInt64=0
  private(set) var bytes=0
  private(set) var builds=0
  let byteLimit=64*1024*1024
  func image(id:String,key:Key)->CGImage?{guard var entry=entries[id],entry.key==key else{return nil};clock&+=1;entry.used=clock;entries[id]=entry;return entry.image}
  func insert(id:String,key:Key,image:CGImage){
    if let old=entries.removeValue(forKey:id){bytes-=old.bytes}
    let cost=image.bytesPerRow*image.height;guard cost<=byteLimit else{return}
    while !entries.isEmpty && (entries.count>=96 || bytes+cost>byteLimit){let victim=entries.min{$0.value.used<$1.value.used}!.key;bytes-=entries.removeValue(forKey:victim)!.bytes}
    clock&+=1;entries[id]=Entry(key:key,image:image,bytes:cost,used:clock);bytes+=cost;builds+=1
  }
  func invalidate(_ id:String){if let old=entries.removeValue(forKey:id){bytes-=old.bytes}}
  func clear(){entries.removeAll();bytes=0}
  var count:Int{entries.count}
}
