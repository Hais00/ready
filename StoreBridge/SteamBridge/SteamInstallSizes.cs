// SPDX-License-Identifier: GPL-3.0-only
using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using SteamKit2;

sealed record SteamSizeRequest(uint AppID,string Platform,string Branch="public",string Language="english",string Architecture="64")
{
    internal static SteamSizeRequest Create(uint app,string platform,string branch,string language,string architecture)
    {
        if(app==0||platform is not ("windows" or "macOS")||architecture!="64"||branch.Length is <1 or >64||!branch.All(c=>char.IsAsciiLetterOrDigit(c)||c is '_' or '-'))throw new ArgumentException();
        return new(app,platform,branch,SteamPublicCatalog.Language(language),architecture);
    }
}
sealed record SteamSelectedDepot(uint DepotID,uint SourceAppID,ulong ManifestID,ulong DownloadBytes,ulong InstalledBytes);
// Package metadata can be reused within exactly one account/license snapshot.
// Depot-key authorization remains a fresh server request for each install plan.
sealed class SteamSizeEntitlementCache
{
    readonly object sync=new();object? scope;ulong account;IReadOnlySet<uint>? value;
    internal IReadOnlySet<uint>? Get(object current,ulong self){lock(sync)return ReferenceEquals(scope,current)&&account==self?value:null;}
    internal void Store(object current,ulong self,IEnumerable<uint> ids){lock(sync){scope=current;account=self;value=new HashSet<uint>(ids);}}
    internal void Invalidate(){lock(sync){scope=null;account=0;value=null;}}
}
sealed class SteamSizePlan
{
    internal required SteamSizeRequest Request;
    internal ulong? DownloadBytes,InstalledBytes,RequiredBytes;
    internal bool Verified;
    internal string Source="steam_pics",Status="unavailable",Reason="metadata_unavailable";
    internal List<SteamSelectedDepot> Depots=new();
    internal string[] Assumptions={"Compressed depot payload, not wire bytes or resume delta","Sum of uncompressed depot payload; overlaps and filesystem overhead are not measured","Cache/staging/peak disk usage is not known"};
    internal Dictionary<string,object?> Payload()
    {
        string fingerprint=Convert.ToHexString(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(new{Request.AppID,Request.Platform,Request.Branch,Request.Language,Request.Architecture,depots=Depots.OrderBy(x=>x.DepotID)}))).ToLowerInvariant();
        return new(){["platform"]=Request.Platform,["branch"]=Request.Branch,["language"]=Request.Language,["architecture"]=Request.Architecture,["downloadBytes"]=DownloadBytes,["installedBytes"]=InstalledBytes,["requiredBytes"]=RequiredBytes,["peakDiskBytes"]=null,["verified"]=Verified,["source"]=Source,["basis"]="selected_depot_payload_totals",["status"]=Status,["reason"]=Reason,["selectedDepotCount"]=Depots.Count,["selectedDepots"]=Depots.Select(x=>new{depotID=x.DepotID,sourceAppID=x.SourceAppID,manifestID=x.ManifestID,downloadBytes=x.DownloadBytes,installedBytes=x.InstalledBytes}).ToArray(),["fingerprint"]=fingerprint,["calculatedAt"]=DateTimeOffset.UtcNow.ToString("O"),["assumptions"]=Assumptions};
    }
    public override string ToString()=>"[Steam install size plan]";
}
static class SteamInstallSizes
{
    internal static SteamSizePlan Unknown(SteamSizeRequest request,string reason)=>new(){Request=request,Reason=reason};
    internal static HashSet<uint>? PackageEntitlements(IEnumerable<uint> requested,IReadOnlyDictionary<uint,KeyValue> packages)
        =>PackageEntitlements(requested,packages,out _);
    internal static HashSet<uint>? PackageEntitlements(IEnumerable<uint> requested,IReadOnlyDictionary<uint,KeyValue> packages,out string reason)
    {
        reason="ownership_package_missing";
        var result=new HashSet<uint>();
        foreach(uint id in requested.Distinct())
        {
            if(!packages.TryGetValue(id,out var values)||values==KeyValue.Invalid)return null;
            foreach(string section in new[]{"appids","depotids"})foreach(var item in values[section].Children)
            {
                if(!uint.TryParse(item.Value,out uint depot)){reason="ownership_package_invalid_id";return null;}
                if(depot>0)result.Add(depot); // Zero is not an app/depot entitlement.
            }
        }
        reason="";
        return result;
    }

    static bool Number(string? value,out ulong result)=>ulong.TryParse(value,NumberStyles.None,CultureInfo.InvariantCulture,out result);
    internal static SteamSizePlan Build(SteamSizeRequest request,IReadOnlyDictionary<uint,KeyValue> apps,IReadOnlySet<uint>? entitledDepots=null)
    {
        var plan=Unknown(request,"metadata_unavailable");
        if(request.Branch!="public")return Unknown(request,"branch_not_supported");
        if(request.Language!="english")return Unknown(request,"language_not_supported");
        if(!apps.TryGetValue(request.AppID,out var app))return plan;
        if(!SteamCatalogMetadata.PICSPlatforms(app).Contains(request.Platform))return Unknown(request,"platform_unavailable");
        var depots=app["depots"].Children.Where(x=>uint.TryParse(x.Name,out var id)&&id>0&&x.Children.Count>0).ToArray();
        if(depots.Length>256)return Unknown(request,"too_many_depots");
        ulong download=0,installed=0;
        foreach(var depot in depots)
        {
            var config=depot["config"];string os=request.Platform=="macOS"?"macos":"windows";
            string? platforms=config["oslist"].Value,arch=config["osarch"].Value,language=config["language"].Value;
            if(!string.IsNullOrWhiteSpace(platforms)&&!platforms.Split(',').Contains(os))continue;
            if(!string.IsNullOrWhiteSpace(arch)&&arch!=request.Architecture)continue;
            if(!string.IsNullOrWhiteSpace(language)&&language!=request.Language)continue;
            if(config["lowviolence"].Value is "1" or "true")continue;
            uint id=uint.Parse(depot.Name!,CultureInfo.InvariantCulture);
            bool free=app["common"]["FreeToDownload"].Value is "1" or "true";
            if(entitledDepots is not null&&!free&&!entitledDepots.Contains(id))continue;
            if(entitledDepots is null&&(depot["dlcappid"].Value is{} dlc&&dlc!="0"))return Unknown(request,"dlc_ownership_unknown");
            var source=depot;uint sourceApp=request.AppID;var seen=new HashSet<uint>{sourceApp};
            while(source["manifests"].Children.Count==0&&uint.TryParse(source["depotfromapp"].Value,out uint parent)&&parent>0)
            {
                if(!seen.Add(parent)||seen.Count>8)return Unknown(request,"shared_depot_cycle");
                if(!apps.TryGetValue(parent,out var parentInfo))return Unknown(request,"shared_depot_metadata_missing");
                sourceApp=parent;source=parentInfo["depots"][depot.Name!];
            }
            var manifest=source["manifests"][request.Branch];
            if(!Number(manifest["gid"].Value,out ulong gid)||gid==0||gid==ulong.MaxValue||!Number(manifest["size"].Value,out ulong bytes)||!Number(manifest["download"].Value,out ulong compressed))return Unknown(request,"manifest_size_unavailable");
            try{download=checked(download+compressed);installed=checked(installed+bytes);}catch(OverflowException){return Unknown(request,"size_overflow");}
            plan.Depots.Add(new(id,sourceApp,gid,compressed,bytes));
        }
        if(plan.Depots.Count==0)return Unknown(request,"no_selected_depots");
        plan.DownloadBytes=download;plan.InstalledBytes=installed;plan.Status="available";plan.Reason=entitledDepots is null?"account_selection_unverified":"depot_access_check_required";return plan;
    }
    internal static Dictionary<string,object?> Overview(uint app,KeyValue? info)
    {
        var apps=new Dictionary<uint,KeyValue>();if(info is not null)apps[app]=info;
        return new[]{"windows","macOS"}.ToDictionary(platform=>platform,platform=>(object?)Build(new(app,platform),apps).Payload());
    }
    internal static ulong? MinimumRequirement(JsonElement data,string key)
    {
        if(!data.TryGetProperty(key,out var requirements)||requirements.ValueKind!=JsonValueKind.Object||!requirements.TryGetProperty("minimum",out var item)||item.ValueKind!=JsonValueKind.String)return null;
        // Only explicitly labelled storage, never the first RAM/VRAM number.
        var match=Regex.Match(item.GetString()??"",@"(?:Storage|Hard Drive|Hard Disk Space)\s*:\s*(?:</[^>]+>\s*)?([0-9]+(?:[.,][0-9]+)?)\s*(GiB|MiB|TiB|GB|MB|TB)\b",RegexOptions.IgnoreCase,TimeSpan.FromSeconds(1));
        if(!match.Success||!decimal.TryParse(match.Groups[1].Value.Replace(',','.'),NumberStyles.AllowDecimalPoint,CultureInfo.InvariantCulture,out var value))return null;
        decimal factor=match.Groups[2].Value.ToUpperInvariant() switch{"MB"=>1000000m,"GB"=>1000000000m,"TB"=>1000000000000m,"MIB"=>1048576m,"GIB"=>1073741824m,"TIB"=>1099511627776m,_=>0};
        try{decimal bytes=checked(value*factor);return bytes>=0&&bytes<=ulong.MaxValue&&decimal.Truncate(bytes)==bytes?(ulong)bytes:null;}catch(OverflowException){return null;}
    }
}
