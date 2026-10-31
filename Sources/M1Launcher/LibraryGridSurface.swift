// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import QuartzCore

enum LibraryCardMetrics {
  static let coverRatio:CGFloat=1.5
  static let titleHeight:CGFloat=42
  static let edgePadding:CGFloat=7
  static let focusOutset:CGFloat=4
}

private final class LibraryGridDocument:NSView {
  weak var canvas:MetalCanvas?
  var inputEnabled=true
  var cardRects=[CGRect]()
  override var isFlipped:Bool{true}
  override func makeBackingLayer()->CALayer{let layer=CALayer();layer.isGeometryFlipped=true;return layer}
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
  var feedbackGeometry:[CGRect]{[selection,hover,focus].filter{!$0.isHidden}.map{$0.frame.insetBy(dx:-$0.lineWidth/2,dy:-$0.lineWidth/2)}}
  var documentBounds:CGRect{grid.bounds}
  var offset:CGFloat{contentView.bounds.minY}
  var visibleTileFrames:[CGRect]{layers.values.map{$0.frame.offsetBy(dx:frame.minX,dy:frame.minY-offset)}}
  init(canvas:MetalCanvas){
    super.init(frame:.zero);grid.canvas=canvas
    drawsBackground=false;hasVerticalScroller=true;autohidesScrollers=true;scrollerStyle = .overlay;borderType = .noBorder
    automaticallyAdjustsContentInsets=false;contentInsets=NSEdgeInsets(top:0,left:0,bottom:0,right:0);contentView.drawsBackground=false
    grid.wantsLayer=true;grid.layerContentsRedrawPolicy = .never
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
      layer.backgroundColor=NSColor(white:tile.installed ? 0.19:0.16,alpha:1).cgColor
      layer.cornerRadius=11;layer.masksToBounds=true
    }
    let safe=grid.canvas.map{grid.convert($0.libraryInteractionViewport,from:$0)} ?? grid.bounds
    grid.cardRects=tiles.map{$0.frame.intersection(safe)}.filter{!$0.isEmpty}
    func overlay(_ layer:CAShapeLayer,_ id:String?,_ color:NSColor,_ width:CGFloat,_ inset:CGFloat,_ fill:NSColor?=nil){
      guard let id,let tile=tiles.first(where:{$0.id==id})else{layer.isHidden=true;return}
      layer.isHidden=false;layer.frame=tile.frame.insetBy(dx:inset,dy:inset);layer.path=CGPath(roundedRect:layer.bounds,cornerWidth:13,cornerHeight:13,transform:nil)
      layer.strokeColor=color.cgColor;layer.fillColor=(fill ?? .clear).cgColor;layer.lineWidth=width
    }
    overlay(selection,selected,NSColor.white,2,-3)
    overlay(hover,hovered,.white.withAlphaComponent(pressed==hovered ? 0.5:0.28),1.5,0.75,.white.withAlphaComponent(pressed==hovered ? 0.02:0.065))
    overlay(focus,showFocus ? focused:nil,NSColor.white,2,-3)
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

/// Bounded immutable card composition. Main only captures inputs and assigns the
/// completed CGImage; event tracking never waits for text/image rasterization.
final class LibraryTileRenderer {
  struct Request {
    let id:String,key:LibraryTileCache.Key,size:NSSize,scale:CGFloat,content:LibraryCardContent,visible:Bool
  }
  struct Statistics {var running=0,maximumRunning=0,rasters=0,mainThreadRasters=0,pending=0}
  private final class Ticket {
    let request:Request,operation=BlockOperation()
    init(_ request:Request){self.request=request}
  }
  private let workers:OperationQueue = {let q=OperationQueue();q.name="app.ready.library.card-raster";q.qualityOfService = .userInitiated;q.maxConcurrentOperationCount=2;return q}()
  private var tickets=[String:Ticket]()
  private let lock=NSLock();private var counters=Statistics()
  var statistics:Statistics{lock.lock();var value=counters;lock.unlock();value.pending=tickets.count;return value}
  func cancel(){tickets.values.forEach{$0.operation.cancel()};tickets.removeAll();workers.cancelAllOperations()}
  deinit{workers.cancelAllOperations()}
  func prepare(_ requests:[Request],completion:@escaping(Request,CGImage,Double)->Void){
    let wanted=Dictionary(requests.map{($0.id,$0)},uniquingKeysWith:{$1})
    for (id,ticket) in tickets{
      guard let next=wanted[id],next.key==ticket.request.key,(next.content.artwork != nil)==(ticket.request.content.artwork != nil)else{ticket.operation.cancel();tickets.removeValue(forKey:id);continue}
      ticket.operation.queuePriority=next.visible ? .veryHigh:.low
    }
    for request in requests where tickets[request.id]==nil{
      let ticket=Ticket(request);tickets[request.id]=ticket
      ticket.operation.queuePriority=request.visible ? .veryHigh:.low
      ticket.operation.addExecutionBlock{[weak self,weak ticket]in
        guard let self,let ticket,!ticket.operation.isCancelled else{return}
        self.lock.lock();self.counters.running+=1;self.counters.maximumRunning=max(self.counters.maximumRunning,self.counters.running);self.counters.rasters+=1;if Thread.isMainThread{self.counters.mainThreadRasters+=1};self.lock.unlock()
        let began=ProcessInfo.processInfo.systemUptime
        let image:CGImage?=autoreleasepool{
          guard !ticket.operation.isCancelled,let bitmap=CanvasRaster(width:request.key.pixelWidth,height:request.key.pixelHeight)else{return nil}
          bitmap.draw(logicalSize:request.size,scale:request.scale){request.content.draw(in:$0,rect:CGRect(origin:.zero,size:request.size))}
          return bitmap.context.makeImage()
        }
        let elapsed=(ProcessInfo.processInfo.systemUptime-began)*1000
        self.lock.lock();self.counters.running-=1;self.lock.unlock()
        guard !ticket.operation.isCancelled else{return}
        let modes=[RunLoop.Mode.common.rawValue,RunLoop.Mode.eventTracking.rawValue,RunLoop.Mode.modalPanel.rawValue]as CFArray
        CFRunLoopPerformBlock(CFRunLoopGetMain(),modes){[weak self,weak ticket]in
          guard let self,let ticket,!ticket.operation.isCancelled,self.tickets[request.id]===ticket else{return}
          self.tickets.removeValue(forKey:request.id)
          if let image{completion(request,image,elapsed)}
        };CFRunLoopWakeUp(CFRunLoopGetMain())
      }
      workers.addOperation(ticket.operation)
    }
  }
}
