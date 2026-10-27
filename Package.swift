// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "M1Launcher", platforms: [.macOS(.v14)],
  products: [
    .executable(name: "M1Launcher", targets: ["M1Launcher"]),
    .library(name: "LauncherCore", targets: ["LauncherCore"]),
    .executable(name: "ReadyCoreProbe", targets: ["ReadyCoreProbe"]),
  ],
  targets: [
    .target(name: "LauncherCore"),
    .executableTarget(
      name: "M1Launcher", dependencies: ["LauncherCore"],
      linkerSettings: [
        .linkedFramework("AppKit"), .linkedFramework("Metal"), .linkedFramework("QuartzCore"),
        .linkedFramework("GameController"), .linkedFramework("Security"),
      ]),
    .target(name: "LauncherChecks", dependencies: ["LauncherCore"], path: "Tests/Checks"),
    .executableTarget(
      name: "ReadyCoreProbe", dependencies: ["LauncherChecks"], path: "Synthetic/CoreProbe"),
    .testTarget(name: "LauncherCoreTests", dependencies: ["LauncherCore", "LauncherChecks"]),
  ])
