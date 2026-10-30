// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AppKit

/// Metadata-only shell shared with the injected UI bridge. It deliberately has
/// no library artwork buffers, view/layer references or credentials. The sole
/// optional image is a bounded current-game dock icon, held only while visible.
enum ReadyShellDestination:String,Codable,CaseIterable {
  case library,game,friends,downloads,settings,profiles
  var title:String {switch self{case .library:return "Libreria";case .game:return "Gioco";case .friends:return "Amici";case .downloads:return "Download";case .settings:return "Impostazioni";case .profiles:return "Profili"}}
  var symbol:String {switch self{case .library:return "books.vertical.fill";case .game:return "gamecontroller.fill";case .friends:return "person.2";case .downloads:return "arrow.down.circle";case .settings:return "gearshape";case .profiles:return "person.crop.circle"}}
}
struct ReadyShellRunningGame:Codable,Equatable,Identifiable {
  let id:String
  let title:String
  /// Artwork lookup key only. The bridge may decode the active icon while the
  /// dock is visible, then release it; it must not warm the library thumbnails.
  var iconGameID:String{id}
}
enum ReadyShellTargetKind:String,Codable {case section,resumeGame,game,setting,back}
struct ReadyShellTarget:Codable,Equatable,Identifiable {
  var id:String
  var kind:ReadyShellTargetKind
  var label:String
  var subtitle:String?
  /// x, y, width, height in top-down normalized viewport coordinates.
  var rect:[Double]
  var enabled:Bool
  var symbol:String?
  var iconPNGBase64:String?=nil
}
struct ReadyShellContentRow:Codable,Equatable,Identifiable {
  var id:String
  var title:String
  var subtitle:String
  var symbol:String?
  var targetId:String?
}
struct ReadyShellSnapshot:Codable,Equatable {
  var schema:Int=1
  var pageId:String
  var title:String
  var viewportNormalized:[Double]
  var navigationTargets:[ReadyShellTarget]
  var dockTargets:[ReadyShellTarget]
  var selectedTargetId:String?
  var contentRows:[ReadyShellContentRow]
  var pageOffset:Int
  var totalRows:Int
  var footerError:String?
  var activeGameIds:[String]
  var resumeActionId:String?
  var header:String{title}
  func boundedJSONData()->Data? {
    let targets=navigationTargets+dockTargets
    guard schema==1,contentRows.count<=16,targets.count<=64,pageOffset>=0,totalRows>=0,
      viewportNormalized.count==4,viewportNormalized.allSatisfy{$0.isFinite && $0>=0 && $0<=1},
      pageId.utf8.count<=1024,title.utf8.count<=1024,(footerError?.utf8.count ?? 0)<=2048,
      targets.allSatisfy({$0.id.utf8.count<=2048 && $0.label.utf8.count<=1024 && ($0.subtitle?.utf8.count ?? 0)<=2048 && ($0.iconPNGBase64?.utf8.count ?? 0)<=16384 && ($0.iconPNGBase64 == nil || $0.kind == .resumeGame) && $0.rect.count==4 && $0.rect.allSatisfy{$0.isFinite && $0>=0 && $0<=1} && $0.rect[0]+$0.rect[2]<=1.000001 && $0.rect[1]+$0.rect[3]<=1.000001}),
      contentRows.allSatisfy({$0.id.utf8.count<=2048 && $0.title.utf8.count<=1024 && $0.subtitle.utf8.count<=4096}) else{return nil}
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
    guard let data=try?encoder.encode(self),data.count<=65536 else{return nil};return data
  }
  static func make(section:ReadyShellDestination,header:String?=nil,profileName:String,runningGames:[ReadyShellRunningGame],error:String?=nil)->Self {
    let library=ReadyShellTarget(id:"section:library",kind:.section,label:"Libreria",subtitle:nil,rect:[0.0125,0.14,0.045,0.065],enabled:true,symbol:"books.vertical.fill")
    var dock=[library]
    dock += runningGames.prefix(5).enumerated().map{index,game in ReadyShellTarget(id:"resume:"+game.id,kind:.resumeGame,label:game.title,subtitle:nil,rect:[0.0125,0.225+Double(index)*0.08,0.045,0.065],enabled:true,symbol:"gamecontroller.fill")}
    for (index,item) in [ReadyShellDestination.friends,.downloads,.settings].enumerated(){dock.append(ReadyShellTarget(id:"section:"+item.rawValue,kind:.section,label:item.title,subtitle:nil,rect:[0.0125,0.70+Double(index)*0.08,0.045,0.065],enabled:true,symbol:item.symbol))}
    return Self(pageId:section.rawValue,title:header ?? section.title,viewportNormalized:[0.10,0.14,0.85,0.76],navigationTargets:[],dockTargets:dock,selectedTargetId:"section:"+section.rawValue,contentRows:[],pageOffset:0,totalRows:0,footerError:error?.isEmpty == false ? error:nil,activeGameIds:runningGames.map(\.id),resumeActionId:runningGames.first.map{"resume:"+$0.id})
  }
}
/// Units are points for the normal shell. The injected renderer should scale
/// these proportions to its drawable, not create a second UI surface.
enum ReadyShellStyle {
  static let dockWidth:Double=72
  static let dockButtonSize:Double=46
  static let dockButtonX:Double=13
  static let dockFirstY:Double=72
  static let dockItemStride:Double=57
  static let contentLeft:Double=112
  static let headerHeight:Double=82
  static let footerHeight:Double=52
  static let transitionSeconds:Double=0.18
  static let gameDimOpacity:Double=0.10
}

/// Only a current application's icon is eligible; no library thumbnails,
/// network fetches or retained global image cache are introduced here.
enum ReadyActiveGameIcon {
  static func image(forExecutable raw:String?)->NSImage? {
    guard let raw,raw.hasPrefix("/") else{return nil}
    var url=URL(fileURLWithPath:raw)
    if url.pathExtension.lowercased() != "app" {
      guard let app=url.pathComponents.indices.reversed().first(where:{url.pathComponents[$0].lowercased().hasSuffix(".app")}) else{return nil}
      url=URL(fileURLWithPath:NSString.path(withComponents:Array(url.pathComponents.prefix(app+1))))
    }
    return NSWorkspace.shared.icon(forFile:url.path)
  }
  static func pngBase64(forExecutable raw:String?)->String? {
    autoreleasepool {
      guard let icon=image(forExecutable:raw) else{return nil}
      for size in [64,32] {
        guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:size*4,bitsPerPixel:32),let context=NSGraphicsContext(bitmapImageRep:bitmap) else{continue}
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
        icon.draw(in:NSRect(x:0,y:0,width:size,height:size),from:.zero,operation:.copy,fraction:1,respectFlipped:false,hints:[.interpolation:NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
        if let data=bitmap.representation(using:.png,properties:[:]),data.count<=12*1024{return data.base64EncodedString()}
      }
      return nil
    }
  }
}
