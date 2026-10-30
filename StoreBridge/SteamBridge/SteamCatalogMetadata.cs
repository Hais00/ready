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
    internal static string LibraryKind(string? type)=>ContentType(type) switch
    {
        "game"=>"game","demo"=>"demo","application" or "software"=>"application",
        "dlc"=>"dlc","tool"=>"tool","runtime" or "redistributable"=>"runtime",
        "support" or "config" or "driver" or "hardware" or "music" or "video" or "series" or "episode" or "advertising"=>"support",
        _=>"unknown"
    };
    internal static bool IsLibraryApp(KeyValue? values)=>LibraryKind(values?["common"]["type"].Value) is "game" or "demo" or "application";
    static string[] Platforms(IEnumerable<string?> oslists)=>oslists.Where(x=>x is not null)
        .SelectMany(x=>x!.Split(',',StringSplitOptions.RemoveEmptyEntries|StringSplitOptions.TrimEntries))
        .Select(x=>x.ToLowerInvariant()).Select(x=>x is "macos" or "mac" or "osx"?"macOS":x)
        .Where(x=>x is "windows" or "macOS").Distinct().OrderBy(x=>x=="windows"?0:1).ToArray();
    internal static string[] PICSPlatforms(KeyValue? values)
    {
        if(values is null)return Array.Empty<string>();
        var sources=new List<string?>{values["common"]["oslist"].Value,values["extended"]["validoslist"].Value};
        sources.AddRange(values["config"]["launch"].Children.Select(x=>x["config"]["oslist"].Value));
        sources.AddRange(values["config"]["launch"].Children.Select(x=>x["oslist"].Value));
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
    internal static object LibraryGame(uint id,KeyValue? values,SteamOwnedGamesSnapshot? owned=null,bool packageMember=true,bool packageMembershipComplete=true)
    {
        var common=values?["common"]??new KeyValue("common");string[] platforms=PICSPlatforms(values);
        SteamOwnedGame? playerGame=null;if(owned?.Available==true)owned.Games.TryGetValue(id,out playerGame);
        string title=Clean(common["name"].Value,512);if(title.Length==0&&playerGame is not null)title=Clean(playerGame.Name,512);
        string kind=LibraryKind(common["type"].Value),classificationSource=kind!="unknown"?"pics":"unknown";
        if(kind=="unknown"&&playerGame is not null){kind="game";classificationSource="cm_player";}
        string? iconHash=Hash(common["icon"].Value)?common["icon"].Value:Hash(playerGame?.IconHash)?playerGame!.IconHash:null;
        string? icon=iconHash is not null?$"https://cdn.akamai.steamstatic.com/steamcommunity/public/images/apps/{id}/{iconHash}.jpg":null;
        string? capsule=Asset(id,common,"library_capsule"),hero=Asset(id,common,"library_hero"),banner=Asset(id,common,"header");
        string[] developers=Associations(common,"developer"),publishers=Associations(common,"publisher");
        string legacyDeveloper=Clean(values?["extended"]["developer"].Value,256),legacyPublisher=Clean(values?["extended"]["publisher"].Value,256);
        if(developers.Length==0&&legacyDeveloper.Length>0)developers=new[]{legacyDeveloper};
        if(publishers.Length==0&&legacyPublisher.Length>0)publishers=new[]{legacyPublisher};
        // Standard CDN addresses are candidates when PICS omits publisher art.
        // They may return 404; consumers must retain their normal icon fallback.
        string fallbackCapsule=$"https://cdn.akamai.steamstatic.com/steam/apps/{id}/library_600x900.jpg";
        string fallbackBanner=$"https://cdn.akamai.steamstatic.com/steam/apps/{id}/header.jpg";
        var metadata=new Dictionary<string,object?>{
            ["platformSizes"]=SteamInstallSizes.Overview(id,values),
            ["launch"]=values?["config"]["launch"].Children.Select(k=>new{executable=k["executable"].Value,arguments=k["arguments"].Value,workingdir=k["workingdir"].Value,@type=k["type"].Value,description=k["description"].Value,oslist=k["config"]["oslist"].Value,osarch=k["config"]["osarch"].Value}).ToArray()??Array.Empty<object>(),
            ["storeURL"]=$"https://store.steampowered.com/app/{id}/",["iconURL"]=icon,["capsuleURL"]=capsule??fallbackCapsule,["heroURL"]=hero??icon,["bannerURL"]=banner??fallbackBanner,["artworkFallbacksUnverified"]=capsule is null||banner is null,
            ["developers"]=developers,["publishers"]=publishers,["genres"]=Array.Empty<string>(),["downloadableVariants"]=platforms,["metadataComplete"]=false,
            ["libraryKind"]=kind,["libraryClassificationSource"]=classificationSource,["libraryMembershipSource"]=playerGame is not null?"cm_player":"package_license",
            ["licensePackageMember"]=packageMember,["licenseMembershipComplete"]=packageMembershipComplete,["ownedGameListAvailable"]=owned?.Available??false,["ownedGameListed"]=owned?.Available==true?playerGame is not null:null,
            ["ownedGameListStatus"]=owned?.Status??"unavailable",["contentInfoUnavailable"]=kind=="unknown"||title.Length==0,["descriptionUnavailable"]=true};
        if(long.TryParse(common["steam_release_date"].Value,out var released))try{metadata["releaseDate"]=DateTimeOffset.FromUnixTimeSeconds(released).ToString("yyyy-MM-dd",CultureInfo.InvariantCulture);}catch(ArgumentOutOfRangeException){}
        if(title.Length>0)metadata["title"]=title;
        string description=Clean(common["description"].Value,65536),shortDescription=Clean(common["short_description"].Value,8192);
        if(description.Length==0)description=shortDescription;
        if(description.Length>0){metadata["description"]=description;metadata["descriptionUnavailable"]=false;metadata["descriptionSource"]="pics";}
        if(shortDescription.Length>0)metadata["shortDescription"]=shortDescription;
        if(ContentType(common["type"].Value)is{} contentType)metadata["contentType"]=contentType;
        return new{id=$"steam:{id}",store="steam",storeID=id.ToString(CultureInfo.InvariantCulture),title=title.Length>0?title:kind=="game"?"Gioco Steam · informazioni non disponibili":"Contenuto Steam · informazioni non disponibili",artworkURL=capsule??icon??fallbackCapsule,
            variants=platforms.Select(platform=>new{id=platform,platform,architecture="unknown",installed=false,arguments=Array.Empty<string>(),verification="Steam platform metadata; inspect local binary to confirm architecture"}).ToArray(),engine="automatic",saveRules=Array.Empty<object>(),metadata};
    }
    internal static Dictionary<string,object?> ParseDetails(uint id,JsonElement root)
    {
        if(root.ValueKind!=JsonValueKind.Object||!root.TryGetProperty(id.ToString(CultureInfo.InvariantCulture),out var app)||app.ValueKind!=JsonValueKind.Object||!app.TryGetProperty("success",out var success))throw new InvalidDataException();
        if(success.ValueKind==JsonValueKind.False)throw new SteamCatalogRequestFailure("metadata_not_found");
        if(success.ValueKind!=JsonValueKind.True||!app.TryGetProperty("data",out var data)||data.ValueKind!=JsonValueKind.Object||!data.TryGetProperty("steam_appid",out var returned)||returned.ValueKind!=JsonValueKind.Number||!returned.TryGetUInt32(out uint appID)||appID!=id)throw new InvalidDataException();
        string Text(string key,int maximum=4096)=>data.TryGetProperty(key,out var item)&&item.ValueKind==JsonValueKind.String?Clean(item.GetString(),maximum):"";
        string[] Names(string key)=>data.TryGetProperty(key,out var array)&&array.ValueKind==JsonValueKind.Array?array.EnumerateArray().Where(x=>x.ValueKind==JsonValueKind.String).Select(x=>Clean(x.GetString(),256)).Where(x=>x.Length>0).Distinct().Take(64).ToArray():Array.Empty<string>();
        string? Image(string key)=>data.TryGetProperty(key,out var item)&&item.ValueKind==JsonValueKind.String?ImageURL(item.GetString()):null;
        string[] genres=data.TryGetProperty("genres",out var genreArray)&&genreArray.ValueKind==JsonValueKind.Array?genreArray.EnumerateArray().Where(x=>x.ValueKind==JsonValueKind.Object&&x.TryGetProperty("description",out var value)&&value.ValueKind==JsonValueKind.String).Select(x=>Clean(x.GetProperty("description").GetString(),256)).Where(x=>x.Length>0).Distinct().Take(64).ToArray():Array.Empty<string>();
        var platforms=new List<string>();if(data.TryGetProperty("platforms",out var os)&&os.ValueKind==JsonValueKind.Object){foreach(var pair in new[]{("windows","windows"),("mac","macOS")})if(os.TryGetProperty(pair.Item1,out var offered)&&offered.ValueKind==JsonValueKind.True)platforms.Add(pair.Item2);}
        string release="";if(data.TryGetProperty("release_date",out var date)&&date.ValueKind==JsonValueKind.Object&&date.TryGetProperty("date",out var text)&&text.ValueKind==JsonValueKind.String)release=Clean(text.GetString(),128);
        string description=Text("about_the_game",65536);if(description.Length==0)description=Text("short_description",8192);
        var result=new Dictionary<string,object?>{["shortDescription"]=Text("short_description",8192),["description"]=description,["developers"]=Names("developers"),["publishers"]=Names("publishers"),["genres"]=genres,["releaseDate"]=release,["storeURL"]=$"https://store.steampowered.com/app/{id}/",["downloadableVariants"]=platforms.ToArray(),["metadataComplete"]=true};
        if(data.TryGetProperty("categories",out var categories)&&categories.ValueKind==JsonValueKind.Array)
            result["categories"]=categories.EnumerateArray().Where(x=>x.ValueKind==JsonValueKind.Object&&x.TryGetProperty("description",out var label)&&label.ValueKind==JsonValueKind.String).Select(x=>Clean(x.GetProperty("description").GetString(),256)).Where(x=>x.Length>0).Distinct().Take(64).ToArray();
        if(data.TryGetProperty("achievements",out var achievements)&&achievements.ValueKind==JsonValueKind.Object&&achievements.TryGetProperty("total",out var total)&&total.ValueKind==JsonValueKind.Number&&total.TryGetUInt32(out uint count)&&count<=100000)result["achievementsCount"]=count;
        string title=Text("name",512);if(title.Length>0)result["title"]=title;
        if(ContentType(Text("type",64))is{} contentType){result["contentType"]=contentType;result["libraryKind"]=LibraryKind(contentType);result["libraryClassificationSource"]="public_store";}
        result["contentInfoUnavailable"]=title.Length==0||!result.ContainsKey("libraryKind")||Equals(result["libraryKind"],"unknown");
        result["descriptionUnavailable"]=description.Length==0;if(description.Length>0)result["descriptionSource"]="public_store";
        var requirements=new Dictionary<string,object?>();
        foreach(var pair in new[]{("windows","pc_requirements"),("macOS","mac_requirements")})if(SteamInstallSizes.MinimumRequirement(data,pair.Item2)is{} bytes)requirements[pair.Item1]=new Dictionary<string,object?>{["requiredBytes"]=bytes,["source"]="steam_store_minimum_requirement",["label"]="Requisito minimo dichiarato, non dimensione del download",["verified"]=false};
        if(requirements.Count>0)result["platformRequirements"]=requirements;
        // Do not erase genuine PICS icons/heroes when Store supplies no such field.
        if(Image("header_image") is {} header)result["bannerURL"]=header;
        if((Image("background_raw")??Image("background")) is {} background)result["heroURL"]=background;
        if((Image("capsule_imagev5")??Image("capsule_image")) is {} capsule)result["capsuleURL"]=capsule;
        return result;
    }
}

sealed class SteamCatalogRequestFailure(string code,int? retryAfterSeconds=null):HttpRequestException(code)
{
    internal string Code {get;}=code;
    internal int? RetryAfterSeconds {get;}=retryAfterSeconds;
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
    internal async Task<Dictionary<string,object?>> DetailsAsync(uint appID,string language,CancellationToken cancel,bool refresh=false)
    {
        if(appID==0)throw new ArgumentException();language=Language(language);string key=$"{appID}:{language}";
        Dictionary<string,object?>? Cached(){lock(sync)return cache.TryGetValue(key,out var entry)&&DateTimeOffset.UtcNow-entry.At<TimeSpan.FromHours(6)?new(entry.Value):null;}
        cancel.ThrowIfCancellationRequested();if(!refresh&&Cached() is {} cached)return cached;
        using var budget=CancellationTokenSource.CreateLinkedTokenSource(cancel);budget.CancelAfter(TimeSpan.FromSeconds(12));
        await requests.WaitAsync(budget.Token);
        try
        {
            if(!refresh&&Cached() is {} existing)return existing;
            using var request=new HttpRequestMessage(HttpMethod.Get,$"https://store.steampowered.com/api/appdetails?appids={appID}&l={language}");
            if(refresh){request.Headers.CacheControl=new(){NoCache=true,NoStore=true};request.Headers.Pragma.ParseAdd("no-cache");}
            using var reply=await http.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,budget.Token);
            if((int)reply.StatusCode==429){double seconds=reply.Headers.RetryAfter?.Delta?.TotalSeconds??(reply.Headers.RetryAfter?.Date is{} date?(date-DateTimeOffset.UtcNow).TotalSeconds:60);throw new SteamCatalogRequestFailure("rate_limited",(int)Math.Clamp(Math.Ceiling(seconds),1,3600));}
            if(reply.StatusCode is HttpStatusCode.NotFound or HttpStatusCode.Gone)throw new SteamCatalogRequestFailure("metadata_not_found");
            if(!reply.IsSuccessStatusCode){double? seconds=reply.Headers.RetryAfter?.Delta?.TotalSeconds??(reply.Headers.RetryAfter?.Date is{} date?(date-DateTimeOffset.UtcNow).TotalSeconds:null);throw new SteamCatalogRequestFailure("metadata_unavailable",seconds is{} retry?(int)Math.Clamp(Math.Ceiling(retry),1,3600):null);}
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
    readonly Dictionary<string,int> kinds=new(StringComparer.Ordinal);
    int bytes=2;
    bool licenseMembershipComplete=true;
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
            string kind="unknown";
            if(document.RootElement.TryGetProperty("metadata",out var metadata)&&metadata.ValueKind==JsonValueKind.Object&&metadata.TryGetProperty("libraryKind",out var kindValue)&&kindValue.ValueKind==JsonValueKind.String)kind=SteamCatalogMetadata.LibraryKind(kindValue.GetString());
            kinds[kind]=kinds.GetValueOrDefault(kind)+1;
            if(document.RootElement.TryGetProperty("metadata",out var entryMetadata)&&entryMetadata.ValueKind==JsonValueKind.Object&&entryMetadata.TryGetProperty("licenseMembershipComplete",out var complete)&&complete.ValueKind==JsonValueKind.False)licenseMembershipComplete=false;
            if(!paged){all.Add(game);continue;}
            if(encoded.Length+2>MaximumPageBytes)throw new SteamLibraryPayloadException("library_entry_too_large");
            if(pending.Count>=50||bytes+encoded.Length+1>MaximumPageBytes)Flush();
            pending.Add(game);bytes+=encoded.Length+1;
        }
    }
    void Flush(){if(pending.Count==0)return;emit(pending.ToArray(),PageCount++);pending.Clear();bytes=2;}
    internal Dictionary<string,object?> Complete()
    {
        if(paged){Flush();return new(){["gameCount"]=GameCount,["recordCount"]=GameCount,["pageCount"]=PageCount,["libraryKindCounts"]=new Dictionary<string,int>(kinds),["licenseMembershipComplete"]=licenseMembershipComplete};}
        return new(){["games"]=all,["gameCount"]=GameCount,["recordCount"]=GameCount,["libraryKindCounts"]=new Dictionary<string,int>(kinds),["licenseMembershipComplete"]=licenseMembershipComplete};
    }
}
