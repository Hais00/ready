// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherCore

/// Persistent display bytes only; no depot selection or installation authority.
enum GameStorageDisplayCache {
  private static let key="readyGameSizeDisplayCache"
  static func remember(in metadata:inout [String:JSONValue]){
    guard case .object(let platforms)=metadata["platformSizes"]else{return}
    var saved=[String:JSONValue]();if case .object(let old)=metadata[key]{saved=old}
    for platform in [GamePlatform.windows,.macOS]{
      guard case .object(let value)=platforms[platform.rawValue]else{continue}
      var info=GameStorageInfo(metadata:value,platform:platform)
      guard info.installedBytes != nil || info.downloadBytes != nil else{continue}
      info.verified=false;info.status="display_only";info.reason="cached_display_bytes"
      saved[platform.rawValue] = .object(info.metadata)
    }
    if !saved.isEmpty{metadata[key] = .object(saved)}
  }
  static func info(metadata:[String:JSONValue],platform:GamePlatform)->GameStorageInfo{
    var current=GameStorageInfo(metadata:metadata,platform:platform)
    guard current.installedBytes==nil,case .object(let all)=metadata[key],case .object(let saved)=all[platform.rawValue]else{return current}
    let cached=GameStorageInfo(metadata:saved,platform:platform)
    current.installedBytes=cached.installedBytes;current.downloadBytes=current.downloadBytes ?? cached.downloadBytes
    if current.installedBytes != nil{current.verified=false;current.status="display_only";current.reason="cached_display_bytes"}
    return current
  }
}

