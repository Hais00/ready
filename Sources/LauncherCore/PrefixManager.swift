// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Personal data is outside disposable Wine prefixes. AppData remains isolated by game AND profile.
public final class PrefixManager {
    public let paths:LauncherPaths
    public init(paths:LauncherPaths){self.paths=paths}
    @discardableResult
    public func prepare(profile:UUID,gameID:String,userName:String=NSUserName())throws->URL {
        try paths.prepare()
        let fm=FileManager.default,prefix=paths.prefix(profile:profile,gameID:gameID)
        let user=prefix.appendingPathComponent("drive_c/users/"+SafePath.component(userName))
        let personal=paths.profile(profile),privateData=paths.gameData(profile:profile,gameID:gameID)
        try fm.createDirectory(at:user,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let links:[(String,URL)]=[
            ("Documents",personal.appendingPathComponent("Documents")),
            ("My Documents",personal.appendingPathComponent("Documents")),
            ("Saved Games",personal.appendingPathComponent("Saved Games")),
            ("AppData",privateData.appendingPathComponent("AppData"))
        ]
        for (name,target) in links {
            try fm.createDirectory(at:target,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try redirect(user.appendingPathComponent(name),to:target,prefix:prefix)
        }
        for name in ["Local","LocalLow","Roaming"]{try fm.createDirectory(at:privateData.appendingPathComponent("AppData/"+name),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
        let reg="""
        Windows Registry Editor Version 5.00

        [HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders]
        "Personal"="C:\\\\users\\\\\(SafePath.component(userName))\\\\Documents"
        "{4C5C32FF-BB9D-43B0-B5B4-2D72E54EAAA4}"="C:\\\\users\\\\\(SafePath.component(userName))\\\\Saved Games"
        "AppData"="C:\\\\users\\\\\(SafePath.component(userName))\\\\AppData\\\\Roaming"
        "Local AppData"="C:\\\\users\\\\\(SafePath.component(userName))\\\\AppData\\\\Local"

        """
        let config=prefix.appendingPathComponent(".ready");try fm.createDirectory(at:config,withIntermediateDirectories:true)
        try AtomicFile.writePrivate(Data(reg.utf8),to:config.appendingPathComponent("folders.reg"))
        return prefix
    }
    private func redirect(_ source:URL,to target:URL,prefix:URL)throws {
        let fm=FileManager.default
        if let link=try? fm.destinationOfSymbolicLink(atPath:source.path) {
            let existing=URL(fileURLWithPath:link,relativeTo:source.deletingLastPathComponent()).standardizedFileURL.resolvingSymlinksInPath()
            if existing==target.standardizedFileURL.resolvingSymlinksInPath(){return}
            // Remove only the link itself: NEVER walk Wine's default links into the host's Documents.
            try fm.removeItem(at:source)
        }else if fm.fileExists(atPath:source.path){
            let backup=paths.root.appendingPathComponent("Backups/redirect-"+UUID().uuidString)
            try fm.createDirectory(at:backup.deletingLastPathComponent(),withIntermediateDirectories:true)
            let originalContents=(try? fm.contentsOfDirectory(at:source,includingPropertiesForKeys:nil)) ?? []
            for item in originalContents {
                let dest=target.appendingPathComponent(item.lastPathComponent)
                if !fm.fileExists(atPath:dest.path){try fm.copyItem(at:item,to:dest)}
                else{let conflicts=target.appendingPathComponent("Imported-"+UUID().uuidString);try fm.createDirectory(at:conflicts,withIntermediateDirectories:true);try fm.copyItem(at:item,to:conflicts.appendingPathComponent(item.lastPathComponent))}
            }
            try fm.moveItem(at:source,to:backup)
        }
        try fm.createSymbolicLink(at:source,withDestinationURL:target)
    }
    /// Never deletes the old prefix. Caller gets a rollback path, and personal directories are reused.
    @discardableResult
    public func recreate(profile:UUID,gameID:String)throws->URL? {
        let lease=try PrefixLease(paths:paths,profile:profile,gameID:gameID)
        return try withExtendedLifetime(lease){
            let prefix=paths.prefix(profile:profile,gameID:gameID),fm=FileManager.default
            var backup:URL?
            if fm.fileExists(atPath:prefix.path){
                let b=paths.root.appendingPathComponent("Backups/prefix-"+UUID().uuidString)
                try fm.createDirectory(at:b.deletingLastPathComponent(),withIntermediateDirectories:true);try fm.moveItem(at:prefix,to:b);backup=b
            }
            do{try prepare(profile:profile,gameID:gameID);return backup}
            catch{if let backup {if fm.fileExists(atPath:prefix.path){try fm.removeItem(at:prefix)};try fm.moveItem(at:backup,to:prefix)};throw error}
        }
    }
}

public struct LegacyMigrationPlan:Codable {
    public var id:UUID
    public var source:String
    public var ownerProfile:UUID
    public var destinations:[String:String]
    public var status:String
    public var warning:String
}
public enum LegacyMigration {
    /// Preparation is deliberately non-destructive. Never guess ownership of old mixed-account data.
    public static func prepare(paths:LauncherPaths,profile:UUID,games:[Game])throws->LegacyMigrationPlan? {
        guard FileManager.default.fileExists(atPath:paths.legacyPrefix.path) else{return nil}
        let directory=paths.root.appendingPathComponent("Migration");try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let plan=LegacyMigrationPlan(id:UUID(),source:paths.legacyPrefix.path,ownerProfile:profile,destinations:Dictionary(uniqueKeysWithValues:games.filter{$0.variants.contains{$0.platform == .windows}}.map{($0.id,paths.prefix(profile:profile,gameID:$0.id).path)}),status:"prepared-original-untouched",warning:"The legacy prefix may contain mixed accounts. Assign its data to the correct profile before executing migration. Keep the original until real games and saves have been verified.")
        try AtomicFile.writePrivate(JSONEncoder().encode(plan),to:directory.appendingPathComponent("plan.json"))
        return plan
    }
    /// Clone only on explicit execution after assigning legacy ownership. No hard links: registry writes must remain isolated.
    public static func execute(_ plan:LegacyMigrationPlan,paths:LauncherPaths)throws->LegacyMigrationPlan {
        guard plan.source==paths.legacyPrefix.path,plan.status=="prepared-original-untouched" else{throw LauncherError.invalid("Piano di migrazione non valido")}
        let fm=FileManager.default
        var leases=[PrefixLease]()
        for id in plan.destinations.keys.sorted(){leases.append(try PrefixLease(paths:paths,profile:plan.ownerProfile,gameID:id))}
        return try withExtendedLifetime(leases){
            // Validate ALL destinations before changing any of them.
            for (id,path) in plan.destinations {
                guard paths.prefix(profile:plan.ownerProfile,gameID:id).path==path,!fm.fileExists(atPath:path) else{throw LauncherError.invalid("Destinazione già presente o non valida; originali conservati")}
            }
            let journal=paths.root.appendingPathComponent("Migration/journal.json")
            var created=[URL]()
            do {
                for (id,path) in plan.destinations.sorted(by:{$0.key<$1.key}){
                    let expected=URL(fileURLWithPath:path)
                    try fm.createDirectory(at:expected.deletingLastPathComponent(),withIntermediateDirectories:true)
                    created.append(expected)
                    try AtomicFile.writePrivate(JSONEncoder().encode(created.map{$0.path}),to:journal)
                    try fm.copyItem(at:paths.legacyPrefix,to:expected)
                    try PrefixManager(paths:paths).prepare(profile:plan.ownerProfile,gameID:id)
                }
            } catch {
                // Roll back only copies created by this attempt. Preserve both legacy and personal data.
                for destination in created.reversed(){if fm.fileExists(atPath:destination.path){try? fm.removeItem(at:destination)}}
                throw error
            }
            var result=plan;result.status="copied-awaiting-real-validation-original-retained"
            try AtomicFile.writePrivate(JSONEncoder().encode(result),to:paths.root.appendingPathComponent("Migration/plan.json"))
            return result
        }
    }
}
