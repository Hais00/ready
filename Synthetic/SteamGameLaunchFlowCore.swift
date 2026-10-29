// SPDX-License-Identifier: GPL-3.0-only
// UI-flow-only LauncherCore model shapes. No filesystem/runtime/account code.
import Foundation
public enum GamePlatform {case macOS,windows}
public struct GameVariant {public let platform:GamePlatform;public init(_ value:GamePlatform){platform=value}}
public struct Game {public let storeID:String;public let title:String;public init(_ title:String){self.title=title;storeID="480"}}
public struct LauncherPaths {public let root:URL;public var logs:URL{root.appendingPathComponent("Logs")};public init(_ root:URL){self.root=root}}
public enum LauncherError:LocalizedError {case unavailable(String);public var errorDescription:String?{switch self{case .unavailable(let message):return message}}}
