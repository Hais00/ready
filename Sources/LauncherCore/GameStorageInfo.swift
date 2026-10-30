// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Size data keeps platform, source and verification together. Unknown bytes
/// never become zero and a Store minimum requirement is not a download size.
public struct GameStorageInfo:Equatable {
  public var installedBytes:UInt64?
  public var downloadBytes:UInt64?
  public var requiredBytes:UInt64?
  public var source:String
  public var verified:Bool
  public var status:String
  public var reason:String?
  public init(installedBytes:UInt64?=nil,downloadBytes:UInt64?=nil,requiredBytes:UInt64?=nil,source:String="unknown",verified:Bool=false,status:String="unavailable",reason:String?=nil){
    self.installedBytes=installedBytes;self.downloadBytes=downloadBytes;self.requiredBytes=requiredBytes;self.source=source;self.verified=verified;self.status=status;self.reason=reason
  }
  public init(metadata:[String:JSONValue],platform:GamePlatform){
    let entry:[String:JSONValue]
    if case .object(let platforms)=metadata["platformSizes"],case .object(let value)=platforms[platform.rawValue]{entry=value}
    else if case .object(let platforms)=metadata["storageSizes"],case .object(let value)=platforms[platform.rawValue]{entry=value}
    else{entry=metadata}
    self.init(installedBytes:Self.bytes(entry["installedBytes"] ?? entry["installSize"]),downloadBytes:Self.bytes(entry["downloadBytes"] ?? entry["downloadSize"]),requiredBytes:Self.bytes(entry["requiredBytes"]),source:Self.text(entry["source"]) ?? "unknown",verified:entry["verified"] == .bool(true),status:Self.text(entry["status"]) ?? "unavailable",reason:Self.text(entry["reason"]))
    if requiredBytes==nil,case .object(let all)=metadata["platformRequirements"],case .object(let requirement)=all[platform.rawValue]{requiredBytes=Self.bytes(requirement["requiredBytes"]);if installedBytes==nil && downloadBytes==nil{source=Self.text(requirement["source"]) ?? source}}
  }
  public var hasSize:Bool{installedBytes != nil || downloadBytes != nil || requiredBytes != nil}
  public var reservationBytes:UInt64?{installedBytes ?? requiredBytes}
  public var metadata:[String:JSONValue]{
    var value:[String:JSONValue]=["source":.string(source),"verified":.bool(verified),"status":.string(status)]
    if let installedBytes{value["installedBytes"] = .unsigned(installedBytes)}
    if let downloadBytes{value["downloadBytes"] = .unsigned(downloadBytes)}
    if let requiredBytes{value["requiredBytes"] = .unsigned(requiredBytes)}
    if let reason{value["reason"] = .string(reason)}
    return value
  }
  private static func text(_ value:JSONValue?)->String?{if case .string(let text)=value,!text.isEmpty{return text};return nil}
  public static func bytes(_ value:JSONValue?)->UInt64?{
    switch value {
    case .unsigned(let v):return v
    case .integer(let v):return v>=0 ? UInt64(v):nil
    case .number(let v):return v.isFinite && v>=0 && v.rounded()==v && v<Double(UInt64.max) ? UInt64(v):nil
    case .string(let raw):guard !raw.isEmpty,raw.utf8.allSatisfy({(48...57).contains($0)})else{return nil};return UInt64(raw)
    default:return nil
    }
  }
}
