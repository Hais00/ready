// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import LauncherCore

enum ReadyDialogRole{case normal,primary,cancel,destructive}
struct ReadyDialogAction{init(_ title:String,role:ReadyDialogRole = .normal){}}
protocol ReadyDialogContentSizing{var maximumViewportHeight:CGFloat{get}}
extension Notification.Name{static let readyDialogContentLayoutChanged=Notification.Name("ready.dialog.content-layout-changed")}
enum SettingsPageSection:String{case overview,accounts,storage,runtime,data,evaluation;var title:String{rawValue}}
struct ReadyPageTab{let id:String,title:String;let action:()->Void}
enum FileSelectionMode{case directory}
final class FixtureSession{var running=false}
final class FixturePages{func isShowing(_ id:UUID)->Bool{true};func configureNavigation(title:String,tabs:[ReadyPageTab],selected:String?,onBack:(()->Void)?=nil){}}
final class AppDelegate{
  var maintenanceInProgress=false,session:FixtureSession?=FixtureSession(),pendingLaunch:UUID?
  let pages=FixturePages(),storageLibraries:StorageLibraryRepository
  init(_ repository:StorageLibraryRepository){storageLibraries=repository}
  func beginSettingsSection(_ section:SettingsPageSection){}
  func settings(){}
  func openSettingsSection(_ section:SettingsPageSection){}
  func presentDialog(title:String,message:String,content:NSView?=nil,actions:[ReadyDialogAction],completion:@escaping(Int)->Void)->UUID{UUID()}
  func showGameDetails(id:String){}
  func showError(_ error:Error){}
  func selectLocalFile(title:String,prompt:String,directory:URL,mode:FileSelectionMode,completion:@escaping(URL?)->Void){}
}
@main struct ReadyStorageSettingsProbe{
  @MainActor static func main()throws{
    _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    let root=URL(fileURLWithPath:CommandLine.arguments[1]).resolvingSymlinksInPath(),fm=FileManager.default
    let repo=StorageLibraryRepository(paths:LauncherPaths(root:root.appendingPathComponent("state")))
    for i in 0..<3{let p=root.appendingPathComponent("Own long library directory \(i)");try fm.createDirectory(at:p,withIntermediateDirectories:false);_=try repo.add(root:p,name:i==0 ? "Cartella predefinita con nome esteso":"Altra cartella \(i)")}
    let statuses=try repo.list();var checks=[String:Bool]()
    func children(_ view:NSView)->[NSView]{view.subviews+view.subviews.flatMap(children)}
    for width in [CGFloat(460),600]{
      let window=NSWindow(contentRect:NSRect(x:0,y:0,width:width,height:800),styleMask:[.titled],backing:.buffered,defer:false)
      let view=StorageSettingsView(frame:NSRect(x:0,y:0,width:width,height:800));window.contentView=view;view.update(statuses);view.layoutSubtreeIfNeeded()
      let buttons=children(view).compactMap{$0 as?NSButton},labels=children(view).compactMap{$0 as?NSTextField}
      checks["all-actions-visible-at-\(Int(width))"]=buttons.count==9 && buttons.allSatisfy{button in let r=button.convert(button.bounds,to:view);return r.width>0 && r.minX>=0 && r.maxX<=width+1}
      // NSTextField's transparent frame extends two points beyond its AppKit
      // alignment rect. Check the laid-out text/control area, not that margin.
      checks["wrapped-paths-fit-at-\(Int(width))"]=labels.count==9 && labels.allSatisfy{label in let r=label.superview!.convert(label.alignmentRect(forFrame:label.frame),to:view);return r.width>0 && r.height>0 && r.minX>=(-1) && r.maxX<=width+1}
      checks["default-action-disabled-only-for-default-at-\(Int(width))"]=buttons.filter{!$0.isEnabled}.count==1
      view.update([]);view.layoutSubtreeIfNeeded();checks["empty-state-removes-all-entry-controls-at-\(Int(width))"]=children(view).compactMap{$0 as?NSButton}.isEmpty && children(view).compactMap{$0 as?NSTextField}.count==1
    }
    let result:[String:Any]=["passed":checks.values.allSatisfy{$0},"count":checks.count,"checks":checks,"windowActivated":false,"accountOrUserLibrariesUsed":false]
    print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),as:UTF8.self));if !checks.values.allSatisfy({$0}){exit(1)}
  }
}
