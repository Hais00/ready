// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import LauncherCore

struct GameInstallationOption {
  let id:UUID,title:String,path:String,availableBytes:UInt64
  let usable:Bool,issue:String?
}
@MainActor final class GameInstallationView:NSView,ReadyDialogContentSizing {
  var maximumViewportHeight:CGFloat{620}
  var onInstall:(()->Void)?,onManage:(()->Void)?,onCancel:(()->Void)?,onPlan:(()->Void)?,onLibraryChanged:((UUID)->Void)?
  private let heading=NSTextField(wrappingLabelWithString:""),version=NSTextField(labelWithString:"")
  private let size=NSTextField(wrappingLabelWithString:"Calcolo delle dimensioni…"),path=NSTextField(wrappingLabelWithString:"")
  private let status=NSTextField(wrappingLabelWithString:""),picker=NSPopUpButton(frame:.zero,pullsDown:false)
  private var install:NSButton!,manage:NSButton!,cancel:NSButton!,plan:NSButton!
  private var options=[GameInstallationOption](),selected:UUID?
  private weak var controllerControl:NSControl?
  private(set) var info=GameStorageInfo()
  var selectedLibraryID:UUID?{selected}
  init(game:Game,variant:GameVariant){
    super.init(frame:NSRect(x:0,y:0,width:600,height:430));heading.stringValue=LibraryEntryPresentation.title(game);heading.font = .systemFont(ofSize:25,weight:.bold)
    version.stringValue=variant.platform == .macOS ? "Versione macOS":"Versione Windows";version.font = .systemFont(ofSize:14,weight:.semibold)
    for label in [size,path,status]{label.font = .systemFont(ofSize:13);label.textColor = .secondaryLabelColor}
    path.isSelectable=true;status.textColor = .systemOrange
    picker.target=self;picker.action=#selector(changed);picker.font = .systemFont(ofSize:14)
    install=action("Installa",#selector(start));manage=action("Gestisci cartelle…",#selector(manageLibraries));cancel=action("Indietro",#selector(back));plan=action("Ricalcola dimensione",#selector(replan))
    install.isEnabled=false
    for view in [heading,version,size,picker,path,status,install,plan,manage,cancel]as[NSView]{addSubview(view)}
  }
  required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
  private func action(_ title:String,_ selector:Selector)->NSButton{let b=NSButton(title:title,target:self,action:selector);b.bezelStyle = .rounded;b.font = .systemFont(ofSize:14,weight:.semibold);return b}
  func update(options:[GameInstallationOption],selected:UUID?,info:GameStorageInfo,loading:Bool,message:String?=nil,canInstall:Bool=true,authorizationRequired:Bool=false){
    self.options=options;self.info=info;self.selected=options.first(where:{$0.id==selected})?.id ?? options.first(where:{$0.usable})?.id
    picker.removeAllItems()
    for option in options{picker.addItem(withTitle:option.title);picker.lastItem?.representedObject=option.id}
    if let id=self.selected,let i=options.firstIndex(where:{$0.id==id}){picker.selectItem(at:i)}
    picker.isEnabled = !options.isEmpty;manage.isEnabled=true;cancel.isEnabled=true
    var lines=[String]()
    if let bytes=info.installedBytes{lines.append((info.verified ? "Installazione: ":"Installazione stimata: ")+Self.bytes(bytes))}
    if let bytes=info.downloadBytes{lines.append("Download: "+Self.bytes(bytes))}
    if let bytes=info.requiredBytes,info.installedBytes==nil{lines.append("Spazio richiesto dal negozio: "+Self.bytes(bytes))}
    if lines.isEmpty{lines.append(loading ? "Calcolo delle dimensioni…":"Dimensione non disponibile per questa versione")}
    size.stringValue=lines.joined(separator:"\n")
    let chosen=options.first{$0.id==self.selected}
    path.stringValue=chosen.map{$0.path+"\n"+Self.bytes($0.availableBytes)+" disponibili per nuove installazioni"} ?? "Configura una cartella giochi in Impostazioni → Archiviazione."
    let enough=chosen.map{item in info.reservationBytes.map{$0<=item.availableBytes} ?? false} ?? false
    let reason=message ?? chosen?.issue ?? (!loading && info.reservationBytes==nil ? "Lo store deve fornire il piano prima di prenotare lo spazio.":(!loading && !enough && chosen != nil ? "Spazio disponibile insufficiente.":""))
    status.stringValue=reason
    install.isEnabled = !loading && canInstall && chosen?.usable==true && enough
    plan.title=authorizationRequired ? "Accedi allo store":"Ricalcola dimensione";plan.isEnabled = !loading
    needsLayout=true
    NotificationCenter.default.post(name:.readyDialogContentLayoutChanged,object:self)
  }
  func setWorking(_ text:String){status.stringValue=text;install.isEnabled=false;plan.isEnabled=false;manage.isEnabled=false;picker.isEnabled=false;controllerControl=cancel;window?.makeFirstResponder(cancel)}
  private static func bytes(_ value:UInt64)->String{ByteCountFormatter.string(fromByteCount:Int64(min(value,UInt64(Int64.max))),countStyle:.file)}
  @objc private func changed(){selected=picker.selectedItem?.representedObject as?UUID;if let selected{onLibraryChanged?(selected)}}
  @objc private func start(){if install.isEnabled{onInstall?()}}
  @objc private func manageLibraries(){onManage?()}
  @objc private func back(){onCancel?()}
  @objc private func replan(){onPlan?()}
  func handleController(_ action:ControllerNavigation.Action)->Bool{
    if action == .cancel{onCancel?();return true}
    let controls:[NSControl]=[picker,install,plan,manage,cancel].filter{$0.isEnabled}
    guard !controls.isEmpty else{return true}
    var focus=controls.firstIndex(where:{$0===controllerControl}) ?? controls.firstIndex(where:{$0===window?.firstResponder}) ?? 0
    if case .move(let direction)=action{
      if controls[focus]===picker,(direction == .left || direction == .right),picker.numberOfItems>0{
        let delta=direction == .left ? -1:1;picker.selectItem(at:(picker.indexOfSelectedItem+delta+picker.numberOfItems)%picker.numberOfItems);changed()
      }else{focus=max(0,min(controls.count-1,focus+(direction == .up || direction == .left ? -1:1)))}
      controllerControl=controls[focus];window?.makeFirstResponder(controls[focus]);_=controls[focus].scrollToVisible(controls[focus].bounds);return true
    }
    if action == .activate{if controls[focus]===picker{return true};(controls[focus]as?NSButton)?.performClick(nil);return true}
    return false
  }
  override var isFlipped:Bool{true}
  override func layout(){
    super.layout();let width=max(240,bounds.width);var y:CGFloat=0
    func label(_ v:NSTextField,_ height:CGFloat){v.frame=NSRect(x:0,y:y,width:width,height:height);y+=height+16}
    label(heading,64);label(version,24);label(size,70);picker.frame=NSRect(x:0,y:y,width:width,height:34);y+=50;label(path,65);label(status,52)
    install.frame=NSRect(x:0,y:y,width:min(180,width),height:42);y+=54
    plan.frame=NSRect(x:0,y:y,width:min(230,width),height:36);y+=46
    manage.frame=NSRect(x:0,y:y,width:min(220,width),height:36);cancel.frame=NSRect(x:max(0,width-120),y:y,width:120,height:36);y+=48
    if abs(frame.height-y)>1{setFrameSize(NSSize(width:frame.width,height:y));NotificationCenter.default.post(name:.readyDialogContentLayoutChanged,object:self)}
  }
}
