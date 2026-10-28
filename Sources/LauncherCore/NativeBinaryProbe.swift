// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Confirms executable Mach-O slices target macOS/Mac Catalyst before labelling ARM64 native.
/// ArchitectureProbe remains the separate, permissive CPU-header utility.
public enum NativeBinaryProbe {
  public static func inspect(_ url: URL) throws -> BinaryArchitecture {
    try inspect(Data(contentsOf: url, options: .mappedIfSafe))
  }
  public static func inspect(_ data: Data) throws -> BinaryArchitecture {
    func invalid() -> LauncherError {
      .invalid("Mach-O eseguibile macOS non valido o piattaforma non verificabile.")
    }
    func u32(_ offset: Int, _ little: Bool) throws -> UInt32 {
      guard offset >= 0, offset <= data.count - 4 else { throw invalid() }
      var value: UInt32 = 0
      for index in 0..<4 {
        value |= UInt32(data[data.startIndex + offset + index]) << ((little ? index : 3 - index) * 8)
      }
      return value
    }
    func u64(_ offset: Int, _ little: Bool) throws -> UInt64 {
      guard offset >= 0, offset <= data.count - 8 else { throw invalid() }
      var value: UInt64 = 0
      for index in 0..<8 {
        value |= UInt64(data[data.startIndex + offset + index]) << ((little ? index : 7 - index) * 8)
      }
      return value
    }
    func thin(_ offset: Int, _ size: Int, expectedCPU: UInt32? = nil, expectedSubtype: UInt32? = nil) throws -> UInt32 {
      guard offset >= 0, size >= 28, offset <= data.count, size <= data.count - offset else {
        throw invalid()
      }
      let magic = try u32(offset, false)
      let little = magic == 0xcffa_edfe || magic == 0xcefa_edfe
      let wide = magic == 0xfeed_facf || magic == 0xcffa_edfe
      guard [UInt32(0xfeed_facf), 0xcffa_edfe, 0xfeed_face, 0xcefa_edfe].contains(magic) else {
        throw invalid()
      }
      let header = wide ? 32 : 28
      guard size >= header else { throw invalid() }
      let cpu = try u32(offset + 4, little)
      let subtype = try u32(offset + 8, little)
      if let expectedCPU, expectedCPU != cpu { throw invalid() }
      if let expectedSubtype, expectedSubtype != subtype { throw invalid() }
      guard [UInt32(7), 18, 0x0100_0007, 0x0100_000c, 0x0100_0012].contains(cpu),
        (cpu & 0x0100_0000 != 0) == wide, try u32(offset + 12, little) == 2
      else { throw invalid() }
      let count = Int(try u32(offset + 16, little))
      let bytes = Int(try u32(offset + 20, little))
      guard count <= 4096, bytes <= 1_048_576, bytes >= count * 8, bytes <= size - header else {
        throw invalid()
      }
      let end = offset + header + bytes
      var cursor = offset + header
      var macOS = false
      for _ in 0..<count {
        guard cursor <= end - 8 else { throw invalid() }
        let command = try u32(cursor, little)
        let length = Int(try u32(cursor + 4, little))
        guard length >= 8, length % (wide ? 8 : 4) == 0, length <= end - cursor else {
          throw invalid()
        }
        if command == 0x32 {
          guard length >= 24 else { throw invalid() }
          let platform = try u32(cursor + 8, little)
          let tools = Int(try u32(cursor + 20, little))
          guard platform == 1 || platform == 6, tools <= (length - 24) / 8 else {
            throw invalid()
          }
          macOS = true
        } else if command == 0x24 {
          guard length >= 16 else { throw invalid() }
          macOS = true
        } else if [UInt32(0x25), 0x2f, 0x30].contains(command) {
          throw invalid() // iOS/tvOS/watchOS legacy version-min commands.
        }
        cursor += length
      }
      guard cursor == end, macOS else { throw invalid() }
      return cpu
    }
    guard data.count >= 4 else { throw invalid() }
    let magic = try u32(0, false)
    let fat = [UInt32(0xcafe_babe), 0xbeba_feca, 0xcafe_babf, 0xbfba_feca].contains(magic)
    let macho = [UInt32(0xfeed_facf), 0xcffa_edfe, 0xfeed_face, 0xcefa_edfe].contains(magic)
    guard fat || macho else { throw invalid() }
    var cpus = Set<UInt32>()
    if fat {
      let little = magic == 0xbeba_feca || magic == 0xbfba_feca
      let wide = magic == 0xcafe_babf || magic == 0xbfba_feca
      let count = Int(try u32(4, little))
      let stride = wide ? 32 : 20
      let tableEnd = 8 + count * stride
      guard count > 0, count <= 64, tableEnd <= data.count else { throw invalid() }
      var ranges = [(Int, Int)]()
      var seen = Set<String>()
      for index in 0..<count {
        let entry = 8 + index * stride
        let cpu = try u32(entry, little), subtype = try u32(entry + 4, little)
        let offset = wide ? try u64(entry + 8, little) : UInt64(try u32(entry + 8, little))
        let size = wide ? try u64(entry + 16, little) : UInt64(try u32(entry + 12, little))
        let alignment = try u32(entry + (wide ? 24 : 16), little)
        guard offset >= UInt64(tableEnd), offset <= UInt64(data.count), size > 0,
          size <= UInt64(data.count) - offset, alignment <= 63,
          offset & ((UInt64(1) << alignment) - 1) == 0,
          seen.insert("\(cpu):\(subtype)").inserted
        else { throw invalid() }
        if wide, try u32(entry + 28, little) != 0 { throw invalid() }
        let start = Int(offset), end = Int(offset + size)
        for range in ranges where start < range.1 && range.0 < end { throw invalid() }
        ranges.append((start, end))
        cpus.insert(try thin(start, Int(size), expectedCPU: cpu, expectedSubtype: subtype))
      }
    } else {
      cpus.insert(try thin(0, data.count))
    }
    let arm = cpus.contains(0x0100_000c), intel = cpus.contains(0x0100_0007)
    guard arm || intel else {
      throw LauncherError.invalid("Il binario macOS richiede un’architettura non supportata su Apple Silicon.")
    }
    return arm && intel ? .universal : arm ? .arm64 : .x86_64
  }

  /// Recognises only the entry's interpreter directive, never the wrapped game's CPU.
  public static func isInterpretedLauncher(_ url: URL) throws -> Bool {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let bytes = try handle.read(upToCount: 4096) ?? Data()
    guard bytes.count >= 3, bytes[bytes.startIndex] == 0x23,
      bytes[bytes.startIndex + 1] == 0x21
    else { return false }
    let line = bytes.prefix { $0 != 0x0a }
    guard line.count < 4096, !line.contains(0), !line.contains(0x0d),
      let directive = String(data: line.dropFirst(2), encoding: .utf8),
      let interpreter = directive.split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
      interpreter.hasPrefix("/"), interpreter != "/",
      FileManager.default.isExecutableFile(atPath: String(interpreter))
    else { return false }
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: String(interpreter), isDirectory: &directory)
      && !directory.boolValue
  }

  /// Resolves only bundle-contained, executable files and rejects iOS-only bundle metadata.
  public static func applicationExecutable(_ app: URL) throws -> URL {
    let root = app.standardizedFileURL.resolvingSymlinksInPath()
    let info = try SafePath.resolve("Contents/Info.plist", under: root)
    guard let plist = try PropertyListSerialization.propertyList(
      from: Data(contentsOf: info), options: [], format: nil) as? [String: Any]
    else { throw LauncherError.invalid("Info.plist dell’app non valido.") }
    if let flag = plist["LSRequiresIPhoneOS"] {
      guard let value = flag as? NSNumber, !value.boolValue else {
        throw LauncherError.invalid("Questa app richiede iOS.")
      }
    }
    if let declared = plist["CFBundleSupportedPlatforms"] {
      guard let platforms = declared as? [String],
        !platforms.contains(where: { $0.lowercased() != "macosx" })
      else { throw LauncherError.invalid("Il bundle non dichiara esclusivamente macOS.") }
    }
    guard let name = plist["CFBundleExecutable"] as? String,
      !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
      !name.contains("\0")
    else { throw LauncherError.invalid("Nome eseguibile dell’app non valido.") }
    let executable = try SafePath.resolve("Contents/MacOS/" + name, under: root)
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: executable.path, isDirectory: &directory),
      !directory.boolValue, FileManager.default.isExecutableFile(atPath: executable.path)
    else { throw LauncherError.invalid("Eseguibile dell’app mancante o non avviabile.") }
    return executable
  }
}
