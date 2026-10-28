// This file is subject to the terms and conditions defined
// in file 'LICENSE', which is part of this source code package.

// SPDX-License-Identifier: GPL-2.0-only
// Independent numeric-only progress bridge for the separate GPL-2 downloader.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using SteamKit2;
using System.Text.Json;
namespace DepotDownloader;
static class ReadyDownloadProgress
{
    static readonly object Gate=new();static ulong Total,Completed,Network;static long Last;
    static bool Enabled=>Environment.GetEnvironmentVariable("READY_DOWNLOAD_PROGRESS_JSON")=="1";
    static void Output(object value){if(Enabled)Console.WriteLine("READY_DOWNLOAD_V1 "+JsonSerializer.Serialize(value));}
    static void Emit(string kind,string phase,bool force=false){if(!Enabled)return;long now=Stopwatch.GetTimestamp();if(!force&&Last!=0&&(now-Last)/(double)Stopwatch.Frequency<0.2)return;Last=now;Output(new{kind,phase,totalBytes=Total,completedBytes=Completed,networkBytesReceived=Network});}
    internal static void Plan(ulong total){lock(Gate){Total=total;Completed=Network=0;Emit("plan","verifying",true);}}
    internal static void Existing(ulong size){lock(Gate){Completed+=size;Emit("progress","verifying");}}
    internal static void Chunk(ulong size,ulong compressed){lock(Gate){Completed+=size;Network+=compressed;Emit("progress","downloading");}}
    internal static void Error(string code){lock(Gate){Output(new{kind="error",code});}}
    internal static void Finish(Dictionary<string,string> manifests){lock(Gate){if(!Enabled)return;if(Completed!=Total||manifests.Count==0){Error("integrity_error");throw new InvalidOperationException("Ready verified byte accounting mismatch");}Output(new{kind="completed",phase="verifying",totalBytes=Total,completedBytes=Completed,networkBytesReceived=Network,manifests});}}
    internal static void RecoverStaging(string staged,string final,System.Collections.Generic.List<DepotManifest.ChunkData> chunks,string recovery)
    {
        if(!File.Exists(staged))return;
        if(!File.Exists(final)){File.Move(staged,final);return;}
        using(var old=File.Open(staged,FileMode.Open,FileAccess.Read,FileShare.Read))
        using(var current=File.Open(final,FileMode.Open,FileAccess.ReadWrite,FileShare.None))
        {
            foreach(var chunk in chunks)
            {
                long end=checked((long)chunk.Offset+chunk.UncompressedLength);
                bool valid=false;
                if(current.Length>=end){current.Position=(long)chunk.Offset;valid=Util.AdlerHash(current,(int)chunk.UncompressedLength).SequenceEqual(BitConverter.GetBytes(chunk.Checksum));}
                if(valid||old.Length<end)continue;
                old.Position=(long)chunk.Offset;
                if(!Util.AdlerHash(old,(int)chunk.UncompressedLength).SequenceEqual(BitConverter.GetBytes(chunk.Checksum)))continue;
                old.Position=(long)chunk.Offset;var bytes=new byte[chunk.UncompressedLength];old.ReadExactly(bytes);
                current.Position=(long)chunk.Offset;current.Write(bytes);current.Flush(true);
            }
        }
        Directory.CreateDirectory(recovery);File.Move(staged,Path.Combine(recovery,Guid.NewGuid().ToString("N")+".partial"));
    }
    internal static void Exception(Exception error){string code=error is System.Net.Http.HttpRequestException||error is System.TimeoutException?"network_error":error is System.IO.IOException io&&(io.HResult&0xffff) is 28 or 112?"disk_full":error is System.IO.IOException?"local_io":error is OperationCanceledException?"engine_cancelled":"download_failed";Error(code);}
}
