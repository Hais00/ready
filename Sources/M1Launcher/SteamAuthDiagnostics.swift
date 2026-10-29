// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CoreFoundation
import Darwin
import ImageIO

private enum SteamAuthDiagnosticError: LocalizedError {
  case invalid
  var errorDescription: String? {
    "Lo stato diagnostico dell’accesso non è disponibile o non è valido."
  }
}

enum SteamAuthDiagnosticPhase: String, CaseIterable {
  case starting, authenticating, qr, authentication_complete, authorizing_game, authorized
  case starting_native, completed, failed, cancelled
  var title: String {
    switch self {
    case .starting: return "Preparazione dell’accesso…"
    case .authenticating: return "Autenticazione in corso…"
    case .qr: return "Inquadra il codice con Steam sul telefono."
    case .authentication_complete: return "Accesso completato."
    case .authorizing_game: return "Verifica della licenza in corso…"
    case .authorized: return "Licenza verificata."
    case .starting_native: return "Preparazione della sessione…"
    case .completed: return "Operazione completata."
    case .failed: return "Accesso non riuscito."
    case .cancelled: return "Operazione annullata."
    }
  }
}

/// Only safe UI status and PNG pixels cross this boundary. No credential/URL
/// fields are accepted and no authentication operation is initiated here.
final class SteamAuthDiagnosticReader {
  struct State {
    let generation: UUID
    let sequence: Int64
    let phase: SteamAuthDiagnosticPhase
    let message: String?
    let image: NSImage?
  }
  private let parent: URL
  private let basename: String
  private let descriptor: Int32
  private let device: dev_t
  private let inode: ino_t
  private(set) var generation: UUID?
  private var sequence: Int64 = -1
  private var lastDocument: Data?

  init(status: URL) throws {
    let raw = status.path
    guard raw.hasPrefix("/"), raw == status.standardizedFileURL.path,
      raw == status.resolvingSymlinksInPath().path
    else { throw SteamAuthDiagnosticError.invalid }
    parent = status.deletingLastPathComponent()
    basename = status.lastPathComponent
    guard !basename.isEmpty, basename != ".", basename != ".." else {
      throw SteamAuthDiagnosticError.invalid
    }
    var info = stat()
    guard lstat(parent.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == getuid(), info.st_mode & 0o777 == 0o700
    else { throw SteamAuthDiagnosticError.invalid }
    let fd = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw SteamAuthDiagnosticError.invalid }
    var opened = stat()
    guard fstat(fd, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
      close(fd)
      throw SteamAuthDiagnosticError.invalid
    }
    descriptor = fd
    device = opened.st_dev
    inode = opened.st_ino
  }
  deinit { close(descriptor) }

  private func validateParent() throws {
    var info = stat()
    guard lstat(parent.path, &info) == 0, info.st_dev == device, info.st_ino == inode,
      info.st_uid == getuid(), info.st_mode & 0o777 == 0o700,
      (info.st_mode & S_IFMT) == S_IFDIR,
      parent.path == parent.resolvingSymlinksInPath().path
    else { throw SteamAuthDiagnosticError.invalid }
  }
  private func read(_ name: String, maximum: Int) throws -> Data {
    try validateParent()
    guard name == (name as NSString).lastPathComponent, !name.contains("/"), !name.contains("\\"),
      !name.contains("\0")
    else { throw SteamAuthDiagnosticError.invalid }
    let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw SteamAuthDiagnosticError.invalid }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == getuid(), info.st_mode & 0o777 == 0o600, info.st_nlink == 1,
      info.st_size > 0, info.st_size <= maximum
    else { throw SteamAuthDiagnosticError.invalid }
    var data = Data(count: Int(info.st_size))
    let expected = data.count
    let count: Int = data.withUnsafeMutableBytes { buffer in
      var offset = 0
      while offset < expected {
        let value = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), expected - offset)
        if value < 0 && errno == EINTR { continue }
        if value <= 0 { return -1 }
        offset += value
      }
      return offset
    }
    var after = stat()
    guard count == expected, fstat(fd, &after) == 0, after.st_size == info.st_size,
      after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
      after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec
    else { throw SteamAuthDiagnosticError.invalid }
    return data
  }
  private func integer(_ value: Any?) throws -> Int64 {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      ["q", "i", "s", "l", "Q", "I", "S", "L"].contains(String(cString: number.objCType)),
      number.int64Value >= 0, number.uint64Value <= 9_007_199_254_740_991
    else { throw SteamAuthDiagnosticError.invalid }
    return number.int64Value
  }
  func next() throws -> State? {
    let data = try read(basename, maximum: 16 * 1024)
    guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(document.keys).isSubset(of: [
        "schema", "generation", "sequence", "phase", "image", "message",
      ]),
      try integer(document["schema"]) == 1,
      let text = document["generation"] as? String, let id = UUID(uuidString: text),
      id.uuidString.lowercased() == text.lowercased(),
      let phaseText = document["phase"] as? String,
      let phase = SteamAuthDiagnosticPhase(rawValue: phaseText)
    else { throw SteamAuthDiagnosticError.invalid }
    let nextSequence = try integer(document["sequence"])
    if let generation, generation != id { throw SteamAuthDiagnosticError.invalid }
    guard nextSequence >= sequence else { throw SteamAuthDiagnosticError.invalid }
    if nextSequence == sequence {
      guard data == lastDocument else { throw SteamAuthDiagnosticError.invalid }
      return nil
    }
    var message: String?
    if let raw = document["message"] {
      guard let value = raw as? String, value.utf8.count <= 512, !value.contains("://"),
        value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
      else { throw SteamAuthDiagnosticError.invalid }
      message = value
    }
    var image: NSImage?
    if phase == .qr {
      guard let name = document["image"] as? String, name.hasPrefix("qr-"), name.hasSuffix(".png"),
        let imageID = UUID(uuidString: String(name.dropFirst(3).dropLast(4))),
        name.lowercased() == "qr-" + imageID.uuidString.lowercased() + ".png"
      else { throw SteamAuthDiagnosticError.invalid }
      let pixels = try read(name, maximum: 2 * 1024 * 1024)
      guard pixels.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
        let source = CGImageSourceCreateWithData(pixels as CFData, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int,
        width >= 16, width <= 2048, height == width,
        let bitmap = NSBitmapImageRep(data: pixels),
        bitmap.pixelsWide >= 16, bitmap.pixelsWide <= 2048,
        bitmap.pixelsHigh == bitmap.pixelsWide
      else { throw SteamAuthDiagnosticError.invalid }
      let decoded = NSImage(size: NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
      decoded.addRepresentation(bitmap)
      image = decoded
    }
    generation = id
    sequence = nextSequence
    lastDocument = data
    return State(
      generation: id, sequence: nextSequence, phase: phase, message: message, image: image)
  }
  private func publish(_ name: String, value: [String: Any]) throws {
    try validateParent()
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    let temporary = ".ready-ui-" + UUID().uuidString + ".pending"
    let fd = openat(
      descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw SteamAuthDiagnosticError.invalid }
    defer {
      close(fd)
      unlinkat(descriptor, temporary, 0)
    }
    let written: Bool = data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < data.count {
        let value = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset)
        if value < 0 && errno == EINTR { continue }
        if value <= 0 { return false }
        offset += value
      }
      return true
    }
    guard written, fsync(fd) == 0, linkat(descriptor, temporary, descriptor, name, 0) == 0 else {
      throw SteamAuthDiagnosticError.invalid
    }
    unlinkat(descriptor, temporary, 0)
    _ = fsync(descriptor)
  }
  func acknowledge() throws {
    guard let generation else { throw SteamAuthDiagnosticError.invalid }
    try publish(
      "live-ui-ready.json",
      value: ["schema": 1, "generation": generation.uuidString.lowercased(), "pid": getpid()])
  }
  func cancel() throws {
    guard let generation else { throw SteamAuthDiagnosticError.invalid }
    try publish(
      "cancel.request",
      value: ["schema": 1, "generation": generation.uuidString.lowercased(), "action": "cancel"])
  }
}

private final class SteamAuthQRImageView: NSImageView {
  override func draw(_ dirtyRect: NSRect) {
    let previous = NSGraphicsContext.current?.imageInterpolation
    NSGraphicsContext.current?.imageInterpolation = .none
    super.draw(dirtyRect)
    if let previous { NSGraphicsContext.current?.imageInterpolation = previous }
  }
}
private final class SteamAuthDialogContent: NSView, ReadyDialogContentSizing {
  let maximumViewportHeight: CGFloat = 420
}

final class SteamAuthDiagnostics {
  private weak var delegate: AppDelegate?
  private let reader: SteamAuthDiagnosticReader
  private var timer: Timer?
  private var dialog: UUID?
  private var acknowledged = false
  private(set) var isWatching = false
  private(set) var imageVisible = false
  private(set) var phase: SteamAuthDiagnosticPhase?
  private let image = SteamAuthQRImageView(frame: NSRect(x: 110, y: 42, width: 320, height: 320))
  private let label = NSTextField(wrappingLabelWithString: "Preparazione dell’accesso…")
  init(delegate: AppDelegate, status: URL) throws {
    self.delegate = delegate
    reader = try SteamAuthDiagnosticReader(status: status)
  }
  func start() throws {
    guard let delegate, let initial = try reader.next() else {
      throw SteamAuthDiagnosticError.invalid
    }
    let side = min(320, max(200, (delegate.window.contentView?.bounds.height ?? 760) - 350))
    let content = SteamAuthDialogContent(frame: NSRect(x: 0, y: 0, width: 540, height: side + 46))
    image.frame = NSRect(x: (540 - side) / 2, y: 0, width: side, height: side)
    image.imageScaling = .scaleProportionallyUpOrDown
    image.isHidden = true
    label.frame = NSRect(x: 0, y: side + 12, width: 540, height: 34)
    label.font = .systemFont(ofSize: 14, weight: .medium)
    content.addSubview(image)
    content.addSubview(label)
    dialog = delegate.presentDialog(
      title: "Accesso a Steam",
      message: "Il codice si aggiorna automaticamente in questa finestra.", content: content,
      actions: [.init("Annulla", role: .cancel)], onCancel: { [weak self] in self?.cancel() }
    ) { _ in }
    apply(initial)
    isWatching = true
    let watcher = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
      self?.tick()
    }
    timer = watcher
    RunLoop.main.add(watcher, forMode: .common)
  }
  deinit { timer?.invalidate() }
  private func apply(_ state: SteamAuthDiagnosticReader.State) {
    phase = state.phase
    image.image = state.phase == .qr ? state.image : nil
    imageVisible = state.phase == .qr && state.image != nil
    image.isHidden = !imageVisible
    label.stringValue = state.message ?? state.phase.title
    image.superview?.needsDisplay = true
  }
  func tick() {
    guard isWatching else { return }
    do {
      if let state = try reader.next() { apply(state) }
      if !acknowledged, let delegate, let dialog, delegate.window.isVisible,
        delegate.isPresentationShowing(dialog)
      {
        try reader.acknowledge()
        acknowledged = true
      }
    } catch {
      image.image = nil
      image.isHidden = true
      imageVisible = false
      label.stringValue = "Stato dell’accesso non disponibile. Il codice è stato nascosto."
    }
  }
  func cancel() {
    isWatching = false
    timer?.invalidate()
    timer = nil
    image.image = nil
    image.isHidden = true
    imageVisible = false
    do { try reader.cancel() } catch {
      label.stringValue = "Impossibile inviare l’annullamento diagnostico."
    }
    if let dialog { delegate?.dismissDialog(dialog) }
    dialog = nil
  }
}
