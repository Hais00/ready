// SPDX-License-Identifier: GPL-3.0-only
using System.Net;
using System.Text.Json;
using SteamKit2;
using SteamKit2.Authentication;
using SteamKit2.Internal;
static class SteamCatalogMetadataChecks
{
    static readonly Dictionary<string,bool> checks=new();
    static void Check(bool condition,string name){if(!condition)throw new Exception(name);checks[name]=true;}
    static JsonElement JSON(object value)=>JsonSerializer.SerializeToElement(value);
    static string Body(uint id=1091500)=>JsonSerializer.Serialize(new Dictionary<string,object>{{id.ToString(),new{success=true,data=new{steam_appid=id,name="<b>Official public name</b>",type="dlc",short_description="Public &amp; safe",about_the_game="<p>About</p><script>bad()</script>",developers=new[]{"Developer"},publishers=new[]{"Publisher"},genres=new[]{new{description="RPG"}},release_date=new{date="10 Dec, 2020"},platforms=new{windows=true,mac=true},header_image="https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/1091500/header.jpg",capsule_image="https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/1091500/capsule.jpg",refresh_token="must_not_be_serialized"}}}});
    sealed class Handler:HttpMessageHandler
    {
        internal int Calls,Active,Maximum;internal string? URL;internal TaskCompletionSource<bool>? Gate;internal bool Bad,Large,ChangedName,NoCacheSeen,ExplicitMissing;internal int? Status;internal int? RetrySeconds;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken cancel)
        {
            Interlocked.Increment(ref Calls);int active=Interlocked.Increment(ref Active);lock(this)Maximum=Math.Max(Maximum,active);URL=request.RequestUri!.AbsoluteUri;NoCacheSeen=request.Headers.CacheControl?.NoCache==true&&request.Headers.CacheControl?.NoStore==true&&request.Headers.Pragma.Any(x=>x.Name=="no-cache");
            try{if(Gate is not null)await Gate.Task.WaitAsync(cancel);uint id=uint.Parse(request.RequestUri.Query.Split("appids=")[1].Split('&')[0]);
                var response=new HttpResponseMessage(Status is{} status?(HttpStatusCode)status:Bad?HttpStatusCode.NotFound:HttpStatusCode.OK){Content=new StringContent(ExplicitMissing?"{\""+id+"\":{\"success\":false}}":Large?new string('x',4*1024*1024+1):ChangedName?Body(id).Replace("Official public name","Updated public name"):Body(id))};
                if(RetrySeconds is{} retry)response.Headers.RetryAfter=new(TimeSpan.FromSeconds(retry));return response;}
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
        handler.ChangedName=true;var refreshed=await catalog.DetailsAsync(1091500,"english",default,refresh:true);
        Check(handler.Calls==3&&handler.NoCacheSeen&&Equals(refreshed["title"],"Updated public name"),"explicit-refresh-skips-memory-and-requests-http-revalidation");
        await catalog.DetailsAsync(1091500,"english",default);Check(handler.Calls==3,"refreshed-result-replaces-default-memory-cache");
        var large=new Handler{Large=true};rejected=false;try{await new SteamPublicCatalog(new HttpClient(large)).DetailsAsync(1,"english",default);}catch(InvalidDataException){rejected=true;}Check(rejected,"response-size-bounded");
        var busy=new Handler{Gate=new(TaskCreationOptions.RunContinuationsAsynchronously)};var bounded=new SteamPublicCatalog(new HttpClient(busy));var pending=Enumerable.Range(1,6).Select(x=>bounded.DetailsAsync((uint)x,"english",default)).ToArray();await Wait(()=>busy.Active==2);Check(busy.Maximum==2,"http-concurrency-two");busy.Gate.SetResult(true);await Task.WhenAll(pending);Check(busy.Maximum==2,"http-concurrency-remains-bounded");
        var bad=new Handler{Bad=true};var badCatalog=new SteamPublicCatalog(new HttpClient(bad));for(int i=0;i<2;i++)try{await badCatalog.DetailsAsync(1,"english",default);}catch(HttpRequestException){}Check(bad.Calls==2,"failed-public-response-not-cached");
        var rate=new Handler{Status=429,RetrySeconds=9};rejected=false;try{await new SteamPublicCatalog(new HttpClient(rate)).DetailsAsync(1,"english",default);}catch(SteamCatalogRequestFailure error){rejected=error.Code=="rate_limited"&&error.RetryAfterSeconds==9;}Check(rejected,"rate-limit-preserves-bounded-retry-after");
        var transient=new Handler{Status=503,RetrySeconds=4};rejected=false;try{await new SteamPublicCatalog(new HttpClient(transient)).DetailsAsync(1,"english",default);}catch(SteamCatalogRequestFailure error){rejected=error.Code=="metadata_unavailable"&&error.RetryAfterSeconds==4;}Check(rejected,"server-5xx-transient-not-not-found");
        var missing=new Handler{ExplicitMissing=true};rejected=false;try{await new SteamPublicCatalog(new HttpClient(missing)).DetailsAsync(1,"english",default);}catch(SteamCatalogRequestFailure error){rejected=error.Code=="metadata_not_found";}Check(rejected,"official-success-false-specific-not-found");
        handler.Status=503;try{await catalog.DetailsAsync(1091500,"english",default,refresh:true);}catch(SteamCatalogRequestFailure){}int failedCalls=handler.Calls;var kept=await catalog.DetailsAsync(1091500,"english",default);
        Check(handler.Calls==failedCalls&&Equals(kept["title"],"Updated public name"),"failed-refresh-keeps-last-valid-memory-cache");
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
        var request=SteamOwnedGamesCatalog.Request(76561198000000001UL);
        Check(request.steamid==76561198000000001UL&&request.include_appinfo&&!request.skip_unvetted_apps&&request.include_free_sub&&!request.include_family_licenses,"owned-games-authenticated-self-request-flags");
        rejected=false;try{SteamOwnedGamesCatalog.Request(0);}catch(ArgumentException){rejected=true;}Check(rejected,"owned-games-invalid-self-rejected");
        var ownedBody=new CPlayer_GetOwnedGames_Response{game_count=2};ownedBody.games.Add(new(){appid=1,name="CM authoritative name",img_icon_url=new string('b',40)});ownedBody.games.Add(new(){appid=2,name="CM other name"});
        var owned=SteamOwnedGamesCatalog.Parse(EResult.OK,ownedBody);
        Check(owned.Available&&owned.Games.Count==2,"owned-games-count-validated");
        Check(!SteamOwnedGamesCatalog.Parse(EResult.AccessDenied,ownedBody).Available,"owned-games-server-failure-unavailable-not-empty-success");
        ownedBody.game_count=3;Check(!SteamOwnedGamesCatalog.Parse(EResult.OK,ownedBody).Available,"owned-games-partial-count-fails-closed");ownedBody.game_count=2;
        var duplicate=new CPlayer_GetOwnedGames_Response{game_count=2};duplicate.games.Add(new(){appid=1});duplicate.games.Add(new(){appid=1});Check(!SteamOwnedGamesCatalog.Parse(EResult.OK,duplicate).Available,"owned-games-duplicate-fails-closed");
        var cmGame=JSON(SteamCatalogMetadata.LibraryGame(1,null,owned,false));
        Check(cmGame.GetProperty("title").GetString()=="CM authoritative name"&&cmGame.GetProperty("metadata").GetProperty("libraryKind").GetString()=="game"&&cmGame.GetProperty("metadata").GetProperty("iconURL").GetString()!.Contains(new string('b',40)),"cm-name-icon-game-classification-survive-missing-pics");
        Check(cmGame.GetProperty("metadata").GetProperty("descriptionUnavailable").GetBoolean()&&!cmGame.GetProperty("metadata").TryGetProperty("description",out _),"cm-owned-games-does-not-invent-description");
        Check(fallback.GetProperty("metadata").GetProperty("libraryKind").GetString()=="unknown"&&!fallback.GetProperty("title").GetString()!.All(char.IsDigit)&&fallback.GetProperty("metadata").GetProperty("ownedGameListed").ValueKind==JsonValueKind.Null,"license-unknown-retained-generic-not-numeric-game");
        var dlc=KeyValue.LoadFromString("\"appinfo\" {\"common\" {\"name\" \"DLC record\" \"type\" \"dlc\"}}")!;
        var tool=KeyValue.LoadFromString("\"appinfo\" {\"common\" {\"name\" \"Tool record\" \"type\" \"tool\"}}")!;
        var collected=new List<JsonElement>();Action<object[]> collect=games=>collected.AddRange(games.Select(JSON));
        await SteamOwnedGamesCatalog.CollectAsync(_=>Task.FromResult(owned),_=>Task.FromResult(new HashSet<uint>{2,3}),(ids,_)=>Task.FromResult(new Dictionary<uint,KeyValue>{{2,dlc},{3,tool}}),collect,default);
        Check(collected.Count==3&&collected.Select(x=>x.GetProperty("storeID").GetString()).Distinct().Count()==3,"cm-and-package-union-complete-unique");
        Check(collected.Single(x=>x.GetProperty("storeID").GetString()=="2").GetProperty("metadata").GetProperty("libraryKind").GetString()=="dlc"&&collected.Single(x=>x.GetProperty("storeID").GetString()=="3").GetProperty("metadata").GetProperty("libraryKind").GetString()=="tool","known-dlc-tool-retained-explicit-not-games");
        collected.Clear();await SteamOwnedGamesCatalog.CollectAsync(_=>Task.FromResult(owned),_=>Task.FromResult(new HashSet<uint>{3}),(ids,_)=>Task.FromException<Dictionary<uint,KeyValue>>(new IOException()),collect,default);
        Check(collected.Count==3&&collected.Single(x=>x.GetProperty("storeID").GetString()=="1").GetProperty("title").GetString()=="CM authoritative name","pics-job-failure-never-drops-authoritative-games");
        collected.Clear();await SteamOwnedGamesCatalog.CollectAsync(_=>Task.FromResult(owned),_=>Task.FromException<HashSet<uint>>(new IOException()),(ids,_)=>Task.FromResult(new Dictionary<uint,KeyValue>()),collect,default);
        Check(collected.Count==2&&collected.All(x=>!x.GetProperty("metadata").GetProperty("licenseMembershipComplete").GetBoolean()),"package-failure-never-drops-cm-games");
        var partialPages=new SteamLibraryPages(true,(_,_)=>{});partialPages.Add(collected.Select(x=>(object)x));Check(!JSON(partialPages.Complete()).GetProperty("licenseMembershipComplete").GetBoolean(),"partial-license-snapshot-terminal-requires-preserving-old-membership");
        collected.Clear();rejected=false;try{await SteamOwnedGamesCatalog.CollectAsync(_=>Task.FromResult(new SteamOwnedGamesSnapshot(true,new Dictionary<uint,SteamOwnedGame>(),"available")),_=>Task.FromException<HashSet<uint>>(new IOException()),(ids,_)=>Task.FromResult(new Dictionary<uint,KeyValue>()),collect,default);}catch(IOException){rejected=true;}Check(rejected&&collected.Count==0,"zero-cm-games-and-license-failure-never-empty-success");
        collected.Clear();await SteamOwnedGamesCatalog.CollectAsync(_=>Task.FromException<SteamOwnedGamesSnapshot>(new IOException()),_=>Task.FromResult(new HashSet<uint>{3}),(ids,_)=>Task.FromResult(new Dictionary<uint,KeyValue>{{3,tool}}),collect,default);
        Check(collected.Count==1&&collected[0].GetProperty("metadata").GetProperty("libraryKind").GetString()=="tool"&&collected[0].GetProperty("metadata").GetProperty("ownedGameListed").ValueKind==JsonValueKind.Null,"owned-rpc-unavailable-keeps-known-pics-content-no-denial");
        collected.Clear();rejected=false;try{await SteamOwnedGamesCatalog.CollectAsync(_=>Task.FromException<SteamOwnedGamesSnapshot>(new IOException()),_=>Task.FromException<HashSet<uint>>(new IOException()),(ids,_)=>Task.FromResult(new Dictionary<uint,KeyValue>()),collect,default);}catch(IOException){rejected=true;}
        Check(rejected&&collected.Count==0,"both-membership-sources-fail-no-empty-success");
        using(var cancellation=new CancellationTokenSource()){
            var gate=new TaskCompletionSource<SteamOwnedGamesSnapshot>(TaskCreationOptions.RunContinuationsAsynchronously);int licenseCalls=0;
            var waiting=SteamOwnedGamesCatalog.CollectAsync(_=>gate.Task,_=>{licenseCalls++;return Task.FromResult(new HashSet<uint>());},(ids,_)=>Task.FromResult(new Dictionary<uint,KeyValue>()),collect,cancellation.Token);
            cancellation.Cancel();gate.SetResult(owned);rejected=false;try{await waiting;}catch(OperationCanceledException){rejected=true;}
            Check(rejected&&licenseCalls==0&&collected.Count==0,"cancel-late-owned-response-does-not-resurrect-library");
        }
        var refreshOutput=new Output();var refreshTransport=new Fake();bool sawRefresh=false;int refreshCalls=0;
        await using(var service=new PersistentSteamService(refreshTransport,refreshOutput,catalogMetadataWithRefresh:(app,language,refresh,cancel)=>{refreshCalls++;sawRefresh=refresh;return Task.FromResult(details);})){
            string SendRefresh(object option){string id=Guid.NewGuid().ToString();service.Accept(JsonSerializer.Serialize(new{id,profileID="00000000-0000-4000-8000-000000000001",profileGeneration="00000000-0000-4000-8000-000000000002",operation="catalog_metadata",options=new{gameID="1091500",refresh=option}}));return id;}
            string yes=SendRefresh(true);await Wait(()=>refreshOutput.Events.Any(x=>x.GetProperty("id").GetString()==yes&&x.GetProperty("type").GetString()=="result"));
            Check(sawRefresh&&refreshCalls==1&&refreshTransport.Connects==0,"service-refresh-true-routed-no-login");
            string invalid=SendRefresh("true");await Wait(()=>refreshOutput.Events.Any(x=>x.GetProperty("id").GetString()==invalid&&x.GetProperty("type").GetString()=="error"));Check(refreshCalls==1,"service-refresh-strict-bool");
        }
        var rateOutput=new Output();await using(var service=new PersistentSteamService(new Fake(),rateOutput,catalogMetadataWithRefresh:(app,language,refresh,cancel)=>throw new SteamCatalogRequestFailure("rate_limited",9))){
            string id=Guid.NewGuid().ToString();service.Accept(JsonSerializer.Serialize(new{id,profileID="00000000-0000-4000-8000-000000000001",profileGeneration="00000000-0000-4000-8000-000000000002",operation="catalog_metadata",options=new{gameID="1091500",refresh=true}}));
            await Wait(()=>rateOutput.Events.Any(x=>x.GetProperty("id").GetString()==id&&x.GetProperty("type").GetString()=="error"));var error=rateOutput.Events.Last(x=>x.GetProperty("id").GetString()==id);Check(error.GetProperty("code").GetString()=="rate_limited"&&error.GetProperty("retryAfterSeconds").GetInt32()==9,"service-rate-limit-code-and-delay-safe");
        }
        KeyValue Product(string depots)=>KeyValue.LoadFromString("\"appinfo\" {\"common\" {\"type\" \"game\" \"oslist\" \"windows,macos\"} \"depots\" {"+depots+"}}")!;
        string Depot(uint id,ulong size,ulong download,string config="",string extra="")=>$"\"{id}\" {{\"config\" {{{config}}} \"manifests\" {{\"public\" {{\"gid\" \"{id+100}\" \"size\" \"{size}\" \"download\" \"{download}\"}}}} {extra}}}";
        var sized=Product(Depot(10,100,50)+Depot(11,200,80,"\"oslist\" \"windows\" \"osarch\" \"64\"")+Depot(12,300,90,"\"oslist\" \"macos\"")+Depot(13,400,150,"\"language\" \"italian\"")+Depot(14,500,200,"\"osarch\" \"32\"")+Depot(15,600,210,"\"lowviolence\" \"1\""));
        var products=new Dictionary<uint,KeyValue>{{1,sized}};var winPlan=SteamInstallSizes.Build(new(1,"windows"),products);var macPlan=SteamInstallSizes.Build(new(1,"macOS"),products);
        Check(winPlan.InstalledBytes==300&&winPlan.DownloadBytes==130&&macPlan.InstalledBytes==400&&macPlan.DownloadBytes==140,"size-os-arch-language-and-lowviolence-match-engine-defaults");
        Check(!winPlan.Verified&&winPlan.Payload()["peakDiskBytes"]is null&&winPlan.Payload()["requiredBytes"]is null,"catalog-size-not-verified-or-invented-peak-space");
        var packageInfo=new KeyValue("package");var appSection=new KeyValue("appids");appSection.Children.Add(new KeyValue("0","10"));packageInfo.Children.Add(appSection);
        Check(SteamInstallSizes.PackageEntitlements(new uint[]{7,8},new Dictionary<uint,KeyValue>{{7,packageInfo}})is null,"size-missing-requested-package-cannot-certify-partial-entitlements");
        Check(SteamInstallSizes.PackageEntitlements(new uint[]{7,7},new Dictionary<uint,KeyValue>{{7,packageInfo}})!.SetEquals(new uint[]{10}),"size-complete-package-coverage-deduplicates-licenses-and-depot-access");
        Check(SteamInstallSizes.Build(new(1,"windows",Language:"italian"),products,new HashSet<uint>{10}).InstalledBytes is null,"size-unsupported-engine-language-cannot-certify-different-selection");
        var ownedPlan=SteamInstallSizes.Build(new(1,"windows"),products,new HashSet<uint>{10});Check(ownedPlan.InstalledBytes==100&&ownedPlan.Depots.Count==1,"size-ownership-excludes-unlicensed-depots");
        var missingSize=Product("\"10\" {\"manifests\" {\"public\" {\"gid\" \"1\"}}}");var unavailable=SteamInstallSizes.Build(new(1,"windows"),new Dictionary<uint,KeyValue>{{1,missingSize}});
        Check(unavailable.InstalledBytes is null&&unavailable.DownloadBytes is null&&unavailable.Reason=="manifest_size_unavailable","missing-size-is-null-never-zero-or-partial-sum");
        var dlcProduct=Product(Depot(10,100,50,extra:"\"dlcappid\" \"123\""));Check(SteamInstallSizes.Build(new(1,"windows"),new Dictionary<uint,KeyValue>{{1,dlcProduct}}).Reason=="dlc_ownership_unknown","size-dlc-ownership-never-guessed");
        var proxy=Product("\"10\" {\"depotfromapp\" \"2\"}");var parent=Product(Depot(10,150,60));var shared=SteamInstallSizes.Build(new(1,"windows"),new Dictionary<uint,KeyValue>{{1,proxy},{2,parent}},new HashSet<uint>{10});
        Check(shared.InstalledBytes==150&&shared.DownloadBytes==60&&shared.Depots[0].SourceAppID==2,"size-shared-depot-parent-resolved");
        Check(SteamInstallSizes.Build(new(1,"windows"),new Dictionary<uint,KeyValue>{{1,proxy}}).InstalledBytes is null,"size-unresolved-shared-is-unavailable");
        var overflowing=Product(Depot(10,ulong.MaxValue,1)+Depot(11,1,1));Check(SteamInstallSizes.Build(new(1,"windows"),new Dictionary<uint,KeyValue>{{1,overflowing}}).Reason=="size_overflow","size-uint64-overflow-rejected");
        Check(SteamInstallSizes.Build(new(1,"windows","beta"),products).InstalledBytes is null,"size-private-branch-does-not-silently-use-public");
        var sizePayload=JSON(winPlan.Payload());Check(sizePayload.GetProperty("fingerprint").GetString()==JSON(winPlan.Payload()).GetProperty("fingerprint").GetString()&&sizePayload.GetProperty("calculatedAt").GetString()!.Length>0,"size-fingerprint-stable-and-filtered-plan-timestamped");
        var requirements=JSON(new{pc_requirements=new{minimum="<strong>Memory:</strong> 16 GB RAM<br><strong>Storage:</strong> 70 GB available space"},mac_requirements=new{minimum="<strong>Memory:</strong> 24 GB RAM"}});
        Check(SteamInstallSizes.MinimumRequirement(requirements,"pc_requirements")==70000000000UL&&SteamInstallSizes.MinimumRequirement(requirements,"mac_requirements")is null,"store-minimum-storage-distinct-from-ram-and-download");
        Check(JSON(SteamCatalogMetadata.LibraryGame(1,sized)).GetProperty("metadata").GetProperty("platformSizes").GetProperty("windows").GetProperty("downloadBytes").GetUInt64()==130,"catalog-platform-size-payload-compatible");
        var emitted=new List<JsonElement>();var pages=new SteamLibraryPages(true,(games,index)=>emitted.Add(JSON(new{games,pageIndex=index})));
        pages.Add(Enumerable.Range(1,1000).Select(i=>(object)new{id="steam:"+i,title=new string('x',5000)}));var final=JSON(pages.Complete());
        Check(final.GetProperty("gameCount").GetInt32()==1000&&final.GetProperty("pageCount").GetInt32()==emitted.Count&&!final.TryGetProperty("games",out _),"paged-library-over-four-MiB-terminal-counts");
        Check(emitted.Select((page,index)=>page.GetProperty("pageIndex").GetInt32()==index&&page.GetProperty("games").GetArrayLength()<=50&&JsonSerializer.SerializeToUtf8Bytes(page).Length<1024*1024).All(x=>x),"ordered-pages-within-byte-and-entry-bounds");
        Check(emitted.SelectMany(x=>x.GetProperty("games").EnumerateArray()).Select(x=>x.GetProperty("id").GetString()).Distinct().Count()==1000,"paged-library-complete-no-duplicate");
        rejected=false;try{pages.Add(new[]{new{id="steam:1"}});}catch(SteamLibraryPayloadException error){rejected=error.Code=="library_duplicate_entry";}Check(rejected,"duplicate-library-entry-rejected");
        rejected=false;try{new SteamLibraryPages(true,(_,_)=>{}).Add(new[]{new{id="steam:1",title=new string('x',1024*1024)}});}catch(SteamLibraryPayloadException error){rejected=error.Code=="library_entry_too_large";}Check(rejected,"oversized-single-library-entry-rejected");
        var classified=new SteamLibraryPages(true,(_,_)=>{});classified.Add(new[]{SteamCatalogMetadata.LibraryGame(1,null,owned,false),SteamCatalogMetadata.LibraryGame(3,tool,owned,true)});var classifiedEnd=JSON(classified.Complete());
        Check(classifiedEnd.GetProperty("gameCount").GetInt32()==2&&classifiedEnd.GetProperty("recordCount").GetInt32()==2&&classifiedEnd.GetProperty("libraryKindCounts").GetProperty("game").GetInt32()==1&&classifiedEnd.GetProperty("libraryKindCounts").GetProperty("tool").GetInt32()==1,"kind-counts-additive-legacy-record-count-preserved");
        var empty=JSON(new SteamLibraryPages(true,(_,_)=>throw new Exception()).Complete());Check(empty.GetProperty("gameCount").GetInt32()==0&&empty.GetProperty("pageCount").GetInt32()==0,"empty-paged-library-explicit-zero-counts");
        Console.WriteLine(JsonSerializer.Serialize(new{passed=true,checkCount=checks.Count,checks,realAuthenticationAttempted=false,steamConnectionCreated=false}));return 0;
    }
}
