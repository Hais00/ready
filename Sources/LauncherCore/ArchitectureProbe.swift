// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum ArchitectureProbe {
  public static func inspect(_ url: URL) throws -> BinaryArchitecture {
    try inspect(Data(contentsOf: url, options: .mappedIfSafe))
  }
  public static func inspect(_ data: Data) throws -> BinaryArchitecture {
    func u32(_ at: Int, _ little: Bool) -> UInt32? {
      guard at >= 0, at + 4 <= data.count else { return nil }
      var value: UInt32 = 0
      for index in 0..<4 {
        let byte = UInt32(data[at + index])
        let position = little ? index : (3 - index)
        value |= byte << (position * 8)
      }
      return value
    }
    guard let magic = u32(0, false) else { return .unknown }
    if magic == 0xcafe_babe || magic == 0xbeba_feca || magic == 0xcafe_babf || magic == 0xbfba_feca
    {
      let little = magic == 0xbeba_feca || magic == 0xbfba_feca
      guard let count = u32(4, little), count <= 64 else { return .unknown }
      let stride = magic == 0xcafe_babf || magic == 0xbfba_feca ? 32 : 20
      var arm = false
      var x64 = false
      for i in 0..<Int(count) {
        let cpu = u32(8 + i * stride, little)
        arm = arm || cpu == 0x0100_000c
        x64 = x64 || cpu == 0x0100_0007
      }
      return arm && x64 ? .universal : arm ? .arm64 : x64 ? .x86_64 : .unknown
    }
    if [UInt32(0xfeed_facf), 0xcffa_edfe, 0xfeed_face, 0xcefa_edfe].contains(magic) {
      let little = magic == 0xcffa_edfe || magic == 0xcefa_edfe
      switch u32(4, little) {
      case 0x0100_000c: return .arm64
      case 0x0100_0007: return .x86_64
      case 7: return .x86
      default: return .unknown
      }
    }
    if data.count >= 64, data[0] == 0x4d, data[1] == 0x5a, let pe = u32(0x3c, true),
      pe < UInt32(data.count), Int(pe) + 6 <= data.count, u32(Int(pe), true) == 0x0000_4550
    {
      let machine = UInt16(data[Int(pe) + 4]) | UInt16(data[Int(pe) + 5]) << 8
      switch machine {
      case 0xaa64: return .arm64
      case 0x8664: return .x86_64
      case 0x14c: return .x86
      default: return .unknown
      }
    }
    return .unknown
  }
  public static func applicationExecutable(_ app: URL) -> URL? {
    guard let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
      let exe = plist["CFBundleExecutable"] as? String, !exe.contains("/")
    else { return nil }
    return app.appendingPathComponent("Contents/MacOS/" + exe)
  }
}
