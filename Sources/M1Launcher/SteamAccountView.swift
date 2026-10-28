// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CoreImage

/// Content of the launcher's own dialog; never creates a system panel/window.
@MainActor
final class SteamAccountView: NSView, ReadyDialogContentSizing {
  nonisolated var maximumViewportHeight: CGFloat { 580 }
  var onQRLogin: (() -> Void)?
  var onPasswordLogin: ((String, String) -> Void)?
  var onGuard: ((String) -> Void)?
  var onPresence: ((String) -> Void)?
  var onReconnect: (() -> Void)?
  var onOffline: (() -> Void)?
  var onLogout: (() -> Void)?
  var onDisplayName: ((String)->Void)?
  var onFriendAction: ((String,String)->Void)?
  private let identity = NSTextField(labelWithString: "Steam")
  private let status = NSTextField(wrappingLabelWithString: "Non connesso")
  private let account = NSTextField()
  private let password = NSSecureTextField()
  private let guardCode = NSSecureTextField()
  private let qr = NSImageView()
  private let friendText = NSTextView()
  private let presence = NSPopUpButton()
  private let publicName = NSTextField()
  private let friendID = NSTextField()
  private let friendPicker=NSPopUpButton()
  private let qrHost = NSView()
  private let friendScroll = NSScrollView()
  private let form = NSStackView()
  private let choices = ["online", "away", "busy", "invisible"]
  private var lastState = SteamClientState()
  private var armedFriendAction:(String,String,Date)?
  private var actionNotice:(String,Date)?
  private var measuringContent=false
  private var layoutScheduled=false
  private weak var layoutFocus:NSView?

  override init(frame: NSRect) {
    super.init(frame: frame)
    identity.font = .systemFont(ofSize: 20, weight: .semibold)
    identity.cell?.lineBreakMode = .byTruncatingTail
    status.font = .systemFont(ofSize: 13)
    account.placeholderString = "Nome account Steam (diverso dal nome pubblico)"
    password.placeholderString = "Password · usata solo per questo accesso"
    guardCode.placeholderString = "Codice Steam Guard"
    publicName.placeholderString = "Nome pubblico Steam"
    friendID.placeholderString = "SteamID64 dell’amico"
    qr.imageScaling = .scaleProportionallyUpOrDown
    qrHost.addSubview(qr); qrHost.isHidden = true
    presence.addItems(withTitles: ["Online", "Assente", "Occupato", "Invisibile"])
    presence.target = self; presence.action = #selector(presenceChanged)
    friendPicker.target=self;friendPicker.action = #selector(selectFriend)
    let login = row([button("Accedi con QR", #selector(qrLogin)), button("Accedi con password", #selector(passwordLogin))])
    let presenceRow = row([presence, button("Riconnetti", #selector(reconnect))])
    let sessionRow = row([button("Modalità offline", #selector(offline)), button("Esci dall’account", #selector(logout))])
    let connection = NSStackView(views: [presenceRow, sessionRow])
    connection.orientation = .vertical; connection.alignment = .leading; connection.spacing = 8
    let guardRow = row([guardCode, button("Conferma codice", #selector(sendGuard))])
    let nameAction = button("Aggiorna nome pubblico",#selector(rename))
    let friendActions = row([button("Aggiungi",#selector(addFriend)),button("Rimuovi",#selector(removeFriend)),button("Blocca",#selector(blockFriend)),button("Sblocca",#selector(unblockFriend))])
    friendActions.distribution = .fillEqually
    guardRow.identifier = NSUserInterfaceItemIdentifier("steam.guard"); guardRow.isHidden = true
    friendText.isEditable = false; friendText.isSelectable = true
    friendText.frame = NSRect(x:0,y:0,width:660,height:150)
    friendText.isVerticallyResizable = true
    friendText.autoresizingMask = [.width]
    friendText.textContainer?.widthTracksTextView = true
    friendText.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    friendText.backgroundColor = .clear
    friendScroll.documentView = friendText; friendScroll.hasVerticalScroller = true
    friendScroll.drawsBackground = false
    form.orientation = .vertical; form.alignment = .leading; form.spacing = 9
    for view in [identity, status, connection, publicName, nameAction, account, password, login, guardRow, qrHost, NSTextField(labelWithString: "Amici e attività"), friendPicker, friendID, friendActions, friendScroll] { form.addArrangedSubview(view) }
    addSubview(form)
    form.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([form.leadingAnchor.constraint(equalTo: leadingAnchor), form.trailingAnchor.constraint(equalTo: trailingAnchor), form.topAnchor.constraint(equalTo: topAnchor), form.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)])
    for view in [identity, status, account, password, login, connection, publicName, nameAction, friendPicker, friendID, friendActions, guardRow, friendScroll, qrHost] {
      view.translatesAutoresizingMaskIntoConstraints = false
      view.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
    }
    for view in [presenceRow, sessionRow] {
      view.translatesAutoresizingMaskIntoConstraints = false
      view.widthAnchor.constraint(equalTo: connection.widthAnchor).isActive = true
    }
    friendScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
    qrHost.heightAnchor.constraint(equalToConstant: 260).isActive = true
    qr.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([qr.centerXAnchor.constraint(equalTo: qrHost.centerXAnchor), qr.topAnchor.constraint(equalTo: qrHost.topAnchor), qr.widthAnchor.constraint(equalToConstant: 250), qr.heightAnchor.constraint(equalToConstant: 250)])
    resizeDialogContent()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
  override func setFrameSize(_ newSize:NSSize) {
    let changed=abs(newSize.width-frame.width)>0.5
    super.setFrameSize(newSize)
    if changed{resizeDialogContent()}
  }
  private func resizeDialogContent(focus:NSView?=nil) {
    if let focus{layoutFocus=focus}
    guard !layoutScheduled else{return};layoutScheduled=true
    DispatchQueue.main.async{[weak self] in
      guard let self else{return}
      self.layoutScheduled=false
      let focus=self.layoutFocus;self.layoutFocus=nil
      self.measureDialogContent(focus:focus)
    }
  }
  private func measureDialogContent(focus:NSView?) {
    guard !measuringContent,form.superview===self,bounds.width>0 else{return}
    measuringContent=true
    status.preferredMaxLayoutWidth=bounds.width
    layoutSubtreeIfNeeded()
    let height=ceil(form.fittingSize.height)
    if height>0,abs(height-frame.height)>0.5{super.setFrameSize(NSSize(width:frame.width,height:height))}
    layoutSubtreeIfNeeded()
    measuringContent=false
    NotificationCenter.default.post(name:.readyDialogContentLayoutChanged,object:self,userInfo:focus.map{["focus":$0]})
  }
  private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title:title,target:self,action:action) }
  private func row(_ views: [NSView]) -> NSStackView {
    let view = NSStackView(views: views); view.orientation = .horizontal; view.spacing = 8
    return view
  }
  @objc private func qrLogin() { password.stringValue = ""; onQRLogin?() }
  @objc private func passwordLogin() {
    let secret = password.stringValue; password.stringValue = ""
    guard !account.stringValue.isEmpty, !secret.isEmpty else { status.stringValue = "Inserisci nome account e password, oppure usa il QR."; resizeDialogContent(focus:status);return }
    onPasswordLogin?(account.stringValue, secret)
  }
  @objc private func sendGuard() { let code = guardCode.stringValue; guardCode.stringValue = ""; if !code.isEmpty { onGuard?(code) } }
  @objc private func presenceChanged() { if choices.indices.contains(presence.indexOfSelectedItem) { onPresence?(choices[presence.indexOfSelectedItem]) } }
  @objc private func reconnect() { onReconnect?() }
  @objc private func offline() { onOffline?() }
  @objc private func logout() { qr.image = nil; qrHost.isHidden = true; password.stringValue = ""; guardCode.stringValue = "";resizeDialogContent();onLogout?() }
  @objc private func rename(){let name=publicName.stringValue.trimmingCharacters(in:.whitespacesAndNewlines);if !name.isEmpty{onDisplayName?(name)}}
  @objc private func addFriend(){onFriendAction?("add_friend",friendID.stringValue)}
  @objc private func selectFriend(){let index=friendPicker.indexOfSelectedItem;if lastState.friends.indices.contains(index){friendID.stringValue=lastState.friends[index].id}}
  private func confirmFriend(_ action:String) {
    let id=friendID.stringValue
    if let armed=armedFriendAction,armed.0==action,armed.1==id,Date().timeIntervalSince(armed.2)<8 {armedFriendAction=nil;onFriendAction?(action,id)}
    else {armedFriendAction=(action,id,Date());status.stringValue=action=="block_friend" ? "Premi di nuovo Blocca entro 8 secondi per confermare." : "Premi di nuovo Rimuovi entro 8 secondi per confermare.";resizeDialogContent(focus:status)}
  }
  @objc private func removeFriend(){confirmFriend("remove_friend")}
  @objc private func blockFriend(){confirmFriend("block_friend")}
  @objc private func unblockFriend(){onFriendAction?("unblock_friend",friendID.stringValue)}
  func update(_ state: SteamClientState) {
    let oldDisplayName=lastState.displayName
    lastState = state
    if publicName.currentEditor()==nil&&(publicName.stringValue.isEmpty||publicName.stringValue==oldDisplayName){publicName.stringValue=state.displayName}
    let selectedID=friendID.stringValue
    friendPicker.removeAllItems();friendPicker.addItems(withTitles:state.friends.map{$0.displayName.isEmpty ? $0.id:$0.displayName})
    if let index=state.friends.firstIndex(where:{$0.id==selectedID}){friendPicker.selectItem(at:index)}
    identity.stringValue = state.displayName.isEmpty ? "Steam" : state.displayName
    let names = ["online":"Connesso", "connecting":"Connessione a Steam…", "authenticating":"Attesa autorizzazione Steam…", "reconnecting":"Riconnessione dopo perdita della rete…", "offline":"Offline", "authorization_required":"Accesso Steam richiesto", "logged_out":"Account disconnesso"]
    var detail = names[state.connection] ?? "Steam"
    if !state.accountName.isEmpty { detail += " · Account: " + state.accountName }
    if ["logged_in_elsewhere","session_replaced","remote_logout"].contains(state.reason) { detail += "\nLa sessione è stata chiusa da Steam o da un altro accesso. Premi Riconnetti per riprovare." }
    if ["revoked","expired","invalid_password"].contains(state.reason) { detail += "\nSteam richiede una nuova autorizzazione." }
    if !state.warning.isEmpty{detail += "\n"+state.warning}
    if let notice=actionNotice,Date().timeIntervalSince(notice.1)<15{detail += "\n"+notice.0}
    status.stringValue = detail
    if let index = choices.firstIndex(of: state.presence) { presence.selectItem(at:index) }
    if state.connection != "authenticating" { qrHost.isHidden = true; qr.image = nil; form.arrangedSubviews.first(where: { $0.identifier?.rawValue == "steam.guard" })?.isHidden = true }
    friendText.string = state.friends.sorted { left, right in
      if (left.presence == "offline") != (right.presence == "offline") { return left.presence != "offline" }
      return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
    }.map { friend in
      let activity = friend.gameName ?? friend.gameID.map { "Gioco \($0)" } ?? friend.presence
      let relations=["Blocked":"Bloccato","RequestRecipient":"Richiesta ricevuta","RequestInitiator":"Richiesta inviata","Ignored":"Ignorato","IgnoredFriend":"Ignorato"]
      return "\(friend.displayName.isEmpty ? friend.id : friend.displayName)  ·  \(relations[friend.relationship] ?? activity)"
    }.joined(separator:"\n")
    if !state.online && !state.friends.isEmpty {friendText.string="Ultimo stato noto · connessione Steam non attiva\n\n"+friendText.string}
    if state.friends.isEmpty { friendText.string = state.online ? "Nessun amico disponibile." : "Gli amici saranno aggiornati quando Steam sarà connesso." }
    resizeDialogContent()
  }
  func authenticationEvent(_ event: [String: Any]) {
    switch event["type"] as? String {
    case "qr":
      guard let value = event["url"] as? String, value.utf8.count <= 8192, let url = URL(string:value), url.scheme == "https",
        let filter = CIFilter(name:"CIQRCodeGenerator") else { return }
      filter.setValue(Data(value.utf8), forKey:"inputMessage")
      guard let image = filter.outputImage?.transformed(by:CGAffineTransform(scaleX:8,y:8)), let cg = CIContext(options:[.useSoftwareRenderer:true]).createCGImage(image,from:image.extent) else { return }
      qr.image = NSImage(cgImage:cg,size:NSSize(width:250,height:250)); qrHost.isHidden = false
      form.arrangedSubviews.first(where:{$0.identifier?.rawValue=="steam.guard"})?.isHidden=true
      status.stringValue = "Scansiona questo QR con l’app Steam. L’accesso verrà salvato solo nel profilo selezionato."
      resizeDialogContent(focus:qrHost)
    case "guard":
      qr.image = nil; qrHost.isHidden = true
      let method=event["method"]as?String ?? "device_code"
      status.stringValue = method=="device_confirmation" ? "Approva l’accesso nell’app Steam del telefono." : method=="email" ? "Inserisci il codice Steam Guard ricevuto per email." : "Inserisci il codice dell’autenticatore Steam Guard."
      let row=form.arrangedSubviews.first(where: { $0.identifier?.rawValue == "steam.guard" })
      row?.isHidden = event["challengeID"]==nil
      resizeDialogContent(focus:event["challengeID"]==nil ? status:row)
    case "error": status.stringValue = "Accesso non riuscito: " + (event["code"] as? String ?? "steam_error");resizeDialogContent(focus:status)
    default: break
    }
  }
  func actionEvent(_ event:[String:Any]) {
    if event["type"]as?String=="error"{actionNotice=("Steam non ha completato l’operazione: "+(event["code"]as?String ?? "steam_error"),Date())}
    else if event["pending"]as?Bool==true{actionNotice=("Richiesta inviata; conferma di Steam ancora in attesa.",Date())}
    else if event["serverAcknowledged"]as?Bool==true{actionNotice=("Operazione confermata da Steam. La relazione mostrata nella lista resta quella ricevuta dal server.",Date())}
    update(lastState)
  }
}
