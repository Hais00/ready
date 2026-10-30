// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import LauncherCore

@MainActor final class StorageSettingsView:NSView,ReadyDialogContentSizing {
  var maximumViewportHeight:CGFloat{680}
  var onRename:((StorageLibraryRecord)->Void)?,onDefault:((StorageLibraryRecord)->Void)?,onRemove:((StorageLibraryRecord)->Void)?
  private let stack=NSStackView()
  override init(frame:NSRect){
    super.init(frame:frame);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=14
    stack.translatesAutoresizingMaskIntoConstraints=false;addSubview(stack)
    NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:leadingAnchor),stack.trailingAnchor.constraint(equalTo:trailingAnchor),stack.topAnchor.constraint(equalTo:topAnchor),stack.bottomAnchor.constraint(equalTo:bottomAnchor)])
    setMessage("Controllo delle cartelle e dei volumi…")
  }
  required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
  private func clear(){for view in stack.arrangedSubviews{stack.removeArrangedSubview(view);view.removeFromSuperview()}}
  private func label(_ text:String,size:CGFloat=13,bold:Bool=false)->NSTextField{let v=NSTextField(wrappingLabelWithString:text);v.font = .systemFont(ofSize:size,weight:bold ? .semibold:.regular);v.textColor = .labelColor;v.setContentCompressionResistancePriority(.defaultLow,for:.horizontal);return v}
  func setMessage(_ text:String){clear();let line=label(text);stack.addArrangedSubview(line);line.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true;resized()}
  func update(_ statuses:[StorageLibraryStatus]){
    clear()
    if statuses.isEmpty{setMessage("Nessuna cartella giochi configurata. Aggiungi una cartella esistente: i file presenti non verranno spostati o cancellati.");return}
    for status in statuses {
      let record=status.library,row=NSStackView();row.orientation = .vertical;row.alignment = .leading;row.spacing=7
      let title=label(record.name+(status.isDefault ? " · Predefinita":""),size:17,bold:true)
      let path=label(record.rootPath);path.textColor = .secondaryLabelColor
      let availability:String
      switch status.availability {
      case .online:availability="Disponibile"
      case .offline:availability="Volume non collegato"
      case .changedVolume:availability="Volume o cartella cambiati"
      case .readOnly:availability="Sola lettura"
      case .unavailable:availability="Cartella non disponibile"
      }
      let capacity=ByteCountFormatter.string(fromByteCount:Int64(min(status.freeBytes,UInt64(Int64.max))),countStyle:.file)+" liberi di "+ByteCountFormatter.string(fromByteCount:Int64(min(status.totalBytes,UInt64(Int64.max))),countStyle:.file)
      var detail=availability
      if status.availability == .online || status.availability == .readOnly {detail += " · "+capacity}
      if status.reservedBytes>0{detail += "\n"+ByteCountFormatter.string(fromByteCount:Int64(min(status.reservedBytes,UInt64(Int64.max))),countStyle:.file)+" prenotati dalle installazioni sul volume"}
      if status.unplannedReservations>0{detail += "\nInstallazioni in attesa del calcolo dello spazio: \(status.unplannedReservations)"}
      let description=label(detail)
      let bar=NSProgressIndicator();bar.isIndeterminate=false;bar.minValue=0;bar.maxValue=1
      bar.doubleValue=status.totalBytes>0 ? Double(status.totalBytes-status.freeBytes)/Double(status.totalBytes):0;bar.style = .bar
      let buttons=NSStackView();buttons.orientation = .horizontal;buttons.spacing=10
      for (index,text) in ["Rinomina","Predefinita","Rimuovi voce"].enumerated(){
        let button=StorageRowButton(title:text,action:{[weak self]in
          if index==0{self?.onRename?(record)}else if index==1{self?.onDefault?(record)}else{self?.onRemove?(record)}
        });button.isEnabled=index != 1 || !status.isDefault;buttons.addArrangedSubview(button)
      }
      for child in [title,path,description,bar,buttons]as[NSView]{row.addArrangedSubview(child)}
      stack.addArrangedSubview(row);row.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true
      for child in [title,path,description,bar]{child.widthAnchor.constraint(equalTo:row.widthAnchor).isActive=true}
      bar.heightAnchor.constraint(equalToConstant:8).isActive=true
    }
    resized()
  }
  private func resized(){needsLayout=true;NotificationCenter.default.post(name:.readyDialogContentLayoutChanged,object:self)}
}
@MainActor private final class StorageRowButton:NSButton {
  private let invoke:()->Void
  init(title:String,action:@escaping()->Void){invoke=action;super.init(frame:.zero);self.title=title;bezelStyle = .rounded;target=self;self.action=#selector(clicked);font = .systemFont(ofSize:12,weight:.medium)}
  required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
  @objc private func clicked(){invoke()}
}

extension AppDelegate {
  @MainActor func showStorageSettings(returnToGameID:String?=nil,onReturn:(()->Void)?=nil){
    guard !maintenanceInProgress,session?.running != true,pendingLaunch==nil else{return}
    beginSettingsSection(.storage)
    var returned=false
    let leave:()->Void = {[weak self]in
      guard !returned else{return};returned=true
      if let onReturn{onReturn()}else if let returnToGameID{self?.showGameDetails(id:returnToGameID)}else{self?.settings()}
    }
    if onReturn != nil || returnToGameID != nil {
      pages.configureNavigation(title:"Impostazioni",tabs:[SettingsPageSection.overview,.accounts,.storage,.runtime,.data,.evaluation].map{item in
        ReadyPageTab(id:item.rawValue,title:item.title,action:{[weak self]in self?.openSettingsSection(item)})
      },selected:SettingsPageSection.storage.rawValue,onBack:leave)
    }
    let view=StorageSettingsView(frame:NSRect(x:0,y:0,width:600,height:220))
    let reload={ [weak self] in self?.showStorageSettings(returnToGameID:returnToGameID,onReturn:onReturn) }
    view.onRename={[weak self]record in
      guard let self else{return}
      let input=NSTextField(string:record.name);input.frame=NSRect(x:0,y:0,width:440,height:30)
      self.presentDialog(title:"Nome della cartella giochi",message:"Cambia soltanto il nome mostrato in Ready.",content:input,
        actions:[.init("Salva",role:.primary),.init("Annulla",role:.cancel)]){[weak self]choice in
        if choice==0{let name=input.stringValue;self?.changeStorage(returnToGameID:returnToGameID,onReturn:onReturn){try $0.rename(id:record.id,name:name)}}else{reload()}
      }
    }
    view.onDefault={[weak self]record in self?.changeStorage(returnToGameID:returnToGameID,onReturn:onReturn){try $0.setDefault(id:record.id)}}
    view.onRemove={[weak self]record in
      self?.presentDialog(title:"Rimuovere questa voce?",message:"I giochi e tutti i file della cartella rimarranno sul disco. Le installazioni in corso impediscono la rimozione.",
        actions:[.init("Rimuovi voce",role:.destructive),.init("Annulla",role:.cancel)]){[weak self]choice in
        if choice==0{self?.changeStorage(returnToGameID:returnToGameID,onReturn:onReturn){try $0.remove(id:record.id)}}else{reload()}
      }
    }
    let page=presentDialog(title:"Archiviazione",message:"I file dei giochi sono condivisi tra profili. Prefix Windows e salvataggi personali mantengono le proprie cartelle separate.",content:view,
      actions:[.init("Aggiungi cartella…",role:.primary),.init("Indietro")]){[weak self]choice in
      guard let self else{return}
      if choice==0{
        self.selectLocalFile(title:"Aggiungi una cartella giochi",prompt:"Usa questa cartella",directory:FileManager.default.homeDirectoryForCurrentUser,mode:.directory){[weak self]root in
          guard let self else{return};guard let root else{reload();return}
          self.changeStorage(returnToGameID:returnToGameID,onReturn:onReturn){_=try $0.add(root:root)}
        }
      }else if choice==1{leave()}
    }
    let repository=storageLibraries
    DispatchQueue.global(qos:.utility).async{
      let result=Result{try repository.list()}
      DispatchQueue.main.async{[weak self,weak view]in
        MainActor.assumeIsolated{
          guard let self,self.pages.isShowing(page),let view else{return}
          switch result{case .success(let statuses):view.update(statuses);case .failure(let error):view.setMessage(error.localizedDescription)}
        }
      }
    }
  }
  @MainActor private func changeStorage(returnToGameID:String?,onReturn:(()->Void)?,_ change:@escaping(StorageLibraryRepository)throws->Void){
    guard !maintenanceInProgress,session?.running != true,pendingLaunch==nil else{return}
    let repository=storageLibraries
    DispatchQueue.global(qos:.utility).async{
      let result=Result{try change(repository)}
      DispatchQueue.main.async{[weak self]in MainActor.assumeIsolated{
        guard let self else{return}
        self.showStorageSettings(returnToGameID:returnToGameID,onReturn:onReturn)
        if case .failure(let error)=result{self.showError(error)}
      }}
    }
  }
}
