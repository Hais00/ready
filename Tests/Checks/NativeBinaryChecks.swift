// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherCore

enum NativeBinaryChecks {
  private enum Failure: Error { case failed(String) }
  private static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure.failed(message) }
  }
  private static func rejects(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw Failure.failed(message)
  }
  private static func put(_ value: UInt64, bytes: Int, at: Int, little: Bool, into data: inout Data) {
    for index in 0..<bytes {
      data[at + index] = UInt8((value >> ((little ? index : bytes - 1 - index) * 8)) & 255)
    }
  }
  private static func macho(
    cpu: UInt32 = 0x0100_000c, subtype: UInt32 = 0, platform: UInt32 = 1,
    kind: UInt32 = 2, little: Bool = true, legacy: UInt32? = nil
  ) -> Data {
    let wide = cpu & 0x0100_0000 != 0, header = wide ? 32 : 28
    let commandSize = legacy == nil ? 24 : 16
    var data = Data(repeating: 0, count: header + commandSize)
    let values: [(Int, UInt32)] = [
      (0, wide ? 0xfeed_facf : 0xfeed_face), (4, cpu), (8, subtype),
      (12, kind), (16, 1), (20, UInt32(commandSize)),
      (header, legacy ?? 0x32), (header + 4, UInt32(commandSize)),
      (header + 8, legacy == nil ? platform : 0x000a_0f00),
    ]
    for (offset, value) in values { put(UInt64(value), bytes: 4, at: offset, little: little, into: &data) }
    return data
  }
  private static func fat(_ slices: [(UInt32, UInt32, Data)], wide: Bool = false, little: Bool = false) -> Data {
    let stride = wide ? 32 : 20
    var data = Data(repeating: 0, count: 8 + slices.count * stride)
    put(wide ? 0xcafe_babf : 0xcafe_babe, bytes: 4, at: 0, little: little, into: &data)
    put(UInt64(slices.count), bytes: 4, at: 4, little: little, into: &data)
    for (index, slice) in slices.enumerated() {
      while data.count % 4 != 0 { data.append(0) }
      let offset = data.count, entry = 8 + index * stride
      put(UInt64(slice.0), bytes: 4, at: entry, little: little, into: &data)
      put(UInt64(slice.1), bytes: 4, at: entry + 4, little: little, into: &data)
      put(UInt64(offset), bytes: wide ? 8 : 4, at: entry + 8, little: little, into: &data)
      put(UInt64(slice.2.count), bytes: wide ? 8 : 4, at: entry + (wide ? 16 : 12), little: little, into: &data)
      put(2, bytes: 4, at: entry + (wide ? 24 : 16), little: little, into: &data)
      data.append(slice.2)
    }
    return data
  }
  static func validate() throws {
    let arm = macho(), intel = macho(cpu: 0x0100_0007, subtype: 3, legacy: 0x24)
    try require(try NativeBinaryProbe.inspect(arm) == .arm64, "Mac ARM64 executable")
    try require(try NativeBinaryProbe.inspect(intel) == .x86_64, "Legacy Mac Intel executable")
    try require(try NativeBinaryProbe.inspect(macho(platform: 6)) == .arm64, "Mac Catalyst executable")
    try require(try NativeBinaryProbe.inspect(macho(cpu: 0x0100_0007, little: false)) == .x86_64, "Big-endian Mach-O fields")
    for wide in [false, true] {
      for little in [false, true] {
        let universal = fat([(0x0100_000c, 0, arm), (0x0100_0007, 3, intel)], wide: wide, little: little)
        try require(try NativeBinaryProbe.inspect(universal) == .universal, "Valid universal table/slices")
      }
    }
    for platform in [UInt32(2), 3, 4, 5, 7, 8, 9, 10, 11, 12, 0] {
      try rejects("Non-Mac build platform must fail") { _ = try NativeBinaryProbe.inspect(macho(platform: platform)) }
    }
    for legacy in [UInt32(0x25), 0x2f, 0x30] {
      try rejects("Non-Mac legacy version command must fail") { _ = try NativeBinaryProbe.inspect(macho(legacy: legacy)) }
    }
    for kind in [UInt32(1), 6, 8] {
      try rejects("Non-executable Mach-O must fail") { _ = try NativeBinaryProbe.inspect(macho(kind: kind)) }
    }
    try rejects("32-bit-only Mac cannot be advertised on M1") { _ = try NativeBinaryProbe.inspect(macho(cpu: 7, legacy: 0x24)) }
    try rejects("CPU-only header is not an executable/platform proof") { _ = try NativeBinaryProbe.inspect(Data(arm.prefix(8))) }
    try require(try ArchitectureProbe.inspect(Data(arm.prefix(8))) == .arm64, "CPU utility remains permissive")
    var noOS = arm
    put(0, bytes: 4, at: 16, little: true, into: &noOS)
    put(0, bytes: 4, at: 20, little: true, into: &noOS)
    try rejects("No OS command is not positive macOS evidence") { _ = try NativeBinaryProbe.inspect(noOS) }
    var bad = arm; put(2, bytes: 4, at: 16, little: true, into: &bad)
    try rejects("Command count/bounds mismatch") { _ = try NativeBinaryProbe.inspect(bad) }
    bad = arm; put(0, bytes: 4, at: 36, little: true, into: &bad)
    try rejects("Zero-length command") { _ = try NativeBinaryProbe.inspect(bad) }
    bad = arm; put(2, bytes: 4, at: 52, little: true, into: &bad)
    try rejects("Build tools count exceeds command size") { _ = try NativeBinaryProbe.inspect(bad) }
    bad = fat([(0x0100_000c, 0, arm), (0x0100_0007, 3, intel)])
    put(0x0100_0007, bytes: 4, at: 8, little: false, into: &bad)
    try rejects("Fat declaration and slice CPU disagree") { _ = try NativeBinaryProbe.inspect(bad) }
    bad = fat([(0x0100_000c, 0, arm)], wide: true)
    put(UInt64.max, bytes: 8, at: 16, little: false, into: &bad)
    try rejects("Overflowing fat offset") { _ = try NativeBinaryProbe.inspect(bad) }
    bad = fat([(0x0100_000c, 0, arm), (0x0100_0007, 3, intel)])
    put(48, bytes: 4, at: 36, little: false, into: &bad)
    try rejects("Overlapping fat slice ranges") { _ = try NativeBinaryProbe.inspect(bad) }
    bad = fat([(0x0100_000c, 0, arm)], wide: true)
    put(1, bytes: 4, at: 36, little: false, into: &bad)
    try rejects("Nonzero reserved fat64 field") { _ = try NativeBinaryProbe.inspect(bad) }
    bad = arm; put(7, bytes: 4, at: 4, little: true, into: &bad)
    try rejects("CPU ABI and 64-bit header disagree") { _ = try NativeBinaryProbe.inspect(bad) }
    let mixed = fat([(0x0100_0007, 3, intel), (0x0100_000c, 0, macho(platform: 2))])
    try rejects("iOS ARM slice in fat must never grant Apple Silicon native") { _ = try NativeBinaryProbe.inspect(mixed) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ready-native-check-" + UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func app(_ name: String, bytes: Data, metadata: [String: Any] = [:], parent: URL? = nil) throws -> URL {
      let bundle = (parent ?? root).appendingPathComponent(name + ".app")
      try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
      let info = ["CFBundleExecutable": "Game"].merging(metadata) { _, new in new }
      try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
      let binary = bundle.appendingPathComponent("Contents/MacOS/Game")
      try bytes.write(to: binary); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
      return bundle
    }
    let valid = try app("Valid", bytes: arm)
    let imported = try LocalDiscovery.importGame(valid)
    try require(imported.variants.first?.architecture == .arm64 && imported.variants.first?.title == "Apple Silicon nativo", "Valid bundle is native")
    let catalyst = try app("Catalyst", bytes: macho(platform: 6), metadata: ["CFBundleSupportedPlatforms": ["MacOSX"]])
    try require(try LocalDiscovery.importGame(catalyst).variants.first?.architecture == .arm64, "Mac Catalyst bundle is accepted")
    for (name, bytes, metadata) in [
      ("Phone", macho(platform: 2), [:]), ("Mixed", mixed, [:]),
      ("Dylib", macho(kind: 6), [:]), ("IOSFlag", arm, ["LSRequiresIPhoneOS": true]),
      ("WrongPlatforms", arm, ["CFBundleSupportedPlatforms": ["iPhoneOS"]]),
      ("MalformedPlatforms", arm, ["CFBundleSupportedPlatforms": "iPhoneOS"]),
      ("UnrecognizedBundle", Data("not an executable format".utf8), [:]),
    ] as [(String, Data, [String: Any])] {
      let bundle = try app(name, bytes: bytes, metadata: metadata)
      try rejects("Invalid native app import: " + name) { _ = try LocalDiscovery.importGame(bundle) }
    }
    let interpretedBundle = try app("Interpreted", bytes: Data("#!/bin/sh\nexit 0\n".utf8))
    let interpretedGame = try LocalDiscovery.importGame(interpretedBundle)
    try require(interpretedGame.variants.first?.architecture == .unknown && interpretedGame.variants.first?.title != "Apple Silicon nativo", "Legitimate script app remains usable and unknown")
    try require(interpretedGame.variants.first?.verification.contains("interpretato") == true, "Script wrapper verification explains unknown game architecture")
    try rejects("Pure Mach-O probe never certifies scripts") { _ = try NativeBinaryProbe.inspect(Data("#!/bin/sh\n".utf8)) }
    let escape = try app("Escape", bytes: arm)
    let executable = escape.appendingPathComponent("Contents/MacOS/Game")
    try FileManager.default.removeItem(at: executable)
    try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: valid.appendingPathComponent("Contents/MacOS/Game"))
    try rejects("Bundle executable symlink must remain inside bundle") { _ = try LocalDiscovery.importGame(escape) }
    let plistEscape = try app("PlistEscape", bytes: arm)
    let info = plistEscape.appendingPathComponent("Contents/Info.plist")
    try FileManager.default.removeItem(at: info)
    try FileManager.default.createSymbolicLink(at: info, withDestinationURL: valid.appendingPathComponent("Contents/Info.plist"))
    try rejects("Bundle plist symlink must remain inside bundle") { _ = try LocalDiscovery.importGame(plistEscape) }
    let notExecutable = try app("NoExecutePermission", bytes: arm)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: notExecutable.appendingPathComponent("Contents/MacOS/Game").path)
    try rejects("Mach-O header cannot replace executable permission") { _ = try LocalDiscovery.importGame(notExecutable) }
    let script = root.appendingPathComponent("script.lua")
    try Data("#!/usr/bin/env lua\nprint('fixture')\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let unknown = try LocalDiscovery.importGame(script)
    try require(unknown.variants.first?.architecture == .unknown && unknown.variants.first?.title != "Apple Silicon nativo", "Script remains unknown")
    for (name, text) in [("unrecognized", "not a binary"), ("relative-interpreter", "#!lua\nprint('fixture')\n")] {
      let unsupported = root.appendingPathComponent(name)
      try Data(text.utf8).write(to: unsupported)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unsupported.path)
      try rejects("Unknown format and invalid interpreter are unsupported") { _ = try LocalDiscovery.importGame(unsupported) }
    }
    let windows = root.appendingPathComponent("Windows.exe")
    try Data([0x4d, 0x5a]).write(to: windows)
    try require(try LocalDiscovery.importGame(windows).variants.first?.platform == .windows, "Windows import behavior preserved")
    let home = root.appendingPathComponent("Home"), steam = home.appendingPathComponent("Library/Application Support/Steam/steamapps")
    let game = steam.appendingPathComponent("common/Installed")
    try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
    _ = try app("SteamGood", bytes: arm, parent: game)
    _ = try app("SteamIOS", bytes: macho(platform: 2), parent: game)
    _ = try app("SteamScript", bytes: Data("#!/bin/sh\nexit 0\n".utf8), parent: game)
    _ = try app("SteamDylib", bytes: macho(kind: 6), parent: game)
    try Data([0x4d, 0x5a]).write(to: game.appendingPathComponent("Windows.exe"))
    try Data(#"""
    "AppState" { "appid" "42" "name" "Fixture" "installdir" "Installed" }
    """#.utf8).write(to: steam.appendingPathComponent("appmanifest_42.acf"))
    let found = try LocalDiscovery.steamLibraries(home: home)
    let native = found.flatMap { $0.variants }.filter { $0.platform == .macOS }
    try require(native.count == 2 && native.filter { $0.architecture == .arm64 }.count == 1 && native.filter { $0.architecture == .unknown }.count == 1, "Steam skips iOS and dylib bundles")
    try require(found.flatMap { $0.variants }.contains { $0.platform == .windows }, "Steam Windows branch preserved")
  }
}
