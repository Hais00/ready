// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Static imports show possible APIs; they do not prove the API selected at runtime.
public enum PEImports {
  public static func graphicsAPIs(at file: URL) throws -> [String] {
    graphicsAPIs(in: try Data(contentsOf: file, options: .mappedIfSafe))
  }
  public static func graphicsAPIs(in data: Data) -> [String] {
    func u16(_ i: Int) -> Int? {
      guard i >= 0, i + 2 <= data.count else { return nil }
      return Int(data[i]) | Int(data[i + 1]) << 8
    }
    func u32(_ i: Int) -> Int? {
      guard i >= 0, i + 4 <= data.count else { return nil }
      var result = 0
      for j in 0..<4 { result |= Int(data[i + j]) << (j * 8) }
      return result
    }
    guard data.count >= 64, data[0] == 0x4d, data[1] == 0x5a, let pe = u32(0x3c), u32(pe) == 0x4550,
      let count = u16(pe + 6), count <= 96, let optSize = u16(pe + 20), let magic = u16(pe + 24)
    else { return [] }
    let directoryOffset = magic == 0x20b ? 112 : magic == 0x10b ? 96 : 0
    guard directoryOffset > 0, optSize >= directoryOffset + 16,
      let importRVA = u32(pe + 24 + directoryOffset + 8), importRVA > 0
    else { return [] }
    let sections = pe + 24 + optSize
    func offset(_ rva: Int) -> Int? {
      for s in 0..<count {
        let h = sections + s * 40
        guard let va = u32(h + 12), let virtualSize = u32(h + 8), let size = u32(h + 16),
          let raw = u32(h + 20)
        else { return nil }
        if rva >= va, rva - va < max(virtualSize, size) {
          let result = raw + rva - va
          return result >= 0 && result < data.count ? result : nil
        }
      }
      return nil
    }
    guard let imports = offset(importRVA) else { return [] }
    var apis = Set<String>()
    for i in 0..<512 {
      guard let nameRVA = u32(imports + i * 20 + 12), nameRVA > 0, let name = offset(nameRVA) else {
        break
      }
      var bytes = [UInt8]()
      for j in 0..<256 where name + j < data.count {
        let byte = data[name + j]
        if byte == 0 { break }
        bytes.append(byte)
      }
      switch String(decoding: bytes, as: UTF8.self).lowercased() {
      case "d3d9.dll": apis.insert("d3d9")
      case "d3d11.dll": apis.insert("d3d11")
      case "d3d12.dll": apis.insert("d3d12")
      case "vulkan-1.dll": apis.insert("vulkan")
      default: break
      }
    }
    return apis.sorted()
  }
  public static func annotate(_ game: inout Game, variant: GameVariant) {
    guard variant.platform == .windows, let executable = variant.executable,
      let apis = try? graphicsAPIs(at: URL(fileURLWithPath: executable)), !apis.isEmpty
    else { return }
    if game.metadata == nil { game.metadata = [:] }
    game.metadata?["possibleGraphicsAPIs"] = .array(apis.map { .string($0) })
    if apis.count == 1 { game.metadata?["graphicsAPI"] = .string(apis[0]) }
  }
}
