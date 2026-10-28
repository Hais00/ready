// This file is subject to the terms and conditions defined
// in file 'LICENSE', which is part of this source code package.

// SPDX-License-Identifier: GPL-2.0-only
using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Text.Json;
using SteamKit2;
namespace DepotDownloader;
static class ReadyDepotDownloadChecks
{
    static void Check(bool condition,string name,Dictionary<string,bool> checks){if(!condition)throw new Exception(name);checks[name]=true;}
    static uint Adler(byte[] value){using var memory=new MemoryStream(value);return BitConverter.ToUInt32(Util.AdlerHash(memory,value.Length));}
    static int Main(string[] args)
    {
        var checks=new Dictionary<string,bool>();var root=args[0];Directory.CreateDirectory(root);
        var final=Path.Combine(root,"game.bin");var staged=Path.Combine(root,"staging.bin");var recovery=Path.Combine(root,"archive");
        File.WriteAllBytes(final,new byte[]{0,0,0,0,66,66,66,66});File.WriteAllBytes(staged,new byte[]{65,65,65,65,0,0,0,0});
        var chunks=new List<DepotManifest.ChunkData>{new(){Offset=0,UncompressedLength=4,Checksum=Adler(new byte[]{65,65,65,65})},new(){Offset=4,UncompressedLength=4,Checksum=Adler(new byte[]{66,66,66,66})}};
        ReadyDownloadProgress.RecoverStaging(staged,final,chunks,recovery);
        Check(File.ReadAllBytes(final).SequenceEqual(new byte[]{65,65,65,65,66,66,66,66}),"staging-recovery-merges-only-valid-chunks",checks);
        Check(!File.Exists(staged)&&Directory.GetFiles(recovery).Length==1,"staging-original-archived-not-deleted",checks);
        File.WriteAllText(staged,"retained old bytes");File.Delete(final);ReadyDownloadProgress.RecoverStaging(staged,final,chunks,recovery);
        Check(File.ReadAllText(final)=="retained old bytes","missing-final-restores-staged-original",checks);
        ReadyDownloadProgress.Plan(16);ReadyDownloadProgress.Existing(4);ReadyDownloadProgress.Chunk(12,7);ReadyDownloadProgress.Finish(new(){{"1","42"}});
        Check(true,"numeric-verified-and-network-byte-accounting",checks);
        ReadyDownloadProgress.Plan(16);bool mismatch=false;try{ReadyDownloadProgress.Finish(new(){{"1","42"}});}catch(InvalidOperationException){mismatch=true;}
        Check(mismatch,"incomplete-byte-accounting-cannot-complete",checks);
        Console.WriteLine(JsonSerializer.Serialize(new{fixtureOnly=true,passed=true,checks,checkCount=checks.Count,realCDN=false,realAccount=false}));return 0;
    }
}
