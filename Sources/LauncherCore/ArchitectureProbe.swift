import Foundation

public enum ArchitectureProbe {
    public static func inspect(_ url: URL) throws -> BinaryArchitecture { try inspect(Data(contentsOf:url,options:.mappedIfSafe)) }
    public static func inspect(_ data:Data) throws -> BinaryArchitecture {
        func u32(_ at:Int, _ little:Bool)->UInt32? {
            guard at >= 0,at+4<=data.count else{return nil}
            return (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[at+$1]) << UInt32((little ? $1:3-$1)*8) }
        }
        guard let magic=u32(0,false) else{return .unknown}
        if magic==0xcafebabe || magic==0xbebafeca || magic==0xcafebabf || magic==0xbfbafeca {
            let little=magic==0xbebafeca || magic==0xbfbafeca
            guard let count=u32(4,little), count<=64 else{return .unknown}
            let stride=magic==0xcafebabf || magic==0xbfbafeca ? 32:20
            var arm=false,x64=false
            for i in 0..<Int(count) { let cpu=u32(8+i*stride,little);arm = arm || cpu==0x0100000c;x64 = x64 || cpu==0x01000007 }
            return arm && x64 ? .universal : arm ? .arm64 : x64 ? .x86_64 : .unknown
        }
        if [UInt32(0xfeedfacf),0xcffaedfe,0xfeedface,0xcefaedfe].contains(magic) {
            let little=magic==0xcffaedfe || magic==0xcefaedfe
            switch u32(4,little) { case 0x0100000c:return .arm64;case 0x01000007:return .x86_64;case 7:return .x86;default:return .unknown }
        }
        if data.count>=64,data[0]==0x4d,data[1]==0x5a,let pe=u32(0x3c,true),pe<UInt32(data.count),Int(pe)+6<=data.count,u32(Int(pe),true)==0x00004550 {
            let machine=UInt16(data[Int(pe)+4])|UInt16(data[Int(pe)+5])<<8
            switch machine { case 0xaa64:return .arm64;case 0x8664:return .x86_64;case 0x14c:return .x86;default:return .unknown }
        }
        return .unknown
    }
    public static func applicationExecutable(_ app:URL)->URL? {
        guard let plist=NSDictionary(contentsOf:app.appendingPathComponent("Contents/Info.plist")),let exe=plist["CFBundleExecutable"] as? String,!exe.contains("/") else{return nil}
        return app.appendingPathComponent("Contents/MacOS/"+exe)
    }
}
