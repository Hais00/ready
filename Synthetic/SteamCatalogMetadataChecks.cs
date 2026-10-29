// SPDX-License-Identifier: GPL-3.0-only
using System.Net;
using System.Text.Json;
using SteamKit2;
using SteamKit2.Authentication;
static class SteamCatalogMetadataChecks
{
    static readonly Dictionary<string,bool> checks=new();
    static void Check(bool condition,string name){if(!condition)throw new Exception(name);checks[name]=true;}
    static JsonElement JSON(object value)=>JsonSerializer.SerializeToElement(value);
    static string Body(uint id=1091500)=>JsonSerializer.Serialize(new Dictionary<string,object>{{id.ToString(),new{success=true,data=new{steam_appid=id,name="<b>Official public name</b>",type="dlc",short_description="Public &amp; safe",about_the_game="<p>About</p><script>bad()</script>",developers=new[]{"Developer"},publishers=new[]{"Publisher"},genres=new[]{new{description="RPG"}},release_date=new{date="10 Dec, 2020"},platforms=new{windows=true,mac=true},header_image="https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/1091500/header.jpg",capsule_image="https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/1091500/capsule.jpg",refresh_token="must_not_be_serialized"}}}});
    sealed class Handler:HttpMessageHandler
    {
        internal int Calls,Active,Maximum;internal string? URL;internal TaskCompletionSource<bool>? Gate;internal bool Bad,Large;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken cancel)
        {
            Interlocked.Increment(ref Calls);int active=Interlocked.Increment(ref Active);lock(this)Maximum=Math.Max(Maximum,active);URL=request.RequestUri!.AbsoluteUri;
            try{if(Gate is not null)await Gate.Task.WaitAsync(cancel);uint id=uint.Parse(request.RequestUri.Query.Split("appids=")[1].Split('&')[0]);
                return new(Bad?HttpStatusCode.NotFound:HttpStatusCode.OK){Content=new StringContent(Large?new string('x',4*1024*1024+1):Body(id))};}
            finally{Interlocked.Decrement(ref Active);}
        }
    }
    sealed class Fake:ISteamServiceTransport
    {
        public event Action<SteamTransportNotice>? Notice {add{}remove{}}
        internal int Connects;
        public Task ConnectAsync(CancellationToken c){Connects++;throw new Exception();}
        public Task<SteamServiceCredentials> AuthenticateAsync(string m,string u,string p,Action<string> q,IAuthenticator g,CancellationToken c)=>throw new Exception();
        public Task<EResult> LogOnAsync(SteamServiceCredentials c,CancellationToken t)=>throw new Exception();
        public Task StopAsync()=>Task.CompletedTask;
        public SteamServiceAccount? Account(string name)=>null;
        public IReadOnlyList<SteamServiceFriend> Friends()=>Array.Empty<SteamServiceFriend>();
        public void SetPresence(EPersonaState p){}public void SetActivity(IReadOnlyCollection<uint> a){}
        public Task<SteamServiceMutation> SetPersonaNameAsync(string n,CancellationToken c)=>throw new Exception();
        public Task<SteamServiceMutation> FriendActionAsync(string o,ulong i,CancellationToken c)=>throw new Exception();
        public Task<SteamServiceOwnership> AuthorizeAsync(uint id,CancellationToken c)=>throw new Exception();
        public Task LibraryAsync(Action<object[]> p,CancellationToken c)=>throw new Exception();
        public ValueTask DisposeAsync()=>ValueTask.CompletedTask;
    }
    sealed class Output:StringWriter
    {readonly object gate=new();public override void WriteLine(string? line){lock(gate)base.WriteLine(line);}internal JsonElement[] Events{get{lock(gate)return ToString().Split('\n',StringSplitOptions.RemoveEmptyEntries).Select(x=>JsonDocument.Parse(x).RootElement.Clone()).ToArray();}}}
    static async Task Wait(Func<bool> condition){using var budget=new CancellationTokenSource(TimeSpan.FromSeconds(4));while(!condition())await Task.Delay(2,budget.Token);}
    static async Task<int> Main(string[] args)
    {
        if(args.Length==1){using var doc=JsonDocument.Parse(await File.ReadAllTextAsync(args[0]));var meta=SteamCatalogMetadata.ParseDetails(1091500,doc.RootElement);Console.WriteLine(JsonSerializer.Serialize(new{passed=true,publicAppID=1091500,metadata=meta}));return 0;}
        var pic=KeyValue.LoadFromString("\"appinfo\" { \"common\" { \"name\" \"Owned fixture\" \"type\" \"game\" \"oslist\" \" windows,macos \" \"icon\" \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\" \"library_assets\" {\"library_capsule\" \"library_600x900.jpg\"} } \"config\" {\"launch\" {\"0\" {\"executable\" \"Game\" \"config\" {\"oslist\" \"macos\" \"osarch\" \"64\"}}}} }")!;
        var game=JSON(SteamCatalogMetadata.LibraryGame(1,pic));var variants=game.GetProperty("variants").EnumerateArray().ToArray();
        Check(variants.Length==2&&variants.All(x=>x.GetProperty("architecture").GetString()=="unknown"&&!x.GetProperty("installed").GetBoolean()),"both-platforms-never-claim-arm64");
        Check(game.GetProperty("metadata").GetProperty("launch")[0].GetProperty("osarch").GetString()=="64","launch-metadata-preserved");
        Check(game.GetProperty("metadata").GetProperty("iconURL").GetString()!.Contains("/images/apps/1/aaaaaaaa"),"real-pics-icon-hash-url");
        Check(game.GetProperty("artworkURL").GetString()!.EndsWith("/library_600x900.jpg"),"offered-pics-capsule");
        var legacy=KeyValue.LoadFromString("\"appinfo\" {\"common\" {\"library_assets\" {\"library_hero\" \"en\"}}}")!;
        Check(JSON(SteamCatalogMetadata.LibraryGame(1,legacy)).GetProperty("metadata").GetProperty("heroURL").GetString()!.EndsWith("/library_hero.jpg"),"legacy-pics-offered-language-asset");
        var fallback=JSON(SteamCatalogMetadata.LibraryGame(2,null));Check(fallback.GetProperty("id").GetString()=="steam:2"&&fallback.GetProperty("variants").GetArrayLength()==0,"missing-pics-retains-owned-entry-no-invented-platform");
        var union=KeyValue.LoadFromString("\"appinfo\" { \"common\" {\"oslist\" \"windows\"} \"depots\" {\"1\" {\"config\" {\"oslist\" \"macos\"}}}}")!;
        Check(SteamCatalogMetadata.PICSPlatforms(union).SequenceEqual(new[]{"windows","macOS"}),"depot-platform-union");
        Check(!SteamCatalogMetadata.IsLibraryApp(KeyValue.LoadFromString("\"appinfo\" {\"common\" {\"type\" \"dlc\"}}")),"known-dlc-is-not-base-game");
        Check(SteamCatalogMetadata.ImageURL("https://evil.example/image.jpg")==null&&SteamCatalogMetadata.ImageURL("http://cdn.akamai.steamstatic.com/a")==null&&SteamCatalogMetadata.ImageURL("https://cdn.akamai.steamstatic.com:8080/a")==null,"image-url-allowlist");
        using var detailsDoc=JsonDocument.Parse(Body());var details=SteamCatalogMetadata.ParseDetails(1091500,detailsDoc.RootElement);var detail=JSON(details);
        Check(detail.GetProperty("shortDescription").GetString()=="Public & safe"&&!detail.GetProperty("description").GetString()!.Contains("bad()"),"plain-text-html-sanitized");
        Check(detail.GetProperty("developers")[0].GetString()=="Developer"&&detail.GetProperty("genres")[0].GetString()=="RPG"&&detail.GetProperty("downloadableVariants").GetArrayLength()==2,"public-details-complete-contract");
        Check(detail.GetProperty("title").GetString()=="Official public name"&&detail.GetProperty("contentType").GetString()=="dlc","optional-official-title-and-content-type-no-filter");
        Check(fallback.GetProperty("artworkURL").GetString()!.EndsWith("/2/library_600x900.jpg")&&fallback.GetProperty("metadata").GetProperty("bannerURL").GetString()!.EndsWith("/2/header.jpg")&&fallback.GetProperty("metadata").GetProperty("artworkFallbacksUnverified").GetBoolean(),"missing-pics-standard-art-candidates-not-existence-proof");
        Check(game.GetProperty("metadata").GetProperty("contentType").GetString()=="game"&&game.GetProperty("metadata").GetProperty("title").GetString()=="Owned fixture","pics-title-type-compatible-metadata");
        Check(SteamCatalogMetadata.ContentType("<b>TOOL</b>")=="tool"&&SteamCatalogMetadata.ContentType("bad/type")==null,"content-type-bounded-canonical");
        Check(!JsonSerializer.Serialize(details).Contains("refresh_token")&&!details.ContainsKey("iconURL")&&!details.ContainsKey("heroURL"),"public-whitelist-preserves-absent-pics-artwork");
        bool rejected=false;try{SteamCatalogMetadata.ParseDetails(1,detailsDoc.RootElement);}catch(InvalidDataException){rejected=true;}Check(rejected,"mismatched-app-rejected");
        var handler=new Handler();var catalog=new SteamPublicCatalog(new HttpClient(handler));await catalog.DetailsAsync(1091500,"english",default);await catalog.DetailsAsync(1091500,"english",default);
        Check(handler.Calls==1&&handler.URL=="https://store.steampowered.com/api/appdetails?appids=1091500&l=english","single-public-app-endpoint-cache");
        await catalog.DetailsAsync(1091500,"italian",default);Check(handler.Calls==2,"language-cache-separated");
        using(var cancelled=new CancellationTokenSource()){cancelled.Cancel();try{await catalog.DetailsAsync(1091500,"english",cancelled.Token);}catch(OperationCanceledException){}Check(handler.Calls==2,"cancelled-cache-request-no-http");}
        var large=new Handler{Large=true};rejected=false;try{await new SteamPublicCatalog(new HttpClient(large)).DetailsAsync(1,"english",default);}catch(InvalidDataException){rejected=true;}Check(rejected,"response-size-bounded");
        var busy=new Handler{Gate=new(TaskCreationOptions.RunContinuationsAsynchronously)};var bounded=new SteamPublicCatalog(new HttpClient(busy));var pending=Enumerable.Range(1,6).Select(x=>bounded.DetailsAsync((uint)x,"english",default)).ToArray();await Wait(()=>busy.Active==2);Check(busy.Maximum==2,"http-concurrency-two");busy.Gate.SetResult(true);await Task.WhenAll(pending);Check(busy.Maximum==2,"http-concurrency-remains-bounded");
        var bad=new Handler{Bad=true};var badCatalog=new SteamPublicCatalog(new HttpClient(bad));for(int i=0;i<2;i++)try{await badCatalog.DetailsAsync(1,"english",default);}catch(HttpRequestException){}Check(bad.Calls==2,"failed-public-response-not-cached");
        var output=new Output();var transport=new Fake();int metadataCalls=0;
        var delayed=new TaskCompletionSource<Dictionary<string,object?>>(TaskCreationOptions.RunContinuationsAsynchronously);
        await using(var service=new PersistentSteamService(transport,output,catalogMetadata:(id,language,cancel)=>{Interlocked.Increment(ref metadataCalls);return id==7?delayed.Task:Task.FromResult(details);}))
        {
            string Send(string op,object options){string id=Guid.NewGuid().ToString();service.Accept(JsonSerializer.Serialize(new{id,profileID="00000000-0000-4000-8000-000000000001",profileGeneration="00000000-0000-4000-8000-000000000002",operation=op,options}));return id;}
            string id=Send("catalog_metadata",new{gameID="1091500"});await Wait(()=>output.Events.Any(x=>x.GetProperty("id").GetString()==id&&x.GetProperty("type").GetString()=="result"));
            Check(transport.Connects==0&&metadataCalls==1,"public-metadata-offline-no-steam-connection");
            string waiting=Send("catalog_metadata",new{gameID="7"});await Wait(()=>metadataCalls==2);string cancellation=Send("cancel",new{requestID=waiting});await Wait(()=>output.Events.Any(x=>x.GetProperty("id").GetString()==cancellation&&x.GetProperty("type").GetString()=="result"));delayed.SetResult(details);await Wait(()=>output.Events.Any(x=>x.GetProperty("id").GetString()==waiting&&x.GetProperty("type").GetString()=="error"));
            Check(output.Events.Count(x=>x.GetProperty("id").GetString()==waiting&&x.GetProperty("type").GetString() is "error" or "result")==1,"late-public-callback-after-cancel-no-result");
        }
        var emitted=new List<JsonElement>();var pages=new SteamLibraryPages(true,(games,index)=>emitted.Add(JSON(new{games,pageIndex=index})));
        pages.Add(Enumerable.Range(1,1000).Select(i=>(object)new{id="steam:"+i,title=new string('x',5000)}));var final=JSON(pages.Complete());
        Check(final.GetProperty("gameCount").GetInt32()==1000&&final.GetProperty("pageCount").GetInt32()==emitted.Count&&!final.TryGetProperty("games",out _),"paged-library-over-four-MiB-terminal-counts");
        Check(emitted.Select((page,index)=>page.GetProperty("pageIndex").GetInt32()==index&&page.GetProperty("games").GetArrayLength()<=50&&JsonSerializer.SerializeToUtf8Bytes(page).Length<1024*1024).All(x=>x),"ordered-pages-within-byte-and-entry-bounds");
        Check(emitted.SelectMany(x=>x.GetProperty("games").EnumerateArray()).Select(x=>x.GetProperty("id").GetString()).Distinct().Count()==1000,"paged-library-complete-no-duplicate");
        rejected=false;try{pages.Add(new[]{new{id="steam:1"}});}catch(SteamLibraryPayloadException error){rejected=error.Code=="library_duplicate_entry";}Check(rejected,"duplicate-library-entry-rejected");
        rejected=false;try{new SteamLibraryPages(true,(_,_)=>{}).Add(new[]{new{id="steam:1",title=new string('x',1024*1024)}});}catch(SteamLibraryPayloadException error){rejected=error.Code=="library_entry_too_large";}Check(rejected,"oversized-single-library-entry-rejected");
        var empty=JSON(new SteamLibraryPages(true,(_,_)=>throw new Exception()).Complete());Check(empty.GetProperty("gameCount").GetInt32()==0&&empty.GetProperty("pageCount").GetInt32()==0,"empty-paged-library-explicit-zero-counts");
        Console.WriteLine(JsonSerializer.Serialize(new{passed=true,checkCount=checks.Count,checks,realAuthenticationAttempted=false,steamConnectionCreated=false}));return 0;
    }
}
