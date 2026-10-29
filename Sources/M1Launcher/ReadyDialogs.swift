// SPDX-License-Identifier: GPL-3.0-only
import AppKit

// In-window, asynchronous UI. No nested AppKit modal loops or additional windows.
enum ReadyDialogRole { case normal, primary, cancel, destructive }
struct ReadyDialogAction {
  var title: String
  var role: ReadyDialogRole
  var enabled: Bool
  init(_ title: String, role: ReadyDialogRole = .normal, enabled: Bool = true) {
    self.title = title
    self.role = role
    self.enabled = enabled
  }
}
protocol ReadyDialogContentSizing {
  var maximumViewportHeight: CGFloat { get }
}
extension Notification.Name {
  /// Responsive content resized itself; optional focus is revealed only within
  /// that active dialog's existing scroll view.
  static let readyDialogContentLayoutChanged=Notification.Name("ready.dialog.content-layout-changed")
}
private func dialogColor(_ hex: Int, alpha: CGFloat = 1) -> NSColor {
  NSColor(
    srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
    blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
private final class DialogShade: NSView {
  override func mouseDown(with event: NSEvent) {}
  override func rightMouseDown(with event: NSEvent) {}
  override func scrollWheel(with event: NSEvent) {}
}
private final class DialogDocument: NSView { override var isFlipped: Bool { true } }
private final class DialogButton: NSButton {
  var role: ReadyDialogRole = .normal
  private var hover = false
  override var acceptsFirstResponder: Bool { isEnabled }
  override func becomeFirstResponder() -> Bool {
    needsDisplay = true
    return super.becomeFirstResponder()
  }
  override func resignFirstResponder() -> Bool {
    needsDisplay = true
    return super.resignFirstResponder()
  }
  override func updateTrackingAreas() {
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(
      NSTrackingArea(
        rect: bounds,
        options: [
          .mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect,
          .enabledDuringMouseDrag,
        ],
        owner: self, userInfo: nil))
    super.updateTrackingAreas()
  }
  override func mouseEntered(with event: NSEvent) {
    setPointerInside(true)
  }
  override func mouseExited(with event: NSEvent) {
    setPointerInside(false)
  }
  override func mouseMoved(with event: NSEvent) {
    updatePointer(event.locationInWindow)
  }
  override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
  func updatePointer(_ windowPoint: NSPoint) {
    setPointerInside(bounds.contains(convert(windowPoint, from: nil)))
  }
  private func setPointerInside(_ inside: Bool) {
    guard hover != inside else { return }
    hover = inside
    needsDisplay = true
  }
  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(bounds, cursor: isEnabled ? .pointingHand : .arrow)
  }
  override func draw(_ dirtyRect: NSRect) {
    let primary = role == .primary
    let rect = bounds.insetBy(dx: 1, dy: 1)
    let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
    let pressed = isEnabled && isHighlighted
    let hovered = isEnabled && hover
    let fill =
      primary
      ? (pressed ? 0x76cda0 : hovered ? 0xc5ffdc : 0xa2eec2)
      : (pressed ? 0x45625c : hovered ? 0x35484b : 0x263237)
    dialogColor(fill).withAlphaComponent(isEnabled ? 1 : 0.4).setFill()
    path.fill()
    if window?.firstResponder === self {
      dialogColor(0xc7ffe0).setStroke()
      path.lineWidth = 2
      path.stroke()
    }
    let color =
      primary ? dialogColor(0x10291f) : (role == .destructive ? dialogColor(0xffc5b4) : .white)
    let text = NSAttributedString(
      string: title,
      attributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
        .foregroundColor: color.withAlphaComponent(isEnabled ? 1 : 0.4),
      ])
    let size = text.size()
    text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
  }
}

final class ReadyDialogPresenter: NSObject {
  private struct Request {
    let id: UUID, title: String, message: String
    let content: NSView?
    var actions: [ReadyDialogAction]
    let onCancel: (() -> Void)?
    let completion: (Int) -> Void
  }
  private let windowProvider: () -> NSWindow?
  private var queue = [Request]()
  private var active: Request?
  private var shade: NSView?
  private var monitor: Any?
  private var contentLayoutObserver: NSObjectProtocol?
  private var buttons = [NSButton]()
  private weak var previousResponder: NSResponder?
  private var previousDefault: NSButtonCell?
  var isPresenting: Bool { active != nil || !queue.isEmpty }
  init(window: @escaping () -> NSWindow?) { windowProvider = window }
  @discardableResult func present(
    title: String, message: String, content: NSView?, actions: [ReadyDialogAction],
    onCancel: (() -> Void)? = nil, completion: @escaping (Int) -> Void
  ) -> UUID {
    precondition(Thread.isMainThread)
    let id = UUID()
    queue.append(
      Request(
        id: id, title: title, message: message, content: content, actions: actions,
        onCancel: onCancel, completion: completion))
    showNext()
    return id
  }
  func attach() { showNext() }
  func isShowing(_ id: UUID) -> Bool { active?.id == id }
  func activatePrimary(_ id: UUID) {
    guard active?.id == id else { return }
    buttons.first(where: { $0.keyEquivalent == "\r" && $0.isEnabled })?.performClick(nil)
  }
  /// Launch already excludes authentication. Release every dialog view and event
  /// monitor before the frontend releases its GPU resources; preserve messages.
  func detachForSession() -> [String] {
    let requests = active.map { [$0] } ?? []
    let notices = (requests + queue).filter { !$0.message.isEmpty }.map {
      $0.title + ": " + $0.message
    }
    queue.removeAll()
    if active != nil { finish(-1, notify: false) }
    return notices
  }
  func cancelCurrent() { cancel() }
  func setActionEnabled(_ id: UUID, index: Int, enabled: Bool) {
    if active?.id == id, buttons.indices.contains(index) {
      active?.actions[index].enabled = enabled
      buttons[index].isEnabled = enabled
      buttons[index].needsDisplay = true
      buttons[index].window?.invalidateCursorRects(for: buttons[index])
      windowProvider()?.defaultButtonCell =
        buttons.first(where: { $0.keyEquivalent == "\r" && $0.isEnabled })?.cell as? NSButtonCell
    } else if let request = queue.firstIndex(where: { $0.id == id }),
      queue[request].actions.indices.contains(index)
    {
      queue[request].actions[index].enabled = enabled
    }
  }
  func dismiss(_ id: UUID) {
    precondition(Thread.isMainThread)
    if active?.id == id { finish(-1, notify: false) } else { queue.removeAll { $0.id == id } }
  }
  private func showNext() {
    guard active == nil, !queue.isEmpty, let window = windowProvider(),
      let host = window.contentView
    else { return }
    let request = queue.removeFirst()
    active = request
    (host as? MetalCanvas)?.interactionEnabled = false
    previousResponder = window.firstResponder
    previousDefault = window.defaultButtonCell
    let shade = DialogShade(frame: host.bounds)
    shade.autoresizingMask = [.width, .height]
    shade.wantsLayer = true
    shade.layer?.backgroundColor = dialogColor(0x070b0c, alpha: 0.84).cgColor
    shade.appearance = NSAppearance(named: .darkAqua)
    host.addSubview(shade)
    self.shade = shade
    let card = NSView()
    card.wantsLayer = true
    card.layer?.backgroundColor = dialogColor(0x1b2529).cgColor
    card.layer?.cornerRadius = 18
    card.layer?.borderWidth = 1
    card.layer?.borderColor = dialogColor(0x40534f).cgColor
    card.translatesAutoresizingMaskIntoConstraints = false
    shade.addSubview(card)
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(stack)
    NSLayoutConstraint.activate([
      card.centerXAnchor.constraint(equalTo: shade.centerXAnchor),
      card.centerYAnchor.constraint(equalTo: shade.centerYAnchor),
      card.widthAnchor.constraint(equalToConstant: min(620, max(400, host.bounds.width - 64))),
      stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
      stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -22),
    ])
    let brand = NSTextField(labelWithString: "ready")
    brand.font = .systemFont(ofSize: 12, weight: .bold)
    brand.textColor = dialogColor(0xa2eec2)
    brand.translatesAutoresizingMaskIntoConstraints = false
    stack.addArrangedSubview(brand)
    let title = NSTextField(wrappingLabelWithString: request.title)
    title.font = .systemFont(ofSize: 25, weight: .bold)
    title.textColor = .white
    title.translatesAutoresizingMaskIntoConstraints = false
    stack.addArrangedSubview(title)
    let width = min(620, max(400, host.bounds.width - 64)) - 48
    title.widthAnchor.constraint(equalToConstant: width).isActive = true
    let message = NSTextField(wrappingLabelWithString: request.message)
    message.font = .systemFont(ofSize: 14)
    message.textColor = dialogColor(0xc3d0ce)
    message.isSelectable = true
    let measured = message.attributedStringValue.boundingRect(
      with: NSSize(width: width - 16, height: 4000),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    ).height
    if let content=request.content,content is ReadyDialogContentSizing {
      content.setFrameSize(NSSize(width:width-16,height:content.frame.height))
    }
    let contentHeight = request.content?.frame.height ?? 0
    let textHeight = request.message.isEmpty ? 0 : ceil(measured) + 8
    let totalHeight = textHeight + (contentHeight > 0 ? contentHeight + 12 : 0)
    if totalHeight > 0 {
      let scroll = NSScrollView()
      scroll.drawsBackground = false
      scroll.hasVerticalScroller = true
      scroll.autohidesScrollers = true
      let document = DialogDocument(
        frame: NSRect(x: 0, y: 0, width: width - 16, height: totalHeight))
      message.frame = NSRect(x: 0, y: 0, width: width - 16, height: textHeight)
      document.addSubview(message)
      if let content = request.content {
        if content is ReadyDialogContentSizing {
          // Responsive content must use the visible document width, rather
          // than retain the larger frame supplied before the card was sized.
          content.setFrameSize(NSSize(width: width - 16, height: content.frame.height))
          content.autoresizingMask.insert(.width)
        }
        content.frame.origin = NSPoint(x: 0, y: textHeight + 12)
        document.addSubview(content)
      }
      scroll.documentView = document
      scroll.translatesAutoresizingMaskIntoConstraints = false
      stack.addArrangedSubview(scroll)
      scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
      let maximumHeight =
        (request.content as? ReadyDialogContentSizing)?.maximumViewportHeight ?? 340
      let viewportHeight=scroll.heightAnchor.constraint(
        equalToConstant: min(
          totalHeight,
          max(
            60,
            min(maximumHeight, host.bounds.height - 64 - 128 - CGFloat(request.actions.count) * 52))
        )
      )
      viewportHeight.isActive = true
      if let content=request.content,content is ReadyDialogContentSizing {
        let requestID=request.id,actionCount=request.actions.count
        var refreshScheduled=false
        weak var pendingFocus:NSView?
        contentLayoutObserver=NotificationCenter.default.addObserver(forName:.readyDialogContentLayoutChanged,object:content,queue:.main) {
          [weak self,weak content,weak document,weak scroll,weak host,weak viewportHeight] notification in
          guard self?.active?.id==requestID else{return}
          if let focus=notification.userInfo?["focus"]as?NSView{pendingFocus=focus}
          guard !refreshScheduled else{return};refreshScheduled=true
          DispatchQueue.main.async{[weak self,weak content,weak document,weak scroll,weak host,weak viewportHeight] in
            refreshScheduled=false
            guard let self,self.active?.id==requestID,let content,let document,let scroll,let host,let viewportHeight else{return}
            let focus=pendingFocus;pendingFocus=nil
            content.setFrameSize(NSSize(width:width-16,height:content.frame.height))
            let height=max(0,content.frame.height),total=textHeight+(height>0 ? height+12:0)
            content.frame.origin=NSPoint(x:0,y:textHeight+12)
            document.setFrameSize(NSSize(width:width-16,height:total))
            viewportHeight.constant=min(total,max(60,min(maximumHeight,host.bounds.height-64-128-CGFloat(actionCount)*52)))
            host.layoutSubtreeIfNeeded()
            let constrained=scroll.contentView.constrainBoundsRect(scroll.contentView.bounds)
            scroll.contentView.scroll(to:constrained.origin)
            if let focus,focus===content||focus.isDescendant(of:content),!focus.isHiddenOrHasHiddenAncestor {
              _=document.scrollToVisible(document.convert(focus.bounds,from:focus).insetBy(dx:-8,dy:-8))
            }
            scroll.reflectScrolledClipView(scroll.contentView)
          }
        }
      }
    }
    buttons = request.actions.enumerated().map { index, action in
      let button = DialogButton(title: action.title, target: self, action: #selector(clicked(_:)))
      button.role = action.role
      button.isEnabled = action.enabled
      button.tag = index
      button.isBordered = false
      button.setButtonType(.momentaryPushIn)
      button.focusRingType = .none
      button.keyEquivalent =
        action.role == .cancel ? "\u{1b}" : (action.role == .primary ? "\r" : "")
      button.translatesAutoresizingMaskIntoConstraints = false
      stack.addArrangedSubview(button)
      button.widthAnchor.constraint(equalToConstant: width).isActive = true
      button.heightAnchor.constraint(equalToConstant: 36).isActive = true
      return button
    }
    if let primary = buttons.first(where: { $0.keyEquivalent == "\r" && $0.isEnabled }) {
      window.defaultButtonCell = primary.cell as? NSButtonCell
    } else {
      window.defaultButtonCell = nil
    }
    let controls = focusable(in: card)
    for (index, control) in controls.enumerated() {
      control.nextKeyView = controls[(index + 1) % controls.count]
    }
    let input = controls.first { $0 is NSPopUpButton || !($0 is NSButton) }
    let safeAction =
      buttons.first { $0.isEnabled && $0.keyEquivalent == "\r" }
      ?? buttons.first { $0.isEnabled && $0.keyEquivalent == "\u{1b}" }
      ?? buttons.first { button in
        button.isEnabled && request.actions[button.tag].role != .destructive
      }
    window.makeFirstResponder(input ?? safeAction)
    monitor = NSEvent.addLocalMonitorForEvents(matching: [
      .keyDown, .mouseMoved, .leftMouseDragged, .rightMouseDragged,
      .leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp,
    ]) { [weak self] event in
      guard let self, event.window === self.windowProvider(), self.active != nil else {
        return event
      }
      if event.type != .keyDown {
        // The shared Metal host and native controls use different tracking
        // paths. Keep button feedback coherent during motion, drag and click;
        // the original event still reaches its normal control unchanged.
        self.buttons.forEach { ($0 as? DialogButton)?.updatePointer(event.locationInWindow) }
        return event
      }
      if event.keyCode == 53 {
        self.cancel()
        return nil
      }
      if event.keyCode == 36 || event.keyCode == 76 {
        if let table = self.focusedControl() as? NSTableView, let action = table.doubleAction {
          _ = table.sendAction(action, to: table.target)
        } else if let field = self.focusedControl() as? NSTextField, let action = field.action,
          let target = field.target
        {
          _ = field.sendAction(action, to: target)
        } else {
          self.buttons.first(where: { $0.keyEquivalent == "\r" && $0.isEnabled })?.performClick(nil)
        }
        return nil
      }
      if event.keyCode == 48 {
        let current = self.focusedControl()
        let controls = self.shade.map { self.focusable(in: $0) } ?? []
        guard !controls.isEmpty else { return nil }
        let delta = event.modifierFlags.contains(.shift) ? -1 : 1
        let index = controls.firstIndex { $0 === current } ?? (delta > 0 ? -1 : 0)
        self.windowProvider()?.makeFirstResponder(
          controls[(index + delta + controls.count) % controls.count])
        return nil
      }
      return event
    }
  }
  private func focusedControl() -> NSView? {
    if let editor = windowProvider()?.firstResponder as? NSTextView, editor.isFieldEditor {
      return editor.delegate as? NSView
    }
    return windowProvider()?.firstResponder as? NSView
  }
  private func focusable(in view: NSView) -> [NSView] {
    if let control = view as? NSControl, control.isEnabled, !control.isHiddenOrHasHiddenAncestor {
      if control is NSButton || control is NSTableView
        || (control as? NSTextField)?.isEditable == true
      {
        return [control]
      }
    }
    return view.subviews.flatMap { focusable(in: $0) }
  }
  @objc private func clicked(_ sender: NSButton) {
    guard sender.isEnabled, let active, active.actions.indices.contains(sender.tag) else { return }
    if active.actions[sender.tag].role == .cancel { cancel() } else { finish(sender.tag) }
  }
  private func cancel() {
    guard let active else { return }
    guard let index = active.actions.firstIndex(where: { $0.role == .cancel && $0.enabled }) else {
      return
    }
    active.onCancel?()  // Credential cancellation barrier precedes any UI removal.
    guard self.active?.id == active.id else { return }
    finish(index)
  }
  private func finish(_ index: Int, notify: Bool = true) {
    guard let request = active else { return }
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    if let contentLayoutObserver{NotificationCenter.default.removeObserver(contentLayoutObserver)}
    contentLayoutObserver=nil
    shade?.removeFromSuperview()
    shade = nil
    buttons = []
    active = nil
    (windowProvider()?.contentView as? MetalCanvas)?.interactionEnabled = true
    if let window = windowProvider() {
      window.defaultButtonCell = previousDefault
      window.makeFirstResponder(previousResponder)
    }
    if notify { request.completion(index) }
    showNext()
  }
  func handleController(_ action: ControllerNavigation.Action) {
    guard let window = windowProvider(), active != nil else { return }
    if action == .cancel {
      cancel()
      return
    }
    if let table = focusedControl() as? NSTableView {
      if case .move(let direction) = action, direction == .up || direction == .down {
        let next = max(
          0, min(table.numberOfRows - 1, table.selectedRow + (direction == .up ? -1 : 1)))
        if table.numberOfRows > 0 {
          table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
          table.scrollRowToVisible(next)
        }
        return
      }
      if action == .activate, let target = table.target, let selector = table.doubleAction {
        _ = table.sendAction(selector, to: target)
        return
      }
    }
    ControllerNavigation.handleModal(action, window: window)
  }
}

extension AppDelegate {
  @discardableResult func presentDialog(
    title: String, message: String, content: NSView? = nil, actions: [ReadyDialogAction],
    onCancel: (() -> Void)? = nil, completion: @escaping (Int) -> Void
  ) -> UUID {
    if canvas != nil, session?.running != true {
      if canvas.section == .library { beginPage(.utility) }
      return pages.present(title:title,message:message,content:content,actions:actions,
        onCancel:onCancel,completion:completion)
    }
    return dialogs.present(
      title: title, message: message, content: content, actions: actions, onCancel: onCancel,
      completion: completion)
  }
  func dismissDialog(_ id: UUID) {
    if pages.isShowing(id) { pages.dismiss(id) }
    else { dialogs.dismiss(id) }
  }
}

// Local browsing stays in ready. This grants no extra filesystem permissions and
// never creates directories; Core still validates every selected executable/root.
enum ReadyFileSelection { case file, directory }
private final class ReadyFileBrowser: NSView, NSTableViewDataSource, NSTableViewDelegate {
  let path = NSTextField()
  let table = NSTableView()
  let status = NSTextField(wrappingLabelWithString: "")
  let mode: ReadyFileSelection
  var directory: URL
  var entries = [URL]()
  private var generation = UUID()
  private var directoryReadable = false
  var selectionChanged: ((Bool) -> Void)?
  var acceptSelection: (() -> Void)?
  var selected: URL? {
    guard directoryReadable else { return nil }
    if table.selectedRow >= 0, entries.indices.contains(table.selectedRow) {
      let value = entries[table.selectedRow]
      let properties = try? value.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
      if mode == .directory { return properties?.isDirectory == true ? value : nil }
      return properties?.isDirectory != true || properties?.isPackage == true ? value : nil
    }
    return mode == .directory ? directory : nil
  }
  init(directory: URL, mode: ReadyFileSelection) {
    self.directory = directory
    self.mode = mode
    super.init(frame: NSRect(x: 0, y: 0, width: 550, height: 300))
    path.frame = NSRect(x: 0, y: 268, width: 464, height: 28)
    path.target = self
    path.action = #selector(go)
    path.placeholderString = "/percorso/alla/cartella"
    addSubview(path)
    let up = NSButton(title: "Su", target: self, action: #selector(parentFolder))
    up.frame = NSRect(x: 472, y: 268, width: 70, height: 28)
    addSubview(up)
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 38, width: 542, height: 220))
    scroll.hasVerticalScroller = true
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
    column.title = "Nome"
    column.width = 520
    table.addTableColumn(column)
    table.headerView = nil
    table.rowHeight = 30
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.doubleAction = #selector(openEntry)
    table.backgroundColor = dialogColor(0x142025)
    scroll.documentView = table
    addSubview(scroll)
    status.frame = NSRect(x: 0, y: 0, width: 542, height: 32)
    status.font = .systemFont(ofSize: 12)
    addSubview(status)
    reload(fallback: true)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let url = entries[row]
    let properties = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
    let label = NSTextField(
      labelWithString: (properties?.isDirectory == true && properties?.isPackage != true
        ? "▸  " : "    ") + url.lastPathComponent)
    label.font = .systemFont(ofSize: 14)
    label.lineBreakMode = .byTruncatingMiddle
    return label
  }
  func tableViewSelectionDidChange(_ notification: Notification) {
    selectionChanged?(selected != nil)
  }
  @objc private func go() {
    let value = (path.stringValue as NSString).expandingTildeInPath
    guard value.hasPrefix("/") else {
      status.stringValue = "Inserisci un percorso assoluto."
      return
    }
    reload(target: URL(fileURLWithPath: value), resolveFile: true)
  }
  @objc private func parentFolder() {
    directory.deleteLastPathComponent()
    reload()
  }
  @objc private func openEntry() {
    let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
    guard entries.indices.contains(row) else { return }
    let url = entries[row]
    let properties = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
    if properties?.isDirectory == true && properties?.isPackage != true {
      directory = url
      reload()
    } else if selected != nil {
      acceptSelection?()
    }
  }
  private func reload(target: URL? = nil, resolveFile: Bool = false, fallback: Bool = false) {
    let requested = target ?? directory
    let token = UUID()
    generation = token
    path.stringValue = requested.path
    directoryReadable = false
    entries = []
    table.reloadData()
    status.stringValue = "Lettura della cartella…"
    selectionChanged?(false)
    let selectionMode = mode
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result = Result { () throws -> (URL, [URL], URL?) in
        var folder = requested
        if fallback {
          while !FileManager.default.fileExists(atPath: folder.path), folder.path != "/" {
            folder.deleteLastPathComponent()
          }
        }
        var selectedFile: URL?
        if resolveFile {
          let properties = try folder.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
          if properties.isDirectory != true
            || (properties.isPackage == true && selectionMode == .file)
          {
            selectedFile = folder
            folder.deleteLastPathComponent()
          }
        }
        let values = try FileManager.default.contentsOfDirectory(
          at: folder,
          includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles]
        ).sorted { a, b in
          let ad = (try? a.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
          let bd = (try? b.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
          return ad != bd
            ? ad
            : a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
        return (folder, values, selectedFile)
      }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.generation == token else { return }
        switch result {
        case .success(let (folder, values, selectedFile)):
          self.directory = folder
          self.path.stringValue = folder.path
          self.entries = values
          self.directoryReadable = true
          self.table.reloadData()
          if let selectedFile, let index = values.firstIndex(of: selectedFile) {
            self.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            self.table.scrollRowToVisible(index)
          }
          self.status.stringValue =
            self.mode == .directory
            ? "Seleziona una cartella o usa quella aperta. Doppio clic per aprire."
            : "Seleziona un file o un’app. Doppio clic per aprire una cartella."
        case .failure(let error):
          self.status.stringValue = "Impossibile leggere la cartella: " + error.localizedDescription
        }
        self.selectionChanged?(self.selected != nil)
      }
    }
  }
}

extension AppDelegate {
  func selectLocalFile(
    title: String, prompt: String, directory: URL, mode: ReadyFileSelection,
    completion: @escaping (URL?) -> Void
  ) {
    let browser = ReadyFileBrowser(directory: directory, mode: mode)
    let id = presentDialog(
      title: title,
      message: "Puoi anche inserire un percorso assoluto. I file restano nella loro posizione.",
      content: browser,
      actions: [
        .init(prompt, role: .primary, enabled: browser.selected != nil),
        .init("Annulla", role: .cancel),
      ]
    ) { choice in
      completion(choice == 0 ? browser.selected : nil)
    }
    browser.selectionChanged = { [weak self] enabled in
      self?.setPresentationActionEnabled(id, index: 0, enabled: enabled)
    }
    browser.acceptSelection = { [weak self] in self?.activatePresentationPrimary(id) }
  }
}
