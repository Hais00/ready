// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import LauncherCore

public final class CoreChecks {
    public init() {}

    public func run() -> [[String:String]] {
        let cases:[(String,() throws -> Void)] = [
            ("Valve manifests and malformed input", testValveManifestWithEscapesAndComments),
            ("Mach-O architecture and unknown native availability", testDistinguishesARM64IntelAndFatBinaries),
            ("Per-prefix locks allow independent sessions", testPrefixLeasePreventsConcurrentMutations),
            ("Isolated game/profile prefix paths and persistent profiles", testProfilesPersistAndUseOnePrefix),
            ("Personal folders persist across prefix recreation", testSaveSnapshotsDoNotLeakBetweenProfiles),
            ("Path traversal and symlink escape rejection", testSavePathsRejectTraversalAndSymlinkEscape),
            ("Literal process arguments and verified engine selection", testLaunchPlanUsesLiteralArgumentsAndTheSharedPrefix),
            ("Dependencies and registry remain isolated between games", testDependencyIsolation),
            ("Non-destructive legacy migration and rollback source", testLegacyMigration)
        ]
        return cases.map { name, body in
            assertions.removeAll()
            do { try setUpWithError(); defer { try? tearDownWithError() }; try body()
                return ["name":name,"status":assertions.isEmpty ? "pass":"fail","detail":assertions.joined(separator:"; ")]
            } catch { return ["name":name,"status":"fail","detail":error.localizedDescription] }
        }
    }
    private var assertions=[String]()
    private func XCTAssertEqual<T:Equatable>(_ a:@autoclosure () throws -> T,_ b:T) rethrows {let actual=try a();if actual != b {assertions.append("Values differ: \(actual) != \(b)")}}
    private func XCTAssertNotEqual<T:Equatable>(_ a:T,_ b:T) {if a == b {assertions.append("Values unexpectedly equal")}}
    private func XCTAssertFalse(_ b:Bool) {if b {assertions.append("Expected false")}}
    private func XCTAssertNotNil<T>(_ x:T?) {if x == nil {assertions.append("Expected non-nil")}}
    private func XCTAssertThrowsError<T>(_ expression:@autoclosure () throws -> T) {do {_ = try expression();assertions.append("Expected operation to throw")}catch{}}

    var temporary:URL!
    func setUpWithError()throws{temporary=FileManager.default.temporaryDirectory.appendingPathComponent("ready-tests-"+UUID().uuidString);try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true)}
    func tearDownWithError()throws{try FileManager.default.removeItem(at:temporary)}
    func testValveManifestWithEscapesAndComments()throws{
        let kv=try KeyValues.parse("// Steam manifest\n\"AppState\" { \"appid\" \"42\" \"name\" \"A \\\"game\\\"\" \"nested\" { \"path\" \"C:\\\\Games\" } }")
        XCTAssertEqual(kv["AppState"]?["appid"]?.string,"42")
        XCTAssertEqual(kv["AppState"]?["name"]?.string,"A \"game\"")
        XCTAssertEqual(kv["AppState"]?["nested"]?["path"]?.string,"C:\\Games")
        XCTAssertThrowsError(try KeyValues.parse("\"broken\" { \"a\" \"b\""))
    }
    func testDistinguishesARM64IntelAndFatBinaries()throws{
        try XCTAssertEqual(try ArchitectureProbe.inspect(Data([0xcf,0xfa,0xed,0xfe,0x0c,0,0,1])),.arm64)
        try XCTAssertEqual(try ArchitectureProbe.inspect(Data([0xcf,0xfa,0xed,0xfe,7,0,0,1])),.x86_64)
        var fat=Data([0xca,0xfe,0xba,0xbe,0,0,0,2]);fat.append(contentsOf:[1,0,0,0x0c]);fat.append(Data(repeating:0,count:16));fat.append(contentsOf:[1,0,0,7]);fat.append(Data(repeating:0,count:16))
        try XCTAssertEqual(try ArchitectureProbe.inspect(fat),.universal)
        try XCTAssertEqual(try ArchitectureProbe.inspect(Data([0,1,2])),.unknown)
        XCTAssertEqual(GameVariant(id:"m",platform:.macOS).architecture,.unknown)
        XCTAssertFalse(GameVariant(id:"m",platform:.macOS).title.contains("Silicon"))
    }
    func testPrefixLeasePreventsConcurrentMutations()throws {
        let p=LauncherPaths(root:temporary),profile=UUID(),other=UUID()
        var first:PrefixLease?=try PrefixLease(paths:p,profile:profile,gameID:"gameA")
        XCTAssertNotNil(first)
        XCTAssertThrowsError(try PrefixLease(paths:p,profile:profile,gameID:"gameA"))
        let independent=try PrefixLease(paths:p,profile:profile,gameID:"gameB")
        let isolated=try PrefixLease(paths:p,profile:other,gameID:"gameA")
        XCTAssertNotNil(independent);XCTAssertNotNil(isolated)
        first=nil
        let second=try PrefixLease(paths:p,profile:profile,gameID:"gameA");XCTAssertNotNil(second)
    }
    func testProfilesPersistAndUseOnePrefix()throws {
        let paths=LauncherPaths(root:temporary),repo=LibraryRepository(paths:paths)
        var state=try repo.load();let first=state.activeProfile
        let second=Profile(name:"Secondo");state.profiles.append(second);state.activeProfile=second.id;try repo.save(state)
        let loaded=try repo.load();XCTAssertEqual(loaded.profiles.count,2);XCTAssertEqual(loaded.activeProfile,second.id)
        XCTAssertNotEqual(paths.prefix(profile:first,gameID:"a:b"),paths.prefix(profile:first,gameID:"a_b"))
        XCTAssertNotEqual(paths.prefix(profile:first,gameID:"gameA"),paths.prefix(profile:second.id,gameID:"gameA"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:paths.legacyPrefix.path))
    }
    func testSaveSnapshotsDoNotLeakBetweenProfiles()throws {
        let paths=LauncherPaths(root:temporary),manager=PrefixManager(paths:paths),a=UUID(),b=UUID()
        let pa=try manager.prepare(profile:a,gameID:"gameA",userName:"test"),pb=try manager.prepare(profile:b,gameID:"gameA",userName:"test")
        let docA=pa.appendingPathComponent("drive_c/users/test/Documents/save.dat"),docB=pb.appendingPathComponent("drive_c/users/test/Documents/save.dat")
        try Data("A saves".utf8).write(to:docA)
        XCTAssertFalse(FileManager.default.fileExists(atPath:docB.path))
        let ga=try manager.prepare(profile:a,gameID:"gameB",userName:"test")
        try XCTAssertEqual(try String(contentsOf:ga.appendingPathComponent("drive_c/users/test/Documents/save.dat")),"A saves")
        let privateA=pa.appendingPathComponent("drive_c/users/test/AppData/Local/account.json")
        try Data("A account".utf8).write(to:privateA)
        XCTAssertFalse(FileManager.default.fileExists(atPath:ga.appendingPathComponent("drive_c/users/test/AppData/Local/account.json").path))
        let backup=try manager.recreate(profile:a,gameID:"gameA")
        XCTAssertNotNil(backup)
        try XCTAssertEqual(try String(contentsOf:paths.profile(a).appendingPathComponent("Documents/save.dat")),"A saves")
        try XCTAssertEqual(try String(contentsOf:paths.gameData(profile:a,gameID:"gameA").appendingPathComponent("AppData/Local/account.json")),"A account")
        XCTAssertFalse(FileManager.default.fileExists(atPath:paths.profile(b).appendingPathComponent("Documents/save.dat").path))
    }
    func testDependencyIsolation()throws {
        let paths=LauncherPaths(root:temporary),manager=PrefixManager(paths:paths),profile=UUID()
        let a=try manager.prepare(profile:profile,gameID:"A"),b=try manager.prepare(profile:profile,gameID:"B")
        let dlls=temporary.appendingPathComponent("Engines/dxvk-verified");try FileManager.default.createDirectory(at:dlls,withIntermediateDirectories:true)
        try Data("renderer-v1".utf8).write(to:dlls.appendingPathComponent("d3d11.dll"))
        var cfg=RuntimeConfiguration(wine:"/usr/bin/true",engineDLLs:[GraphicsEngine.dxvkKosmic.rawValue:dlls.path])
        try EngineInstaller.configure(.dxvkKosmic,runtime:cfg,paths:paths,prefix:a)
        XCTAssertFalse(FileManager.default.fileExists(atPath:b.appendingPathComponent("drive_c/windows/system32/d3d11.dll").path))
        try XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath:a.appendingPathComponent("drive_c/windows/system32/d3d11.dll").path),dlls.appendingPathComponent("d3d11.dll").path)
        try Data("registry A".utf8).write(to:a.appendingPathComponent("user.reg"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:b.appendingPathComponent("user.reg").path))
        cfg.wineVersion="11.test";cfg.verifiedEngines=[GraphicsEngine.wineD3D.rawValue]
        let game=Game(id:"A",store:.local,storeID:"A",title:"A")
        let rule=CompatibilityRule(gameID:"A",wineVersion:"11.test",engines:[.d3dMetal,.wineD3D],verified:true,evidence:"Synthetic fixture: WineD3D only")
        try XCTAssertEqual(try RendererSelector.select(game:game,runtime:cfg,rules:[rule]),.wineD3D)
        XCTAssertThrowsError(try RendererSelector.select(game:game,runtime:cfg,rules:[rule],failed:[.wineD3D]))
    }
    func testLegacyMigration()throws {
        let paths=LauncherPaths(root:temporary);try paths.prepare()
        try FileManager.default.createDirectory(at:paths.legacyPrefix,withIntermediateDirectories:true)
        let registry=paths.legacyPrefix.appendingPathComponent("user.reg");try Data("original registry".utf8).write(to:registry)
        let profile=UUID(),games=[Game(id:"A",store:.local,storeID:"A",title:"A",variants:[.init(id:"windows",platform:.windows)])]
        let plan=try LegacyMigration.prepare(paths:paths,profile:profile,games:games)
        XCTAssertNotNil(plan)
        let migrated=try LegacyMigration.execute(plan!,paths:paths)
        XCTAssertEqual(migrated.status,"copied-awaiting-real-validation-original-retained")
        try Data("new registry".utf8).write(to:paths.prefix(profile:profile,gameID:"A").appendingPathComponent("user.reg"))
        try XCTAssertEqual(try String(contentsOf:registry),"original registry")
    }
    func testSavePathsRejectTraversalAndSymlinkEscape()throws{
        let prefix=temporary.appendingPathComponent("prefix");try FileManager.default.createDirectory(at:prefix,withIntermediateDirectories:true)
        XCTAssertThrowsError(try SafePath.resolve("../outside",under:prefix));XCTAssertThrowsError(try SafePath.resolve("/tmp/file",under:prefix))
        try FileManager.default.createSymbolicLink(at:prefix.appendingPathComponent("escape"),withDestinationURL:temporary)
        XCTAssertThrowsError(try SafePath.resolve("escape/outside",under:prefix))
    }
    func testLaunchPlanUsesLiteralArgumentsAndTheSharedPrefix()throws{
        let p=LauncherPaths(root:temporary);try p.prepare();let profile=UUID()
        let exe=temporary.appendingPathComponent("game with spaces;echo.exe");try Data([0x4d,0x5a]).write(to:exe)
        let variant=GameVariant(id:"w",platform:.windows,executable:exe.path,arguments:["--name","a;$(touch /tmp/no)"],installed:true)
        let g=Game(id:"1",store:.local,storeID:"1",title:"Game",variants:[variant],engine:.wineD3D)
        let cfg=RuntimeConfiguration(wine:"/usr/bin/true")
        let plan=try LaunchPlan.build(game:g,variant:variant,runtime:cfg,paths:p,profile:profile,overlay:nil,controlURL:p.session(UUID()).appendingPathComponent("control.json"))
        XCTAssertEqual(plan.environment["WINEPREFIX"],p.prefix(profile:profile,gameID:g.id).path);XCTAssertEqual(plan.arguments,[exe.path,"--name","a;$(touch /tmp/no)"])
        var unavailable=g;unavailable.engine = .d3dMetal
        XCTAssertThrowsError(try LaunchPlan.build(game:unavailable,variant:variant,runtime:cfg,paths:p,profile:profile,overlay:nil,controlURL:p.session(UUID()).appendingPathComponent("control.json")))
    }
}
