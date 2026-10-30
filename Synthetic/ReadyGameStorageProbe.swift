// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherCore
@main struct ReadyGameStorageProbe {
  @MainActor static func main()throws{
    let root=URL(fileURLWithPath:CommandLine.arguments[1]);var checks=[String:Bool]()
    func check(_ name:String,_ value:Bool)throws{checks[name]=value;if !value{throw NSError(domain:name,code:1)}}
    func wait(_ operation:(@escaping(UInt64?)->Void)->Void)throws->UInt64?{
      var finished=false,value:UInt64?;operation{value=$0;finished=true};let end=Date().addingTimeInterval(5)
      while !finished && Date()<end{_=RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.005))}
      try check("workerCompleted",finished);return value
    }
    try check("unsignedSizesDoNotOverflowSignedRange",GameStorageInfo.bytes(.unsigned(UInt64.max))==UInt64.max)
    try check("negativeBooleanAndFractionalSizesAreUnknown",GameStorageInfo.bytes(.integer(-1))==nil && GameStorageInfo.bytes(.bool(true))==nil && GameStorageInfo.bytes(.number(1.5))==nil)
    let metadata:[String:JSONValue]=["platformSizes":.object(["macOS":.object(["installedBytes":.unsigned(3000),"downloadBytes":.unsigned(1000),"verified":.bool(true),"source":.string("manifest")]),"windows":.object(["installedBytes":.unsigned(9000)])]),"platformRequirements":.object(["windows":.object(["requiredBytes":.unsigned(12000)])])]
    let mac=GameStorageInfo(metadata:metadata,platform:.macOS),win=GameStorageInfo(metadata:metadata,platform:.windows)
    try check("sizesRemainSeparatedByPlatform",mac.installedBytes==3000 && mac.downloadBytes==1000 && win.installedBytes==9000 && win.downloadBytes==nil)
    try check("minimumRequirementIsSeparateFromDownload",win.requiredBytes==12000 && win.reservationBytes==9000)
    try check("unknownSizeDoesNotBecomeZero",!GameStorageInfo(metadata:[:],platform:.macOS).hasSize)
    let install=root.appendingPathComponent("library/steamapps/common/Fixture"),program=install.appendingPathComponent("Fixture.app/Contents/MacOS/game"),asset=install.appendingPathComponent("data/asset")
    try FileManager.default.createDirectory(at:program.deletingLastPathComponent(),withIntermediateDirectories:true);try FileManager.default.createDirectory(at:asset.deletingLastPathComponent(),withIntermediateDirectories:true)
    try Data(repeating:1,count:10).write(to:program);try Data(repeating:2,count:20).write(to:asset)
    try FileManager.default.linkItem(at:asset,to:install.appendingPathComponent("data/hardlink"))
    let outside=root.appendingPathComponent("outside");try Data(repeating:3,count:1000).write(to:outside);try FileManager.default.createSymbolicLink(at:install.appendingPathComponent("outside-link"),withDestinationURL:outside)
    var variant=GameVariant(id:"mac",platform:.macOS,architecture:.arm64,executable:program.path,installationRoot:install.path,installed:true)
    let game=Game(id:"fixture",store:.steam,storeID:"42",title:"Fixture",variants:[variant]),directory=root.appendingPathComponent("sizes")
    let service=GameStorageSizeService(directory:directory)
    let measured=try wait{service.measure(game:game,variant:variant,completion:$0)}
    FileHandle.standardError.write(Data(("measured="+String(describing:measured)+"\n").utf8))
    try check("actualInstallationSizeSkipsSymlinksAndDeduplicatesHardlinks",measured==30)
    let second=GameStorageSizeService(directory:directory);let cached=try wait{second.measure(game:game,variant:variant,completion:$0)}
    try check("sizeIndexPersistsAcrossServiceInstances",cached==30)
    let manifest=install.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("appmanifest_42.acf");try Data("new build".utf8).write(to:manifest);try Data(repeating:2,count:40).write(to:asset)
    let updated=try wait{second.measure(game:game,variant:variant,completion:$0)}
    try check("SteamManifestChangeInvalidatesCachedFileMeasurement",updated==50)
    try Data(repeating:1,count:14).write(to:program);second.invalidate(game:game)
    let after=try wait{second.measure(game:game,variant:variant,completion:$0)}
    try check("verifiedInstallCompletionCanInvalidateSize",after==54)
    variant.installed=false;let uninstalled=try wait{second.measure(game:game,variant:variant,completion:$0)}
    try check("uninstalledVariantDoesNotTriggerDiskTraversal",uninstalled==nil)
    print(String(data:try JSONSerialization.data(withJSONObject:["passed":true,"count":checks.count,"checks":checks,"realLibraryOrAccountUsed":false],options:.sortedKeys),encoding:.utf8)!)
  }
}
