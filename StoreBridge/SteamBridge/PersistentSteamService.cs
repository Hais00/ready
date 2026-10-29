// SPDX-License-Identifier: GPL-3.0-only
using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using SteamKit2;
using SteamKit2.Authentication;
using SteamKit2.Internal;

// The transport is injectable for offline state/protocol tests. Production uses
// SteamKit callbacks/jobs exclusively; no account, entitlement or presence stubs.
sealed class SteamServiceCredentials(string username,string refreshToken)
{
    internal string Username { get; }=username;
    internal string RefreshToken { get; }=refreshToken;
    public override string ToString()=>"[private Steam credentials]";
}
sealed record SteamServiceAccount(string steamID,string accountName,string displayName,string presence);
sealed record SteamServiceFriend(string steamID,string displayName,string presence,string? gameID,string? gameName,string relationship="Friend");
sealed record SteamServiceMutation(bool ServerAcknowledged,bool RequestSent,EResult? Result,string Status);
sealed record SteamTransportNotice(string Kind,EResult? Result=null,bool UserInitiated=false);
// Preserve callback facts until the service can report a bounded failure. Never
// serialize this object: a successful Decision contains private ticket metadata.
sealed record SteamServiceOwnership(GameOwnershipPreflight.Decision Decision,EResult Result,
    bool AppMatched,bool TicketNonEmpty,bool SteamIDPresent)
{
    internal static SteamServiceOwnership Observe(uint requested,EResult result,uint returned,byte[]? ticket,ulong? steamID)=>
        new(GameOwnershipPreflight.Decide(requested,result,returned,ticket,steamID),result,
            requested==returned,ticket is {Length:>0},steamID is not null and not 0);
    public override string ToString()=>"[private Steam ownership response]";
}
interface ISteamServiceTransport:IAsyncDisposable
{
    event Action<SteamTransportNotice>? Notice;
    Task ConnectAsync(CancellationToken cancel);
    Task<SteamServiceCredentials> AuthenticateAsync(string method,string username,string password,
        Action<string> qr,IAuthenticator guard,CancellationToken cancel);
    Task<EResult> LogOnAsync(SteamServiceCredentials credentials,CancellationToken cancel);
    Task StopAsync();
    SteamServiceAccount? Account(string username);
    IReadOnlyList<SteamServiceFriend> Friends();
    void SetPresence(EPersonaState presence);
    void SetActivity(IReadOnlyCollection<uint> apps);
    Task<SteamServiceMutation> SetPersonaNameAsync(string displayName,CancellationToken cancel);
    Task<SteamServiceMutation> FriendActionAsync(string operation,ulong steamID,CancellationToken cancel);
    Task<SteamServiceOwnership> AuthorizeAsync(uint appID,CancellationToken cancel);
    Task LibraryAsync(Action<object[]> page,CancellationToken cancel);
}

/// One process serves one immutable (profileID, profileGeneration). It receives
/// secrets only through its anonymous stdin; only the credentials event is private.
/// Process supervision/Keychain storage belong to the caller, not this service.
sealed class PersistentSteamService:IAsyncDisposable
{
    internal const int MaximumLine=65536,MaximumRequests=4096,MaximumPending=16;
    readonly ISteamServiceTransport transport;
    readonly TextWriter output;
    readonly object sync=new();
    readonly CancellationTokenSource lifetime=new();
    readonly SemaphoreSlim lifecycle=new(1,1);
    readonly SemaphoreSlim social=new(1,1);
    readonly Dictionary<string,CancellationTokenSource> pending=new(StringComparer.OrdinalIgnoreCase);
    readonly HashSet<string> explicitlyCancelled=new(StringComparer.OrdinalIgnoreCase);
    readonly HashSet<string> seen=new(StringComparer.OrdinalIgnoreCase);
    readonly HashSet<uint> authorizedApps=new(),runningApps=new();
    readonly List<Task> work=new();
    readonly Func<TimeSpan,CancellationToken,Task> delay;
    readonly TimeSpan requestBudget,heartbeatInterval;
    readonly Func<uint,string,CancellationToken,Task<Dictionary<string,object?>>> catalogMetadata;
    Task? heartbeat,reconnect;
    CancellationTokenSource? reconnectCancel;
    SteamServiceCredentials? credentials;
    string? profile,generation;
    string state="offline",reason="not_connected";
    EResult? lastConnectionResult;
    string? connectionResultContext;
    long sequence,epoch;
    bool blocked=true,disposed;
    string? guardChallenge;
    TaskCompletionSource<string>? guardAnswer;
    internal PersistentSteamService(ISteamServiceTransport transport,TextWriter output,
        Func<TimeSpan,CancellationToken,Task>? delay=null,TimeSpan? requestBudget=null,TimeSpan? heartbeatInterval=null,
        Func<uint,string,CancellationToken,Task<Dictionary<string,object?>>>? catalogMetadata=null)
    {
        this.transport=transport;this.output=output;
        this.catalogMetadata=catalogMetadata??new SteamPublicCatalog().DetailsAsync;
        this.delay=delay??Task.Delay;this.requestBudget=requestBudget??TimeSpan.FromMinutes(4);
        this.heartbeatInterval=heartbeatInterval??TimeSpan.FromSeconds(15);
        transport.Notice+=OnNotice;
    }
    internal static async Task<int> RunAsync(TextReader input,TextWriter output,ISteamServiceTransport transport)
    {
        await using var service=new PersistentSteamService(transport,output);
        try
        {
            while(!service.lifetime.IsCancellationRequested)
            {
                // Console.In may wrap a synchronous TextReader. Keep its blocking
                // read off the control task so shutdown can cancel without waiting
                // for the caller to send another frame/EOF.
                string? line=await Task.Run(()=>ReadBoundedLine(input,service.lifetime.Token)).WaitAsync(service.lifetime.Token);
                if(line is null)break;
                service.Accept(line);
            }
            return 0;
        }
        catch(OperationCanceledException){return 0;}
        catch(Exception){return 1;} // Never echo malformed input or exception messages.
    }
    internal static async Task<string?> ReadBoundedLine(TextReader input,CancellationToken cancel)
    {
        var line=new System.Text.StringBuilder();var character=new char[1];
        while(await input.ReadAsync(character.AsMemory(),cancel)!=0)
        {
            if(character[0]=='\n')return line.ToString().TrimEnd('\r');
            if(line.Length>=MaximumLine)throw new InvalidDataException();
            line.Append(character[0]);
        }
        if(line.Length!=0)throw new InvalidDataException(); // Require a complete JSONL frame.
        return null;
    }
    static string Text(JsonElement element,string key,string fallback="")
    {
        if(element.ValueKind!=JsonValueKind.Object)throw new ArgumentException();
        if(!element.TryGetProperty(key,out var value))return fallback;
        if(value.ValueKind!=JsonValueKind.String)throw new ArgumentException();
        return value.GetString()??fallback;
    }
    static string UUIDText(JsonElement element,string key)
    {
        var value=Text(element,key);
        if(!Guid.TryParseExact(value,"D",out var guid))throw new ArgumentException();
        return key is "id" or "requestID"?value:guid.ToString("D");
    }
    static JsonElement Options(JsonElement root)
    {
        var options=root.TryGetProperty("options",out var nested)?nested:root;
        if(options.ValueKind!=JsonValueKind.Object)throw new ArgumentException();
        return options;
    }
    static uint AppID(JsonElement root)=>GameOwnershipPreflight.AppID(JsonSerializer.SerializeToElement(new{options=Options(root)}));
    internal static ulong IndividualSteamID(string text,string? ownSteamID)
    {
        if(text.Length is <1 or >20||!text.All(char.IsAsciiDigit)||
            !ulong.TryParse(text,NumberStyles.None,CultureInfo.InvariantCulture,out var id)||
            id>>56!=1||(id>>52&15)!=1||(id>>32&0xfffff)!=1||(uint)id==0||
            (ownSteamID is not null&&ulong.TryParse(ownSteamID,NumberStyles.None,CultureInfo.InvariantCulture,out var own)&&id==own))throw new ArgumentException();
        return id;
    }
    static SteamServiceCredentials ReadCredentials(JsonElement root)
    {
        var value=root.GetProperty("credentials");string username=Text(value,"username"),token=Text(value,"refresh_token");
        if(username.Length is <1 or >64||!username.All(c=>char.IsAsciiLetterOrDigit(c)||c=='_')||
            token.Length is <1 or >8192||!token.All(c=>c is >=(char)33 and <=(char)126))throw new ArgumentException();
        return new(username,token);
    }
    void Emit(string type,string? id,Dictionary<string,object?>? fields=null)
    {
        lock(sync)
        {
            if(disposed||profile is null)return;
            var value=fields??new();
            value["type"]=type;value["id"]=id;value["profileID"]=profile;value["profileGeneration"]=generation;value["sequence"]=++sequence;
            string line=JsonSerializer.Serialize(value);
            if(line.Length>4*1024*1024)throw new InvalidDataException();
            output.WriteLine(line);output.Flush();
        }
    }
    void Result(string id,Dictionary<string,object?>? fields=null)=>Emit("result",id,fields);
    void Error(string id,string code,EResult? result=null)=>Emit("error",id,new(){["code"]=code,["steamResult"]=SteamSafeFailure.ResultName(result)});
    void State(string value,string why,double? retryAfter=null)
    {
        lock(sync){state=value;reason=why;Emit("state",null,new(){["state"]=value,["reason"]=why,["retryAfter"]=retryAfter,
            ["steamResult"]=SteamSafeFailure.ResultName(lastConnectionResult),["connectionResultContext"]=connectionResultContext});}
    }
    internal void Accept(string line)
    {
        // Invalid/unbound/duplicate envelopes cannot safely be correlated: reject
        // the process protocol rather than emit an error with a forged request ID.
        using var document=JsonDocument.Parse(line,new JsonDocumentOptions{MaxDepth=16});var root=document.RootElement;
        string id=UUIDText(root,"id"),incomingProfile=UUIDText(root,"profileID"),incomingGeneration=UUIDText(root,"profileGeneration");
        string operation=Text(root,"operation");
        lock(sync)
        {
            if(profile is null)
            {
                profile=incomingProfile;generation=incomingGeneration;
                heartbeat=Task.Run(Heartbeat);
            }
            if(profile!=incomingProfile||generation!=incomingGeneration)throw new InvalidDataException();
            if(seen.Count>=MaximumRequests||!seen.Add(id))throw new InvalidDataException();
            if(pending.Count>=MaximumPending){Error(id,"busy");return;}
            var cancel=CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);cancel.CancelAfter(requestBudget);pending[id]=cancel;
            var request=root.Clone();
            work.RemoveAll(t=>t.IsCompleted);
            work.Add(Task.Run(()=>Handle(id,operation,request,cancel)));
        }
    }
    async Task Handle(string id,string operation,JsonElement root,CancellationTokenSource cancel)
    {
        try
        {
            switch(operation)
            {
                case "snapshot":Snapshot(id,Options(root));break;
                case "friends":RequireOnline();Result(id,FriendPage(Options(root)));break;
                case "connect":case "authenticate":case "reconnect":
                    await Login(id,operation,root,cancel.Token);break;
                case "guard_code":
                    var options=Options(root);string challenge=Text(options,"challengeID"),code=Text(options,"code");
                    lock(sync)
                    {
                        if(guardChallenge!=challenge||guardAnswer is null||code.Length is <1 or >16||!code.All(char.IsAsciiLetterOrDigit))throw new ServiceFailure("invalid_guard_response");
                        guardAnswer.TrySetResult(code);guardChallenge=null;guardAnswer=null;
                    }
                    Result(id);break;
                case "set_presence":
                    RequireOnline();string presence=Text(Options(root),"presence");
                    if(!Enum.TryParse<EPersonaState>(presence,true,out var value)||!Enum.IsDefined(value))throw new ServiceFailure("invalid_presence");
                    if(value==EPersonaState.Offline){await Stop("offline","manual_offline",false,id);Result(id);break;}
                    if(!await social.WaitAsync(0,cancel.Token))throw new ServiceFailure("busy");
                    try{lock(sync){RequireOnline();transport.SetPresence(value);Result(id);PublishPersona();}}
                    finally{social.Release();}break;
                case "set_persona_name":case "add_friend":case "remove_friend":case "block_friend":case "unblock_friend":
                    await SocialAction(id,operation,Options(root),cancel.Token);break;
                case "authorize_game":
                    await AuthorizeGame(id,root,cancel.Token);break;
                case "set_activity":
                    RequireOnline();uint playingApp=AppID(root);var activityOptions=Options(root);
                    if(!activityOptions.TryGetProperty("running",out var running)||running.ValueKind is not (JsonValueKind.True or JsonValueKind.False))throw new ArgumentException();
                    lock(sync)
                    {
                        RequireOnline();
                        if(running.ValueKind==JsonValueKind.True)
                        {
                            if(!authorizedApps.Contains(playingApp))throw new ServiceFailure("not_authorized");
                            runningApps.Add(playingApp);
                        }
                        else runningApps.Remove(playingApp);
                        transport.SetActivity(runningApps);Result(id);
                    }
                    break;
                case "library":
                    RequireOnline();long libraryEpoch=CurrentEpoch();var libraryOptions=Options(root);bool paged=false;
                    if(libraryOptions.TryGetProperty("paged",out var pageOption)){if(pageOption.ValueKind is not (JsonValueKind.True or JsonValueKind.False))throw new ArgumentException();paged=pageOption.ValueKind==JsonValueKind.True;}
                    var pages=new SteamLibraryPages(paged,(games,index)=>Emit("library_page",id,new(){["games"]=games,["pageIndex"]=index}));
                    await transport.LibraryAsync(page=>{lock(sync){EnsureEpoch(libraryEpoch);cancel.Token.ThrowIfCancellationRequested();pages.Add(page);}},cancel.Token);
                    lock(sync){EnsureEpoch(libraryEpoch);cancel.Token.ThrowIfCancellationRequested();Result(id,pages.Complete());}break;
                case "catalog_metadata":
                    uint catalogApp=AppID(root);string language=SteamPublicCatalog.Language(Text(Options(root),"language","english"));
                    Dictionary<string,object?> details;
                    try{details=await catalogMetadata(catalogApp,language,cancel.Token);}
                    catch(OperationCanceledException)when(!cancel.IsCancellationRequested){throw new ServiceFailure("metadata_timeout");}
                    catch(Exception error)when(error is HttpRequestException or InvalidDataException or JsonException or System.Text.RegularExpressions.RegexMatchTimeoutException){throw new ServiceFailure("metadata_unavailable");}
                    lock(sync){cancel.Token.ThrowIfCancellationRequested();Result(id,new(){["appID"]=catalogApp,["metadata"]=details});}break;
                case "offline":case "logout":
                    bool forget=operation=="logout"&&Options(root).TryGetProperty("forgetCredentials",out var forgetValue)&&forgetValue.ValueKind==JsonValueKind.True;
                    await Stop(operation=="offline"?"offline":"logged_out",operation=="offline"?"manual_offline":"explicit_logout",forget,id);
                    Result(id,new(){["invalidateCredentials"]=forget});break;
                case "cancel":
                    string target=UUIDText(Options(root),"requestID");
                    lock(sync){if(pending.TryGetValue(target,out var request)&&target!=id){explicitlyCancelled.Add(target);request.Cancel();}}
                    Result(id);break;
                case "shutdown":await Stop("logged_out","shutdown",false,id);Result(id);lifetime.Cancel();break;
                default:throw new ServiceFailure("unsupported_operation");
            }
        }
        catch(ServiceFailure failure){Error(id,failure.Code,failure.Result);}
        catch(SteamLibraryPayloadException failure){Error(id,failure.Code);}
        catch(AuthenticationException failure){Error(id,"authentication_failed",failure.Result);}
        catch(OperationCanceledException){Error(id,cancel.IsCancellationRequested&&!lifetime.IsCancellationRequested?"cancelled":"disconnected");}
        catch(ArgumentException){Error(id,"invalid_request");}
        catch(JsonException){Error(id,"invalid_request");}
        catch(KeyNotFoundException){Error(id,"invalid_request");}
        catch(Exception){Error(id,"steam_error");}
        finally{lock(sync){pending.Remove(id);explicitlyCancelled.Remove(id);cancel.Dispose();}}
    }
    async Task AuthorizeGame(string id,JsonElement root,CancellationToken cancel)
    {
        SteamServiceOwnership? ownership=null;long? current=null;string stage="ownership_ticket";
        try
        {
            uint app;
            try{app=AppID(root);}catch(Exception){throw new ServiceFailure("invalid_game_id");}
            lock(sync){RequireOnline();current=epoch;cancel.ThrowIfCancellationRequested();}
            ownership=await transport.AuthorizeAsync(app,cancel);
            stage="ownership_decision";
            lock(sync)
            {
                EnsureEpoch(current.Value);cancel.ThrowIfCancellationRequested();
                if(!ownership.Decision.Authorized)
                {
                    string code=OwnershipCode(ownership.Result);
                    OwnershipError(id,code,stage,ownership,null);return;
                }
                authorizedApps.Add(app);
                Result(id,new(){["appID"]=app,["steamID"]=ownership.Decision.SteamID,["authorized"]=true,["ownershipTicketReceived"]=true,["backendSessionReady"]=false});
            }
        }
        catch(Exception error)
        {
            // State/epoch changes override even a late successful SDK callback.
            // A cancelled SDK AsyncJob without our token cancellation means its
            // message deadline elapsed; it is not evidence of missing ownership.
            lock(sync)
            {
                string code=current is {} observed&&(observed!=epoch||state!="online")||lifetime.IsCancellationRequested
                    ?"disconnected":error switch
                    {
                        ServiceFailure failure=>failure.Code,
                        OperationCanceledException=>explicitlyCancelled.Contains(id)?"cancelled":"timeout",
                        TimeoutException=>"timeout",IOException or System.Net.Sockets.SocketException=>"network_error",
                        AsyncJobFailedException=>"ownership_request_failed",_=>"steam_error"
                    };
                OwnershipError(id,code,stage,ownership,error);
            }
        }
    }
    static string OwnershipCode(EResult result)=>result switch
    {
        EResult.OK=>"ownership_invalid_response",
        EResult.AccessDenied or EResult.InsufficientPrivilege=>"not_authorized",
        EResult.Timeout=>"timeout",
        EResult.NoConnection or EResult.ConnectFailed or EResult.HandshakeFailed or EResult.IOFailure or
            EResult.RemoteDisconnect or EResult.ServiceUnavailable or EResult.TryAnotherCM=>"network_error",
        EResult.NotLoggedOn or EResult.Revoked or EResult.Expired or EResult.InvalidPassword or
            EResult.AccountDisabled or EResult.AccountLockedDown=>"authentication_required",
        EResult.RateLimitExceeded or EResult.LimitExceeded=>"rate_limited",_=>"ownership_request_failed"
    };
    void OwnershipError(string id,string code,string stage,SteamServiceOwnership? response,Exception? error)
    {
        string category=code switch
        {
            "not_authorized"=>response?.Result==EResult.AccessDenied?"not_owned":"permission_denied",
            "ownership_invalid_response"=>"invalid_callback","timeout"=>"timeout","network_error"=>"network",
            "authentication_required" or "not_online" or "disconnected"=>"session_unavailable",
            "cancelled"=>"cancelled","rate_limited"=>"rate_limited",_=>"request_failed"
        };
        Emit("error",id,new(){["code"]=code,["stage"]=stage,["steamResult"]=SteamSafeFailure.ResultName(response?.Result),
            ["exceptionKind"]=error is null?null:error is AsyncJobFailedException?"AsyncJobFailedException":SteamSafeFailure.ExceptionKind(error),
            ["ownershipFailure"]=category,["ownershipResponseReceived"]=response is not null,
            ["ownershipAppMatched"]=response?.AppMatched,["ownershipTicketNonEmpty"]=response?.TicketNonEmpty,
            ["ownershipSteamIDPresent"]=response?.SteamIDPresent,["ownershipDecisionAuthorized"]=response?.Decision.Authorized});
    }
    long CurrentEpoch(){lock(sync)return epoch;}
    void EnsureEpoch(long current){lock(sync){if(current!=epoch||state!="online")throw new ServiceFailure("disconnected");}}
    void RequireOnline(){lock(sync){if(state!="online")throw new ServiceFailure("not_online");}}
    async Task SocialAction(string id,string operation,JsonElement options,CancellationToken cancel)
    {
        RequireOnline();long current=CurrentEpoch();string? displayName=null;ulong target=0;
        if(operation=="set_persona_name")
        {
            displayName=Text(options,"displayName");
            if(string.IsNullOrWhiteSpace(displayName)||displayName.Length>128||displayName.Any(char.IsControl))throw new ArgumentException();
        }
        else target=IndividualSteamID(Text(options,"steamID"),transport.Account(credentials?.Username??"")?.steamID);
        if(!await social.WaitAsync(0,cancel))throw new ServiceFailure("busy");
        try
        {
            EnsureEpoch(current);cancel.ThrowIfCancellationRequested();
            var outcome=operation=="set_persona_name"
                ?await transport.SetPersonaNameAsync(displayName!,cancel)
                :await transport.FriendActionAsync(operation,target,cancel);
            lock(sync)
            {
                EnsureEpoch(current);cancel.ThrowIfCancellationRequested();
                if(outcome.ServerAcknowledged&&outcome.Result is {} result&&result!=EResult.OK)throw new ServiceFailure("social_request_failed",result);
                Result(id,new(){["requestedAction"]=operation,["requestedSteamID"]=target==0?null:target.ToString(CultureInfo.InvariantCulture),
                    ["serverAcknowledged"]=outcome.ServerAcknowledged,["requestSent"]=outcome.RequestSent,["pending"]=outcome.Status.StartsWith("awaiting_",StringComparison.Ordinal),
                    ["status"]=outcome.Status,["steamResult"]=SteamSafeFailure.ResultName(outcome.Result),["account"]=transport.Account(credentials?.Username??""),["friends"]=transport.Friends()});
                PublishPersona();
            }
        }
        finally{social.Release();}
    }
    async Task Login(string id,string operation,JsonElement root,CancellationToken cancel)
    {
        if(!await lifecycle.WaitAsync(0,cancel))throw new ServiceFailure("busy");
        long current;
        lock(sync)
        {
            if(state=="online"){lifecycle.Release();Result(id,new(){["alreadyOnline"]=true});return;}
            blocked=true;reconnectCancel?.Cancel();current=++epoch;authorizedApps.Clear();runningApps.Clear();
        }
        try
        {
            await transport.StopAsync();cancel.ThrowIfCancellationRequested();
            SteamServiceCredentials? selected;
            lock(sync)selected=operation=="reconnect"?credentials:null;
            if(operation=="connect")selected=ReadCredentials(root);
            if(operation=="reconnect"&&selected is null)throw new ServiceFailure("authentication_required");
            lock(sync){if(selected is not null)credentials=selected;}
            State("connecting","explicit_connect");await transport.ConnectAsync(cancel);
            if(operation=="authenticate")
            {
                State("authenticating","explicit_authentication");
                string method=Text(Options(root),"method","qr").ToLowerInvariant();
                if(method is not ("qr" or "password"))throw new ServiceFailure("invalid_request");
                string username="",password="";
                if(method=="password")
                {
                    var data=root.TryGetProperty("credentials",out var loginData)?loginData:Options(root);username=Text(data,"username");password=Text(data,"password");
                    if(username.Length is <1 or >64||password.Length is <1 or >1024)throw new ServiceFailure("invalid_request");
                }
                selected=await transport.AuthenticateAsync(method,username,password,url=>
                {
                    cancel.ThrowIfCancellationRequested();
                    if(!Uri.TryCreate(url,UriKind.Absolute,out var uri)||uri.Scheme!="https"||url.Length>4096)throw new ServiceFailure("invalid_qr");
                    Emit("qr",id,new(){["url"]=url});
                },new ServiceAuthenticator(this,id,cancel),cancel);
                password="";
            }
            cancel.ThrowIfCancellationRequested();
            if(selected is null)throw new ServiceFailure("authentication_required");
            lock(sync)
            {
                if(epoch!=current)throw new ServiceFailure("disconnected");
                credentials=selected;
                // The QR/password API has already issued a genuine refresh
                // credential. Preserve it before the separate CM logon, so a
                // transient network failure does not require another QR.
                if(operation=="authenticate")Emit("credentials",id,new(){["credentials"]=new{username=selected.Username,refresh_token=selected.RefreshToken}});
            }
            State("authenticating","logon");EResult login=await transport.LogOnAsync(selected,cancel);
            lock(sync)
            {
                if(epoch!=current)throw new ServiceFailure("disconnected");
                cancel.ThrowIfCancellationRequested();
                lastConnectionResult=login;connectionResultContext="logon_response";
                if(login!=EResult.OK)
                {
                    if(InvalidatesCredentials(login)||RemoteKick(login))ApplyLogOff(login,rejectedLogon:true);
                    else State("offline","logon_failed");
                    throw new ServiceFailure("steam_login_failed",login);
                }
                credentials=selected;blocked=false;
                State("online","logon_success");PublishPersona();
                Result(id,new(){["account"]=transport.Account(selected.Username)});
            }
        }
        catch
        {
            bool stop;lock(sync){stop=epoch==current;if(stop){blocked=true;++epoch;guardAnswer?.TrySetCanceled();guardAnswer=null;guardChallenge=null;}}
            if(stop){try{await transport.StopAsync();}finally{lock(sync){if(state is not ("authorization_required" or "logged_out"))State("offline","login_incomplete");}}}
            throw;
        }
        finally{lifecycle.Release();}
    }
    async Task Stop(string nextState,string why,bool forget,string? except=null)
    {
        lock(sync)
        {
            blocked=true;++epoch;reconnectCancel?.Cancel();authorizedApps.Clear();runningApps.Clear();guardAnswer?.TrySetCanceled();guardAnswer=null;guardChallenge=null;
            foreach(var pair in pending)if(pair.Key!=except)pair.Value.Cancel();
            if(forget)credentials=null;
            State(nextState,why);
        }
        await lifecycle.WaitAsync(lifetime.Token);
        try{await transport.StopAsync();}finally{lifecycle.Release();}
    }
    internal static bool InvalidatesCredentials(EResult result)=>result is EResult.Expired or EResult.Revoked or EResult.InvalidPassword or EResult.AccountDisabled or EResult.AccountLockedDown;
    internal static bool RemoteKick(EResult result)=>result is EResult.LoggedInElsewhere or EResult.AlreadyLoggedInElsewhere or EResult.LogonSessionReplaced;
    void ApplyLogOff(EResult result,bool rejectedLogon=false)
    {
        lock(sync)
        {
            if(disposed)return;
            lastConnectionResult=result;connectionResultContext=rejectedLogon?"logon_response":"logged_off";
            blocked=true;++epoch;reconnectCancel?.Cancel();authorizedApps.Clear();runningApps.Clear();
            // A server's LoggedOff result describes this CM session, not a
            // response to using the long-lived refresh credential. Preserve the
            // credential until an explicit subsequent LogOn actually rejects it.
            bool invalidate=rejectedLogon&&InvalidatesCredentials(result);
            bool needsAuthorization=invalidate||result is EResult.AccountDisabled or EResult.AccountLockedDown;
            if(invalidate)credentials=null;
            string why=result switch
            {
                EResult.Expired when !rejectedLogon=>"session_expired",
                EResult.Revoked when !rejectedLogon=>"server_session_revoked",
                EResult.InvalidPassword when !rejectedLogon=>"server_session_rejected",
                EResult.AccountDisabled when !rejectedLogon=>"account_disabled",
                EResult.AccountLockedDown when !rejectedLogon=>"account_locked",
                EResult.Revoked=>"revoked",EResult.Expired=>"expired",EResult.InvalidPassword=>"invalid_password",
                EResult.LogonSessionReplaced=>"session_replaced",EResult.LoggedInElsewhere or EResult.AlreadyLoggedInElsewhere=>"logged_in_elsewhere",
                _=>invalidate?"credentials_rejected":"server_logoff"
            };
            State(needsAuthorization?"authorization_required":"logged_out",why);
            Emit("state",null,new(){["state"]=state,["reason"]=reason,["steamResult"]=SteamSafeFailure.ResultName(result),
                ["connectionResultContext"]=connectionResultContext,["invalidateCredentials"]=invalidate});
            foreach(var request in pending.Values)request.Cancel();
            long stoppedEpoch=epoch;
            work.Add(Task.Run(async()=>
            {
                try
                {
                    await lifecycle.WaitAsync(lifetime.Token);
                    try{lock(sync){if(epoch!=stoppedEpoch)return;}await transport.StopAsync();}
                    finally{lifecycle.Release();}
                }
                catch(OperationCanceledException){}
                catch(Exception){lock(sync){if(!disposed&&epoch==stoppedEpoch)State(state,"cleanup_failed");}}
            }));
        }
    }
    void OnNotice(SteamTransportNotice notice)
    {
        lock(sync)
        {
            if(disposed||profile is null)return;
            if(notice.Kind=="logged_off"&&notice.Result is {} result){ApplyLogOff(result);return;}
            if(notice.Kind=="persona"){PublishPersona();return;}
            if(notice.Kind=="friends")
            {
                if(state=="online")Emit("friends",null,new(){["friends"]=transport.Friends(),["changed"]=true});
                return;
            }
            if(notice.Kind!="disconnected"||blocked||notice.UserInitiated)return;
            ++epoch;authorizedApps.Clear();runningApps.Clear();State("reconnecting","network_disconnected");
            // A delayed server LoggedOff callback still overrides this retry via
            // epoch/blocked. A kicked or revoked session never silently relogs.
            foreach(var request in pending.Values)request.Cancel();
            if(reconnect is null||reconnect.IsCompleted)
            {
                reconnectCancel?.Dispose();reconnectCancel=CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
                reconnect=Task.Run(()=>Reconnect(reconnectCancel.Token));
            }
        }
    }
    async Task Reconnect(CancellationToken cancel)
    {
        try
        {
            // Six finite attempts (1,2,4,8,16,30 seconds), each 30-second I/O
            // budget. Explicit reconnect is required after exhaustion.
            foreach(int seconds in new[]{1,2,4,8,16,30})
            {
                SteamServiceCredentials? selected;long current;
                lock(sync){if(blocked)return;selected=credentials;current=epoch;State("reconnecting","network_disconnected",seconds);}
                if(selected is null)return;
                await delay(TimeSpan.FromSeconds(seconds),cancel);
                await lifecycle.WaitAsync(cancel);
                try
                {
                    lock(sync){if(blocked||epoch!=current)return;}
                    using var budget=CancellationTokenSource.CreateLinkedTokenSource(cancel);budget.CancelAfter(TimeSpan.FromSeconds(30));
                    await transport.StopAsync();await transport.ConnectAsync(budget.Token);
                    var result=await transport.LogOnAsync(selected,budget.Token);
                    lock(sync)
                    {
                        if(blocked||epoch!=current)return;
                        budget.Token.ThrowIfCancellationRequested();
                        lastConnectionResult=result;connectionResultContext="logon_response";
                        if(result!=EResult.OK)
                        {
                            if(InvalidatesCredentials(result)||RemoteKick(result)||result==EResult.AccessDenied){ApplyLogOff(result,rejectedLogon:true);return;}
                            continue;
                        }
                        State("online","reconnected");PublishPersona();
                    }
                    return;
                }
                catch(OperationCanceledException)when(!cancel.IsCancellationRequested){}
                catch(Exception)when(!cancel.IsCancellationRequested){}
                finally{lifecycle.Release();}
            }
            long stoppedEpoch;
            lock(sync){if(blocked)return;blocked=true;stoppedEpoch=++epoch;State("offline","reconnect_exhausted");}
            await lifecycle.WaitAsync(cancel);
            try{lock(sync){if(epoch!=stoppedEpoch)return;}await transport.StopAsync();}
            finally{lifecycle.Release();}
        }
        catch(OperationCanceledException){}
    }
    Dictionary<string,object?> FriendPage(JsonElement options)
    {
        int offset=0,limit=20000;
        if(options.TryGetProperty("offset",out var offsetValue)&&!offsetValue.TryGetInt32(out offset))throw new ArgumentException();
        if(options.TryGetProperty("limit",out var limitValue)&&!limitValue.TryGetInt32(out limit))throw new ArgumentException();
        if(offset<0||limit is <1 or >20000)throw new ArgumentException();
        var friends=transport.Friends();
        return new(){["friends"]=friends.Skip(offset).Take(limit).ToArray(),["total"]=friends.Count,["offset"]=offset,["nextOffset"]=offset+limit<friends.Count?offset+limit:null};
    }
    void Snapshot(string id,JsonElement options)
    {
        lock(sync)
        {
            var fields=state=="online"?FriendPage(options):new Dictionary<string,object?>{["friends"]=Array.Empty<object>()};
            fields["state"]=state;fields["reason"]=reason;fields["account"]=state=="online"?transport.Account(credentials?.Username??""):null;
            fields["steamResult"]=SteamSafeFailure.ResultName(lastConnectionResult);fields["connectionResultContext"]=connectionResultContext;
            fields["capabilities"]=new[]{"connect","authenticate","guard_code","snapshot","friends","set_presence","set_persona_name","add_friend","remove_friend","block_friend","unblock_friend","set_activity","authorize_game","library","catalog_metadata","offline","reconnect","logout","cancel","shutdown"};
            fields["protocolVersion"]=1;fields["backendSessionReady"]=false;
            Result(id,fields);
        }
    }
    void PublishPersona()
    {
        lock(sync)
        {
            if(state!="online")return;
            var account=transport.Account(credentials?.Username??"");if(account is null)return;
            Emit("persona",null,new(){["steamID"]=account.steamID,["accountName"]=account.accountName,["displayName"]=account.displayName,["presence"]=account.presence});
        }
    }
    async Task Heartbeat()
    {
        try{while(true){await Task.Delay(heartbeatInterval,lifetime.Token);lock(sync){Emit("heartbeat",null,new(){["state"]=state});}}}
        catch(OperationCanceledException){}
    }
    sealed class ServiceFailure(string code,EResult? result=null):Exception
    {internal string Code=>code;internal EResult? Result=>result;}
    sealed class ServiceAuthenticator(PersistentSteamService service,string requestID,CancellationToken cancel):IAuthenticator
    {
        Task<string> Ask(string method,bool incorrect)
        {
            lock(service.sync)
            {
                cancel.ThrowIfCancellationRequested();
                string challenge=Guid.NewGuid().ToString("D");
                var answer=new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
                service.guardChallenge=challenge;service.guardAnswer=answer;
                service.Emit("guard",requestID,new(){["challengeID"]=challenge,["method"]=method,["previousCodeWasIncorrect"]=incorrect,["instructions"]=method=="email"?"Enter the Steam Guard email code.":"Enter the Steam Guard authenticator code."});
                return answer.Task.WaitAsync(cancel);
            }
        }
        public Task<string> GetDeviceCodeAsync(bool incorrect)=>Ask("device_code",incorrect);
        public Task<string> GetEmailCodeAsync(string email,bool incorrect)=>Ask("email",incorrect); // Never echo email.
        public Task<bool> AcceptDeviceConfirmationAsync()
        {
            service.Emit("guard",requestID,new(){["method"]= "device_confirmation",["instructions"]="Approve the sign-in in the Steam mobile app."});
            return Task.FromResult(true);
        }
    }
    public async ValueTask DisposeAsync()
    {
        lock(sync)
        {
            if(disposed)return;
            disposed=true;blocked=true;++epoch;credentials=null;lifetime.Cancel();reconnectCancel?.Cancel();
            guardAnswer?.TrySetCanceled();guardAnswer=null;guardChallenge=null;
            foreach(var request in pending.Values)request.Cancel();
        }
        transport.Notice-=OnNotice;
        // All protocol jobs have finite budgets/cancellation. Await them before
        // disposing the exact transport, never another process's Steam session.
        await Task.WhenAll(work);
        if(reconnect is not null)await reconnect;
        if(heartbeat is not null)await heartbeat;
        await transport.DisposeAsync();
        reconnectCancel?.Dispose();lifetime.Dispose();lifecycle.Dispose();social.Dispose();
    }
}

// Target-correlated callbacks have no job ID for rename/add/remove. Keep their
// slot occupied after timeout/cancellation: a late reply must not acknowledge a
// newly sent request. Only a matching callback or connection reset frees it.
sealed class SteamSocialConfirmation
{
    internal sealed class Pending(string operation,string target,string key)
    {
        internal string Operation=>operation;
        internal string Target=>target;
        internal string Key=>key;
        internal TaskCompletionSource<SteamServiceMutation> Completion {get;}=new(TaskCreationOptions.RunContinuationsAsynchronously);
    }
    readonly object sync=new();
    readonly Dictionary<string,Pending> pending=new(StringComparer.Ordinal);
    internal Pending? Begin(string operation,string target)
    {
        string key=operation=="set_persona_name"?"persona":"friend:"+target;
        lock(sync){if(pending.ContainsKey(key))return null;var item=new Pending(operation,target,key);pending.Add(key,item);return item;}
    }
    internal void Complete(Pending item,EResult? result,string status)
    {
        lock(sync)
        {
            if(!pending.TryGetValue(item.Key,out var current)||!ReferenceEquals(current,item))return;
            pending.Remove(item.Key);item.Completion.TrySetResult(new(true,true,result,status));
        }
    }
    internal void Failed(Pending item)
    {
        lock(sync)
        {
            if(!pending.TryGetValue(item.Key,out var current)||!ReferenceEquals(current,item))return;
            pending.Remove(item.Key);item.Completion.TrySetException(new IOException());
        }
    }
    internal void Persona(string returnedName,EResult result)
    {
        lock(sync){if(pending.TryGetValue("persona",out var item)&&item.Target==returnedName)Complete(item,result,"server_acknowledged");}
    }
    internal void Added(ulong id,EResult result)
    {
        lock(sync){if(pending.TryGetValue("friend:"+id.ToString(CultureInfo.InvariantCulture),out var item)&&item.Operation=="add_friend")Complete(item,result,"friend_request_acknowledged");}
    }
    internal void Relationships(bool incremental,IReadOnlyDictionary<ulong,EFriendRelationship> relationships)
    {
        lock(sync)
        {
            foreach(var item in pending.Values.ToArray())
            {
                if(item.Operation!="remove_friend")continue;
                ulong id=ulong.Parse(item.Target,CultureInfo.InvariantCulture);
                if(relationships.TryGetValue(id,out var relationship)?relationship==EFriendRelationship.None:!incremental)
                    Complete(item,null,"relationship_removed");
            }
        }
    }
    internal void Reset()
    {
        lock(sync){foreach(var item in pending.Values)item.Completion.TrySetCanceled();pending.Clear();}
    }
    internal static async Task<SteamServiceMutation> Wait(Pending? item,CancellationToken cancel,TimeSpan? timeout=null)
    {
        if(item is null)return new(false,false,null,"awaiting_prior_confirmation");
        try{return await item.Completion.Task.WaitAsync(timeout??TimeSpan.FromSeconds(15),cancel);}
        catch(TimeoutException){return new(false,true,null,"awaiting_server_confirmation");}
    }
}

// Actual SteamKit adapter. The callback pump remains alive throughout the
// service, including reconnects. All subscriptions are owned by this instance.
sealed class SteamKitServiceTransport:ISteamServiceTransport
{
    readonly SteamClient client=new();
    readonly CallbackManager callbacks;
    readonly SteamUser user;
    readonly SteamApps apps;
    readonly SteamFriends friends;
    readonly CancellationTokenSource lifetime=new();
    readonly List<IDisposable> subscriptions=new();
    readonly object sync=new();
    readonly Task pump;
    readonly SteamSocialConfirmation socialConfirmation=new();
    string? confirmedDisplayName;
    // Downloader uses the disjoint 0xD0000000..0xDfffffff range.
    readonly uint loginID=(BitConverter.ToUInt32(RandomNumberGenerator.GetBytes(4))&0x7fffffffU)|1U;
    bool stopping;
    TaskCompletionSource<bool>? connected;
    TaskCompletionSource<EResult>? loggedOn;
    TaskCompletionSource<SteamApps.LicenseListCallback> licenses=NewCompletion<SteamApps.LicenseListCallback>();
    public event Action<SteamTransportNotice>? Notice;
    static TaskCompletionSource<T> NewCompletion<T>()=>new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal SteamKitServiceTransport()
    {
        callbacks=new(client);user=client.GetHandler<SteamUser>()!;apps=client.GetHandler<SteamApps>()!;friends=client.GetHandler<SteamFriends>()!;
        subscriptions.Add(callbacks.Subscribe<SteamClient.ConnectedCallback>(_=>{lock(sync)connected?.TrySetResult(true);}));
        subscriptions.Add(callbacks.Subscribe<SteamUser.LoggedOnCallback>(value=>{lock(sync)loggedOn?.TrySetResult(value.Result);}));
        subscriptions.Add(callbacks.Subscribe<SteamApps.LicenseListCallback>(value=>{lock(sync)licenses.TrySetResult(value);}));
        subscriptions.Add(callbacks.Subscribe<SteamClient.DisconnectedCallback>(value=>
        {
            lock(sync){connected?.TrySetException(new IOException());loggedOn?.TrySetException(new IOException());licenses.TrySetException(new IOException());}
            Notice?.Invoke(new("disconnected",UserInitiated:value.UserInitiated));
        }));
        subscriptions.Add(callbacks.Subscribe<SteamUser.LoggedOffCallback>(value=>{lock(sync){if(!stopping)Notice?.Invoke(new("logged_off",value.Result));}}));
        subscriptions.Add(callbacks.Subscribe<DrainCallback>(value=>value.Completion.TrySetResult(true)));
        subscriptions.Add(callbacks.Subscribe<SteamUser.AccountInfoCallback>(value=>{Volatile.Write(ref confirmedDisplayName,value.PersonaName);Notice?.Invoke(new("persona"));}));
        subscriptions.Add(callbacks.Subscribe<SteamFriends.PersonaChangeCallback>(value=>
        {
            Volatile.Write(ref confirmedDisplayName,value.Name);
            socialConfirmation.Persona(value.Name,value.Result);Notice?.Invoke(new("persona"));
        }));
        subscriptions.Add(callbacks.Subscribe<SteamFriends.FriendAddedCallback>(value=>socialConfirmation.Added(value.SteamID.ConvertToUInt64(),value.Result)));
        subscriptions.Add(callbacks.Subscribe<SteamFriends.PersonaStateCallback>(_=>{Notice?.Invoke(new("persona"));Notice?.Invoke(new("friends"));}));
        subscriptions.Add(callbacks.Subscribe<SteamFriends.FriendsListCallback>(value=>
        {
            socialConfirmation.Relationships(value.Incremental,value.FriendList.GroupBy(item=>item.SteamID.ConvertToUInt64()).ToDictionary(group=>group.Key,group=>group.Last().Relationship));
            Notice?.Invoke(new("friends"));
        }));
        pump=Task.Run(async()=>{try{while(!lifetime.IsCancellationRequested)await callbacks.RunWaitCallbackAsync(lifetime.Token);}catch(OperationCanceledException){}});
    }
    public async Task ConnectAsync(CancellationToken cancel)
    {
        Task<bool> task;lock(sync){connected=NewCompletion<bool>();task=connected.Task;}
        client.Connect();await task.WaitAsync(cancel);
    }
    public async Task<SteamServiceCredentials> AuthenticateAsync(string method,string username,string password,Action<string> qr,IAuthenticator guard,CancellationToken cancel)
    {
        AuthSession session;
        if(method=="qr")
        {
            var auth=await client.Authentication.BeginAuthSessionViaQRAsync(new AuthSessionDetails{IsPersistentSession=true,DeviceFriendlyName="Ready for macOS"}).WaitAsync(cancel);
            auth.ChallengeURLChanged=()=>qr(auth.ChallengeURL);qr(auth.ChallengeURL);session=auth;
        }
        else session=await client.Authentication.BeginAuthSessionViaCredentialsAsync(new AuthSessionDetails{Username=username,Password=password,IsPersistentSession=true,DeviceFriendlyName="Ready for macOS",Authenticator=guard}).WaitAsync(cancel);
        var result=await session.PollingWaitForResultAsync(cancel);
        return new(result.AccountName,result.RefreshToken);
    }
    public async Task<EResult> LogOnAsync(SteamServiceCredentials credentials,CancellationToken cancel)
    {
        Task<EResult> task;lock(sync){loggedOn=NewCompletion<EResult>();licenses=NewCompletion<SteamApps.LicenseListCallback>();task=loggedOn.Task;}
        var details=SteamLoginPolicy.CreateLogOnDetails(credentials.Username,credentials.RefreshToken);details.LoginID=loginID;
        user.LogOn(details);return await task.WaitAsync(cancel);
    }
    public async Task StopAsync()
    {
        // Dispose/Disconnect may synchronously join a socket worker; never invoke
        // it from that callback/pump. The vendored close-task fix is also required.
        lock(sync)stopping=true;
        try
        {
            await Task.Run(()=>{if(client.IsConnected)user.LogOff();client.Disconnect();});
            // Disconnect guarantees its connection callback has been posted.
            // Drain all earlier callbacks before reusing this client/TCS set.
            var barrier=new DrainCallback();client.PostCallback(barrier);
            await barrier.Completion.Task.WaitAsync(TimeSpan.FromSeconds(5));
        }
        finally{socialConfirmation.Reset();Volatile.Write(ref confirmedDisplayName,null);lock(sync)stopping=false;}
    }
    public SteamServiceAccount? Account(string username)
    {
        if(client.SteamID is not {} id)return null;
        return new(id.ConvertToUInt64().ToString(CultureInfo.InvariantCulture),username,Bound(Volatile.Read(ref confirmedDisplayName)??friends.GetPersonaName()),friends.GetPersonaState().ToString());
    }
    static string Bound(string? value)=>value is null?"":value.Length>256?value[..256]:value;
    public IReadOnlyList<SteamServiceFriend> Friends()
    {
        var result=new List<SteamServiceFriend>();int count=Math.Min(friends.GetFriendCount(),20000);
        for(int index=0;index<count;index++)
        {
            var id=friends.GetFriendByIndex(index);if(id.ConvertToUInt64()==0)continue;
            var game=friends.GetFriendGamePlayed(id);
            string gameName=Bound(friends.GetFriendGamePlayedName(id));
            result.Add(new(id.ConvertToUInt64().ToString(CultureInfo.InvariantCulture),Bound(friends.GetFriendPersonaName(id)),friends.GetFriendPersonaState(id).ToString(),game.ToUInt64()==0?null:game.ToUInt64().ToString(CultureInfo.InvariantCulture),string.IsNullOrEmpty(gameName)?null:gameName,friends.GetFriendRelationship(id).ToString()));
        }
        return result;
    }
    public void SetPresence(EPersonaState presence)=>friends.SetPersonaState(presence);
    public async Task<SteamServiceMutation> SetPersonaNameAsync(string displayName,CancellationToken cancel)
    {
        cancel.ThrowIfCancellationRequested();
        string current=Volatile.Read(ref confirmedDisplayName)??friends.GetPersonaName()??"";
        var item=socialConfirmation.Begin("set_persona_name",displayName);
        if(item is null)return await SteamSocialConfirmation.Wait(null,cancel);
        if(displayName==current){socialConfirmation.Complete(item,null,"unchanged");return new(false,false,null,"unchanged");}
        Volatile.Write(ref confirmedDisplayName,current); // SDK eagerly caches the requested name; do not publish it as confirmed.
        friends.SetPersonaName(displayName);
        return await SteamSocialConfirmation.Wait(item,cancel);
    }
    public async Task<SteamServiceMutation> FriendActionAsync(string operation,ulong target,CancellationToken cancel)
    {
        cancel.ThrowIfCancellationRequested();
        var id=new SteamID(target);
        if(operation=="remove_friend"&&friends.GetFriendRelationship(id)==EFriendRelationship.None)return new(false,false,null,"unchanged");
        var item=socialConfirmation.Begin(operation,target.ToString(CultureInfo.InvariantCulture));
        if(item is null)return await SteamSocialConfirmation.Wait(null,cancel);
        switch(operation)
        {
            case "add_friend":friends.AddFriend(id);break;
            case "remove_friend":friends.RemoveFriend(id);break;
            case "block_friend":case "unblock_friend":
                // This API has a genuine job ID, unlike add/remove. Complete only
                // this exact Pending instance; late jobs cannot affect a new epoch.
                _=ObserveIgnore(friends.IgnoreFriend(id,operation=="block_friend").ToTask(),item);break;
            default:throw new ArgumentException();
        }
        return await SteamSocialConfirmation.Wait(item,cancel);
    }
    async Task ObserveIgnore(Task<SteamFriends.IgnoreFriendCallback> job,SteamSocialConfirmation.Pending item)
    {
        try{var response=await job;socialConfirmation.Complete(item,response.Result,"server_acknowledged");}
        catch{socialConfirmation.Failed(item);}
    }
    public void SetActivity(IReadOnlyCollection<uint> apps)
    {
        var message=new ClientMsgProtobuf<CMsgClientGamesPlayed>(EMsg.ClientGamesPlayed);
        foreach(uint app in apps)message.Body.games_played.Add(new CMsgClientGamesPlayed.GamePlayed{game_id=app});
        client.Send(message);
    }
    public async Task<SteamServiceOwnership> AuthorizeAsync(uint appID,CancellationToken cancel)
    {
        var request=apps.GetAppOwnershipTicket(appID).ToTask();SteamApps.AppOwnershipTicketCallback? response=null;
        try
        {
            response=await request.WaitAsync(cancel);
            return SteamServiceOwnership.Observe(appID,response.Result,response.AppID,response.Ticket,client.SteamID?.ConvertToUInt64());
        }
        finally
        {
            if(response?.Ticket is {} ticket)CryptographicOperations.ZeroMemory(ticket);
            else _=request.ContinueWith(completed=>
            {
                if(completed.IsCompletedSuccessfully&&completed.Result.Ticket is {} lateTicket)CryptographicOperations.ZeroMemory(lateTicket);
                else _=completed.Exception;
            },CancellationToken.None,TaskContinuationOptions.ExecuteSynchronously,TaskScheduler.Default);
        }
    }
    public async Task LibraryAsync(Action<object[]> page,CancellationToken cancel)
    {
        Task<SteamApps.LicenseListCallback> task;lock(sync)task=licenses.Task;
        var licenseList=await task.WaitAsync(cancel);
        if(licenseList.Result!=EResult.OK)throw new IOException();
        var ids=new HashSet<uint>();
        foreach(var chunk in licenseList.LicenseList.Chunk(100))
        {
            var requests=chunk.Select(value=>new SteamApps.PICSRequest(value.PackageID,value.AccessToken));
            var packages=await apps.PICSGetProductInfo(Array.Empty<SteamApps.PICSRequest>(),requests).ToTask().WaitAsync(cancel);
            if(!packages.Complete||packages.Failed||packages.Results is null)throw new IOException();
            foreach(var part in packages.Results)foreach(var package in part.Packages.Values)
                if(package.KeyValues is {} values)foreach(var id in values["appids"].Children)if(uint.TryParse(id.Value,out var value))ids.Add(value);
        }
        foreach(var chunk in ids.Chunk(50))
        {
            var access=await apps.PICSGetAccessTokens(chunk,Array.Empty<uint>()).ToTask().WaitAsync(cancel);
            var info=await apps.PICSGetProductInfo(chunk.Select(id=>new SteamApps.PICSRequest(id,access.AppTokens.GetValueOrDefault(id))),Array.Empty<SteamApps.PICSRequest>()).ToTask().WaitAsync(cancel);
            if(!info.Complete||info.Failed||info.Results is null)throw new IOException();
            var games=new List<object>();var records=new Dictionary<uint,KeyValue>();
            foreach(var part in info.Results)foreach(var app in part.Apps.Values)
                if(app.KeyValues is {} values)records[app.ID]=values;
            foreach(uint id in chunk)
            {
                records.TryGetValue(id,out var values);
                if(SteamCatalogMetadata.IsLibraryApp(values))games.Add(SteamCatalogMetadata.LibraryGame(id,values));
            }
            page(games.ToArray());
        }
    }
    public async ValueTask DisposeAsync()
    {
        await StopAsync();lifetime.Cancel();await pump;
        foreach(var subscription in subscriptions)subscription.Dispose();lifetime.Dispose();
    }
    sealed class DrainCallback:CallbackMsg
    {internal TaskCompletionSource<bool> Completion {get;}=NewCompletion<bool>();}
}
