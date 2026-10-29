// SPDX-License-Identifier: GPL-3.0-only
using System.Globalization;
using System.Net;
using System.Text.Json;
using System.Text.RegularExpressions;
using SteamKit2;

// Public catalog data is descriptive, never evidence of ownership or executable
// architecture. PICS library enumeration performs no HTTP requests.
static class SteamCatalogMetadata
{
    internal static string Clean(string? value,int maximum=4096)
    {
        if(string.IsNullOrEmpty(value))return "";
        value=Regex.Replace(value,"<(script|style)\\b[^>]*>.*?</\\1>","",RegexOptions.IgnoreCase|RegexOptions.Singleline,TimeSpan.FromSeconds(1));
        value=Regex.Replace(value,"<[^>]*>"," ",RegexOptions.None,TimeSpan.FromSeconds(1));
        value=WebUtility.HtmlDecode(value);
        value=new string(value.Where(c=>!char.IsControl(c)||c=='\n'||c=='\t').ToArray()).Trim();
        return value.Length>maximum?value[..maximum]:value;
    }
    internal static string? ContentType(string? value)
    {
        string text=Clean(value,64).ToLowerInvariant();
        return text.Length>0&&text.All(c=>char.IsAsciiLetterOrDigit(c)||c=='_')?text:null;
    }
    internal static bool IsLibraryApp(KeyValue? values)
    {
        string type=values?["common"]["type"].Value?.ToLowerInvariant()??"";
        return type is "" or "game" or "application" or "demo" or "software";
    }
    static string[] Platforms(IEnumerable<string?> oslists)=>oslists.Where(x=>x is not null)
        .SelectMany(x=>x!.Split(',',StringSplitOptions.RemoveEmptyEntries|StringSplitOptions.TrimEntries))
        .Select(x=>x.ToLowerInvariant()).Select(x=>x is "macos" or "mac" or "osx"?"macOS":x)
        .Where(x=>x is "windows" or "macOS").Distinct().OrderBy(x=>x=="windows"?0:1).ToArray();
    internal static string[] PICSPlatforms(KeyValue? values)
    {
        if(values is null)return Array.Empty<string>();
        var sources=new List<string?>{values["common"]["oslist"].Value};
        sources.AddRange(values["config"]["launch"].Children.Select(x=>x["config"]["oslist"].Value));
        sources.AddRange(values["depots"].Children.Select(x=>x["config"]["oslist"].Value));
        return Platforms(sources);
    }
    static bool Hash(string? text)=>text is {Length:40}&&text.All(Uri.IsHexDigit);
    internal static string? ImageURL(string? value)
    {
        if(value is null||value.Length>2048||!Uri.TryCreate(value,UriKind.Absolute,out var uri)||uri.Scheme!="https"||!uri.IsDefaultPort||uri.UserInfo.Length!=0||uri.Fragment.Length!=0)return null;
        return uri.Host.EndsWith(".steamstatic.com",StringComparison.OrdinalIgnoreCase)||uri.Host.EndsWith(".steamusercontent.com",StringComparison.OrdinalIgnoreCase)?uri.AbsoluteUri:null;
    }
    static string? Asset(uint id,KeyValue common,string key)
    {
        foreach(string group in new[]{"library_assets_full","library_assets"})
        {
            var node=common[group][key];
            var candidates=new[]{node.Value,node["english"].Value,node["image"]["english"].Value,node["image"].Value};
            foreach(string? candidate in candidates)
            {
                if(string.IsNullOrWhiteSpace(candidate))continue;
                string path=candidate;
                // Older PICS marks an offered English library asset by language
                // code instead of a filename. Use only the corresponding Steam
                // library filename, never turn an arbitrary flag into a URL.
                if(path is "en" or "english")path=key switch{"library_capsule"=>"library_600x900.jpg","library_hero"=>"library_hero.jpg","header"=>"header.jpg",_=>""};
                if(path.Length==0)continue;
                if(ImageURL(path) is {} absolute)return absolute;
                if(path.Length<=256&&new[]{".jpg",".jpeg",".png",".webp",".avif"}.Any(extension=>path.EndsWith(extension,StringComparison.OrdinalIgnoreCase))&&!path.Contains("..")&&path.All(c=>char.IsAsciiLetterOrDigit(c)||c is '/' or '_' or '-' or '.'))
                    return $"https://cdn.akamai.steamstatic.com/steam/apps/{id}/{path}";
            }
        }
        return null;
    }
    static string[] Associations(KeyValue common,string type)=>common["associations"].Children
        .Where(x=>string.Equals(x["type"].Value,type,StringComparison.OrdinalIgnoreCase)).Select(x=>Clean(x["name"].Value,256)).Where(x=>x.Length>0).Distinct().Take(64).ToArray();
    internal static object LibraryGame(uint id,KeyValue? values)
    {
        var common=values?["common"]??new KeyValue("common");string[] platforms=PICSPlatforms(values);
        string? icon=Hash(common["icon"].Value)?$"https://cdn.akamai.steamstatic.com/steamcommunity/public/images/apps/{id}/{common["icon"].Value}.jpg":null;
        string? capsule=Asset(id,common,"library_capsule"),hero=Asset(id,common,"library_hero"),banner=Asset(id,common,"header");
        // Standard CDN addresses are candidates when PICS omits publisher art.
        // They may return 404; consumers must retain their normal icon fallback.
        string fallbackCapsule=$"https://cdn.akamai.steamstatic.com/steam/apps/{id}/library_600x900.jpg";
        string fallbackBanner=$"https://cdn.akamai.steamstatic.com/steam/apps/{id}/header.jpg";
        var metadata=new Dictionary<string,object?>{
            ["launch"]=values?["config"]["launch"].Children.Select(k=>new{executable=k["executable"].Value,arguments=k["arguments"].Value,workingdir=k["workingdir"].Value,@type=k["type"].Value,description=k["description"].Value,oslist=k["config"]["oslist"].Value,osarch=k["config"]["osarch"].Value}).ToArray()??Array.Empty<object>(),
            ["storeURL"]=$"https://store.steampowered.com/app/{id}/",["iconURL"]=icon,["capsuleURL"]=capsule??fallbackCapsule,["heroURL"]=hero??icon,["bannerURL"]=banner??fallbackBanner,["artworkFallbacksUnverified"]=capsule is null||banner is null,
            ["developers"]=Associations(common,"developer"),["publishers"]=Associations(common,"publisher"),["genres"]=Array.Empty<string>(),["downloadableVariants"]=platforms,["metadataComplete"]=false};
        if(long.TryParse(common["steam_release_date"].Value,out var released))try{metadata["releaseDate"]=DateTimeOffset.FromUnixTimeSeconds(released).ToString("yyyy-MM-dd",CultureInfo.InvariantCulture);}catch(ArgumentOutOfRangeException){}
        string title=Clean(common["name"].Value,512);
        if(title.Length>0)metadata["title"]=title;
        if(ContentType(common["type"].Value)is{} contentType)metadata["contentType"]=contentType;
        return new{id=$"steam:{id}",store="steam",storeID=id.ToString(CultureInfo.InvariantCulture),title=title.Length>0?title:id.ToString(CultureInfo.InvariantCulture),artworkURL=capsule??icon??fallbackCapsule,
            variants=platforms.Select(platform=>new{id=platform,platform,architecture="unknown",installed=false,arguments=Array.Empty<string>(),verification="Steam platform metadata; inspect local binary to confirm architecture"}).ToArray(),engine="automatic",saveRules=Array.Empty<object>(),metadata};
    }
    internal static Dictionary<string,object?> ParseDetails(uint id,JsonElement root)
    {
        if(!root.TryGetProperty(id.ToString(CultureInfo.InvariantCulture),out var app)||!app.TryGetProperty("success",out var success)||success.ValueKind!=JsonValueKind.True||!app.TryGetProperty("data",out var data)||!data.TryGetProperty("steam_appid",out var returned)||!returned.TryGetUInt32(out uint appID)||appID!=id)throw new InvalidDataException();
        string Text(string key,int maximum=4096)=>data.TryGetProperty(key,out var item)&&item.ValueKind==JsonValueKind.String?Clean(item.GetString(),maximum):"";
        string[] Names(string key)=>data.TryGetProperty(key,out var array)&&array.ValueKind==JsonValueKind.Array?array.EnumerateArray().Where(x=>x.ValueKind==JsonValueKind.String).Select(x=>Clean(x.GetString(),256)).Where(x=>x.Length>0).Distinct().Take(64).ToArray():Array.Empty<string>();
        string? Image(string key)=>data.TryGetProperty(key,out var item)&&item.ValueKind==JsonValueKind.String?ImageURL(item.GetString()):null;
        string[] genres=data.TryGetProperty("genres",out var genreArray)&&genreArray.ValueKind==JsonValueKind.Array?genreArray.EnumerateArray().Where(x=>x.ValueKind==JsonValueKind.Object&&x.TryGetProperty("description",out var value)&&value.ValueKind==JsonValueKind.String).Select(x=>Clean(x.GetProperty("description").GetString(),256)).Where(x=>x.Length>0).Distinct().Take(64).ToArray():Array.Empty<string>();
        var platforms=new List<string>();if(data.TryGetProperty("platforms",out var os)&&os.ValueKind==JsonValueKind.Object){foreach(var pair in new[]{("windows","windows"),("mac","macOS")})if(os.TryGetProperty(pair.Item1,out var offered)&&offered.ValueKind==JsonValueKind.True)platforms.Add(pair.Item2);}
        string release="";if(data.TryGetProperty("release_date",out var date)&&date.ValueKind==JsonValueKind.Object&&date.TryGetProperty("date",out var text)&&text.ValueKind==JsonValueKind.String)release=Clean(text.GetString(),128);
        string description=Text("about_the_game",65536);if(description.Length==0)description=Text("short_description",8192);
        var result=new Dictionary<string,object?>{["shortDescription"]=Text("short_description",8192),["description"]=description,["developers"]=Names("developers"),["publishers"]=Names("publishers"),["genres"]=genres,["releaseDate"]=release,["storeURL"]=$"https://store.steampowered.com/app/{id}/",["downloadableVariants"]=platforms.ToArray(),["metadataComplete"]=true};
        string title=Text("name",512);if(title.Length>0)result["title"]=title;
        if(ContentType(Text("type",64))is{} contentType)result["contentType"]=contentType;
        // Do not erase genuine PICS icons/heroes when Store supplies no such field.
        if(Image("header_image") is {} header)result["bannerURL"]=header;
        if((Image("background_raw")??Image("background")) is {} background)result["heroURL"]=background;
        if((Image("capsule_imagev5")??Image("capsule_image")) is {} capsule)result["capsuleURL"]=capsule;
        return result;
    }
}

sealed class SteamPublicCatalog
{
    const int MaximumBytes=4*1024*1024,MaximumCached=256;
    readonly HttpClient http;
    readonly SemaphoreSlim requests=new(2,2);
    readonly object sync=new();
    readonly Dictionary<string,(DateTimeOffset At,Dictionary<string,object?> Value)> cache=new();
    internal SteamPublicCatalog(HttpClient? http=null)=>this.http=http??new HttpClient(new HttpClientHandler{AllowAutoRedirect=false}){Timeout=Timeout.InfiniteTimeSpan};
    internal static string Language(string value)
    {if(value.Length is <1 or >32||!value.All(c=>char.IsAsciiLetter(c)||c is '_' or '-'))throw new ArgumentException();return value.ToLowerInvariant();}
    internal async Task<Dictionary<string,object?>> DetailsAsync(uint appID,string language,CancellationToken cancel)
    {
        if(appID==0)throw new ArgumentException();language=Language(language);string key=$"{appID}:{language}";
        Dictionary<string,object?>? Cached(){lock(sync)return cache.TryGetValue(key,out var entry)&&DateTimeOffset.UtcNow-entry.At<TimeSpan.FromHours(6)?new(entry.Value):null;}
        cancel.ThrowIfCancellationRequested();if(Cached() is {} cached)return cached;
        using var budget=CancellationTokenSource.CreateLinkedTokenSource(cancel);budget.CancelAfter(TimeSpan.FromSeconds(12));
        await requests.WaitAsync(budget.Token);
        try
        {
            if(Cached() is {} existing)return existing;
            using var reply=await http.GetAsync($"https://store.steampowered.com/api/appdetails?appids={appID}&l={language}",HttpCompletionOption.ResponseHeadersRead,budget.Token);reply.EnsureSuccessStatusCode();
            if(reply.Content.Headers.ContentLength>MaximumBytes)throw new InvalidDataException();
            using var body=await reply.Content.ReadAsStreamAsync(budget.Token);using var bytes=new MemoryStream();byte[] buffer=new byte[16384];int count;
            while((count=await body.ReadAsync(buffer,budget.Token))>0){if(bytes.Length+count>MaximumBytes)throw new InvalidDataException();bytes.Write(buffer,0,count);}
            using var document=JsonDocument.Parse(bytes.ToArray());var metadata=SteamCatalogMetadata.ParseDetails(appID,document.RootElement);
            lock(sync){if(cache.Count>=MaximumCached)cache.Remove(cache.MinBy(pair=>pair.Value.At).Key);cache[key]=(DateTimeOffset.UtcNow,metadata);}
            return new(metadata);
        }
        finally{requests.Release();}
    }
}

sealed class SteamLibraryPayloadException(string code):Exception
{internal string Code {get;}=code;}
// The caller commits pages only after the terminal counts match. Keep pages well
// below the service/client 4 MiB line limit, including their authenticated envelope.
sealed class SteamLibraryPages(bool paged,Action<object[],int> emit)
{
    const int MaximumPageBytes=1024*1024-2048;
    readonly HashSet<string> ids=new(StringComparer.Ordinal);
    readonly List<object> all=new(),pending=new();
    int bytes=2;
    internal int GameCount {get;private set;}
    internal int PageCount {get;private set;}
    internal void Add(IEnumerable<object> games)
    {
        foreach(object game in games)
        {
            byte[] encoded=JsonSerializer.SerializeToUtf8Bytes(game);
            using var document=JsonDocument.Parse(encoded);
            if(!document.RootElement.TryGetProperty("id",out var field)||field.ValueKind!=JsonValueKind.String||field.GetString() is not {Length:>0 and <=128} id)throw new SteamLibraryPayloadException("invalid_library_entry");
            if(!ids.Add(id))throw new SteamLibraryPayloadException("library_duplicate_entry");
            if(++GameCount>20000)throw new SteamLibraryPayloadException("library_too_large");
            if(!paged){all.Add(game);continue;}
            if(encoded.Length+2>MaximumPageBytes)throw new SteamLibraryPayloadException("library_entry_too_large");
            if(pending.Count>=50||bytes+encoded.Length+1>MaximumPageBytes)Flush();
            pending.Add(game);bytes+=encoded.Length+1;
        }
    }
    void Flush(){if(pending.Count==0)return;emit(pending.ToArray(),PageCount++);pending.Clear();bytes=2;}
    internal Dictionary<string,object?> Complete()
    {
        if(paged){Flush();return new(){["gameCount"]=GameCount,["pageCount"]=PageCount};}
        return new(){["games"]=all,["gameCount"]=GameCount};
    }
}
