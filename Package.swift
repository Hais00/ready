// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "M1Launcher", platforms: [.macOS(.v14)],
  products: [
    .executable(name: "M1Launcher", targets: ["M1Launcher"]),
    .library(name: "LauncherCore", type: .static, targets: ["LauncherCore"]),
    .executable(name: "ReadyCoreProbe", targets: ["ReadyCoreProbe"]),
  ],
  targets: [
    .target(name: "LauncherCore"),
    .target(
      name: "ReadyHostedView", publicHeadersPath: "include",
      cSettings: [.unsafeFlags(["-fobjc-arc", "-fblocks", "-std=gnu11"])],
      linkerSettings: [
        .linkedFramework("AppKit"), .linkedFramework("Metal"), .linkedFramework("QuartzCore"),
        .linkedFramework("IOSurface"), .linkedFramework("Security"), .linkedLibrary("bsm"),
      ]),
    .executableTarget(
      name: "M1Launcher", dependencies: ["LauncherCore", "ReadyHostedView"],
      linkerSettings: [
        .linkedFramework("AppKit"), .linkedFramework("Metal"), .linkedFramework("QuartzCore"),
        .linkedFramework("GameController"), .linkedFramework("Security"),
        .linkedFramework("ScreenCaptureKit"),
      ]),
    .target(name: "LauncherChecks", dependencies: ["LauncherCore"], path: "Tests/Checks"),
    .executableTarget(
      name: "ReadyCoreProbe", dependencies: ["LauncherChecks"], path: "Synthetic/CoreProbe"),
    .testTarget(name: "LauncherCoreTests", dependencies: ["LauncherCore", "LauncherChecks"]),
  ])
