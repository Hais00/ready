// SPDX-License-Identifier: GPL-3.0-only
// SteamKit usage follows the upstream LGPL authentication samples. No Valve client binaries.
using System.Text.Json;
using System.Globalization;
using System.Security.Cryptography;
using SteamKit2;
using SteamKit2.Authentication;

static class Program
{
    static void Emit(object obj) { Console.WriteLine(JsonSerializer.Serialize(obj)); Console.Out.Flush(); }
    static string Str(JsonElement e, string name, string fallback="")
    {
        if(e.ValueKind!=JsonValueKind.Object)throw new Exception("invalid_request");
        if(!e.TryGetProperty(name,out var value)||value.ValueKind==JsonValueKind.Null)return fallback;
        if(value.ValueKind!=JsonValueKind.String)throw new Exception("invalid_request");
        return value.GetString() ?? fallback;
    }
    static TaskCompletionSource<T> Completion<T>() => new(TaskCreationOptions.RunContinuationsAsynchronously);
    static async Task<int> Main()
    {
        var stage=SteamOperationStage.Request;EResult? observedResult=null;
        SteamOwnershipFacts? ownershipFacts=null;
        try
        {
            var input=await Console.In.ReadLineAsync();
            if(input is null || input.Length>16*1024*1024) throw new Exception("invalid_request");
            using var doc=JsonDocument.Parse(input); var root=doc.RootElement;
            var op=Str(root,"operation");
            if(op=="self_test") { Emit(new {type="result",helper="SteamKit2",protocolVersion=1,transport="stdin-jsonl",libraryParsing="compiled",version="3.5.1-Alpha.1"});return 0; }
            if(op is not ("auth_begin" or "auth_start" or "library" or "launch_info" or "authorize_game"))throw new Exception("unsupported_operation");
            // Structural validation happens before allocating/connecting a SteamClient.
            uint ownershipAppID=op=="authorize_game" ? GameOwnershipPreflight.AppID(root) : 0;
            string name="",token="";
            if(op is not ("auth_begin" or "auth_start"))
            {
                if(!root.TryGetProperty("credentials",out var credentials)||credentials.ValueKind!=JsonValueKind.Object)throw new Exception("authentication_required");
                name=Str(credentials,"username");token=Str(credentials,"refresh_token");
                if(string.IsNullOrWhiteSpace(name)||string.IsNullOrEmpty(token))throw new Exception("authentication_required");
            }
            using var deadline=new CancellationTokenSource(TimeSpan.FromMinutes(4));
            var client=new SteamClient(); var callbacks=new CallbackManager(client);
            var user=client.GetHandler<SteamUser>()!;var apps=client.GetHandler<SteamApps>()!;
            var connected=Completion<bool>();var loggedOn=Completion<SteamUser.LoggedOnCallback>();var licenses=Completion<SteamApps.LicenseListCallback>();
            using var c1=callbacks.Subscribe<SteamClient.ConnectedCallback>(_=>connected.TrySetResult(true));
            using var c2=callbacks.Subscribe<SteamUser.LoggedOnCallback>(c=>loggedOn.TrySetResult(c));
            using var c3=callbacks.Subscribe<SteamApps.LicenseListCallback>(c=>licenses.TrySetResult(c));
            using var c4=callbacks.Subscribe<SteamClient.DisconnectedCallback>(_=>{ if(!deadline.IsCancellationRequested) { connected.TrySetException(new Exception("disconnected"));loggedOn.TrySetException(new Exception("disconnected"));licenses.TrySetException(new Exception("disconnected")); }});
            var pump=Task.Run(async ()=>{try{while(!deadline.IsCancellationRequested)await callbacks.RunWaitCallbackAsync(deadline.Token);}catch(OperationCanceledException){} });
            stage=SteamOperationStage.Connecting;
            client.Connect();await connected.Task.WaitAsync(deadline.Token);
            if(op is "auth_begin" or "auth_start")
            {
                stage=SteamOperationStage.QRAuthentication;observedResult=null;
                var auth=await client.Authentication.BeginAuthSessionViaQRAsync(new AuthSessionDetails { IsPersistentSession=true, DeviceFriendlyName="Ready for macOS" });
                void QR()=>Emit(new {type="qr",url=auth.ChallengeURL,instructions="Scan with the Steam mobile app and approve sign-in."});
                auth.ChallengeURLChanged=QR;QR();
                var result=await auth.PollingWaitForResultAsync(deadline.Token);
                Emit(new {type="result",credentials=new {username=result.AccountName,refresh_token=result.RefreshToken,access_token=result.AccessToken}});
                deadline.Cancel();client.Disconnect();await pump;return 0;
            }
            stage=SteamOperationStage.LogOn;observedResult=null;
            user.LogOn(SteamLoginPolicy.CreateLogOnDetails(name,token));
            var login=await loggedOn.Task.WaitAsync(deadline.Token);
            observedResult=login.Result;
            if(login.Result!=EResult.OK)throw new Exception("steam_login_failed");
            if(op=="authorize_game")
            {
                stage=SteamOperationStage.OwnershipTicket;observedResult=null;
                ownershipFacts=new();
                SteamApps.AppOwnershipTicketCallback? ownership=null;
                GameOwnershipPreflight.Decision decision=default;
                SteamOwnershipFailure? failure=null;
                try
                {
                    ownership=await apps.GetAppOwnershipTicket(ownershipAppID).ToTask().WaitAsync(deadline.Token);
                    stage=SteamOperationStage.OwnershipResponse;
                    ownershipFacts.ResponseReceived=true;
                    observedResult=ownership.Result;
                    ulong? steamID=client.SteamID?.ConvertToUInt64();
                    ownershipFacts.Observe(ownershipAppID,ownership.AppID,ownership.Ticket,steamID);
                    stage=SteamOperationStage.OwnershipDecision;
                    decision=GameOwnershipPreflight.Decide(ownershipAppID,ownership.Result,ownership.AppID,ownership.Ticket,steamID);
                    ownershipFacts.DecisionAuthorized=decision.Authorized;
                    if(!decision.Authorized)throw new Exception("not_authorized");
                }
                catch(Exception error){failure=new(error,stage);}
                var cleanupFailure=await SteamOwnershipCleanup.Run(async cleanupStage=>
                {
                    stage=cleanupStage;
                    switch(cleanupStage)
                    {
                        case SteamOperationStage.OwnershipClearTicket:
                            if(ownership?.Ticket is { } ticket)CryptographicOperations.ZeroMemory(ticket);
                            break;
                        case SteamOperationStage.OwnershipLogOff:user.LogOff();break;
                        case SteamOperationStage.OwnershipCancel:deadline.Cancel();break;
                        case SteamOperationStage.OwnershipDisconnect:client.Disconnect();break;
                        case SteamOperationStage.OwnershipPump:await pump;break;
                    }
                },ownershipFacts);
                failure??=cleanupFailure;
                if(failure is not null){stage=failure.Stage;throw failure.Error;}
                stage=SteamOperationStage.OwnershipComplete;
                Emit(new {type="result",steamID=decision.SteamID,appID=ownershipAppID,authorized=true,ownershipTicketReceived=true,ticketSHA256=decision.TicketSHA256});
                return 0;
            }
            if(op=="library")
            {
                stage=SteamOperationStage.Library;observedResult=null;
                var licenseList=await licenses.Task.WaitAsync(deadline.Token);
                observedResult=licenseList.Result;
                if(licenseList.Result!=EResult.OK)throw new Exception("license_error");
                var ids=new HashSet<uint>();
                foreach(var chunk in licenseList.LicenseList.Chunk(100))
                {
                    var requests=chunk.Select(l=>new SteamApps.PICSRequest(l.PackageID,l.AccessToken));
                    var packages=await apps.PICSGetProductInfo(Array.Empty<SteamApps.PICSRequest>(),requests).ToTask().WaitAsync(deadline.Token);
                    if(!packages.Complete || packages.Failed || packages.Results is null)throw new Exception("license_error");
                    foreach(var part in packages.Results)foreach(var p in part.Packages.Values)
                        if(p.KeyValues is not null)foreach(var id in p.KeyValues["appids"].Children)if(uint.TryParse(id.Value,out var n))ids.Add(n);
                }
                var games=new List<object>();
                foreach(var chunk in ids.Chunk(100))
                {
                    var access=await apps.PICSGetAccessTokens(chunk,Array.Empty<uint>()).ToTask().WaitAsync(deadline.Token);
                    var requests=chunk.Select(id=>new SteamApps.PICSRequest(id,access.AppTokens.GetValueOrDefault(id)));
                    var infos=await apps.PICSGetProductInfo(requests,Array.Empty<SteamApps.PICSRequest>()).ToTask().WaitAsync(deadline.Token);
                    if(!infos.Complete || infos.Failed || infos.Results is null)throw new Exception("license_error");
                    foreach(var part in infos.Results)foreach(var app in part.Apps.Values)
                    {
                        if(app.KeyValues is null)continue;
                        var common=app.KeyValues["common"];var type=common["type"].Value ?? "";
                        if(!new[]{"game","application","demo"}.Contains(type.ToLowerInvariant()))continue;
                        var platforms=(common["oslist"].Value ?? "").Split(',');var variants=new List<object>();
                        foreach(var platform in new[]{"windows","macos"})
                        {
                            if(!platforms.Contains(platform))continue;
                            var normalized=platform=="macos" ? "macOS":"windows";
                            variants.Add(new {id=normalized,platform=normalized,architecture="unknown",installed=false,arguments=Array.Empty<string>(),verification="Steam platform metadata; inspect local binary to confirm Apple Silicon"});
                        }
                        var launch=app.KeyValues["config"]["launch"].Children.Select(k=>new {executable=k["executable"].Value,arguments=k["arguments"].Value,workingdir=k["workingdir"].Value,@type=k["type"].Value,description=k["description"].Value,oslist=k["config"]["oslist"].Value,osarch=k["config"]["osarch"].Value}).ToArray();
                        games.Add(new {id="steam:"+app.ID,store="steam",storeID=app.ID.ToString(),title=common["name"].Value ?? app.ID.ToString(),artworkURL=$"https://cdn.cloudflare.steamstatic.com/steam/apps/{app.ID}/library_600x900.jpg",variants,engine="automatic",saveRules=Array.Empty<object>(),metadata=new {launch}});
                    }
                    Emit(new {type="progress",phase="library",completed=games.Count});
                }
                Emit(new {type="result",games,steamID=client.SteamID?.ConvertToUInt64().ToString()});
            }
            else if(op=="launch_info")
            {
                stage=SteamOperationStage.LaunchInfo;observedResult=null;
                var options=root.GetProperty("options");var id=Str(options,"gameID");
                if(!uint.TryParse(id,out _))throw new Exception("invalid_game_id");
                Emit(new {type="result",environment=new Dictionary<string,string>{{"SteamAppId",id},{"SteamGameId",id}},arguments=Array.Empty<string>(),requiresSteamClient=true,note="DRM-free games may run directly. Steamworks/DRM games need a genuine compatible Steam client; this bridge does not emulate or bypass it."});
            }
            else throw new Exception("unsupported_operation");
            user.LogOff();deadline.Cancel();client.Disconnect();await pump;return 0;
        }
        catch(Exception error){Emit(SteamSafeFailure.Create(error,stage,observedResult,ownershipFacts));return 1;}
    }
}

// Pure validation/decision helpers are shared with an offline test entry point.
// Only the production path above obtains callback values from SteamApps itself.
static class GameOwnershipPreflight
{
    internal readonly record struct Decision(bool Authorized,string? SteamID,string? TicketSHA256);
    internal static uint AppID(JsonElement request)
    {
        if(request.ValueKind!=JsonValueKind.Object||!request.TryGetProperty("options",out var options)||
            options.ValueKind!=JsonValueKind.Object||!options.TryGetProperty("gameID",out var value))throw new Exception("invalid_game_id");
        uint id=0;
        bool valid=value.ValueKind==JsonValueKind.String
            ? uint.TryParse(value.GetString(),NumberStyles.None,CultureInfo.InvariantCulture,out id)
            : value.ValueKind==JsonValueKind.Number&&value.TryGetUInt32(out id);
        if(!valid||id==0)throw new Exception("invalid_game_id");
        return id;
    }
    internal static Decision Decide(uint requested,EResult result,uint returned,byte[]? ticket,ulong? steamID)
    {
        if(requested==0||result!=EResult.OK||returned!=requested||ticket is not {Length:>0}||steamID is null or 0)
            return new(false,null,null);
        return new(true,steamID.Value.ToString(CultureInfo.InvariantCulture),Convert.ToHexString(SHA256.HashData(ticket)).ToLowerInvariant());
    }
}

// SteamKit's SteamUser.LogOnDetails.ShouldRememberPassword documentation requires
// true for an AuthSessionDetails.IsPersistentSession=true access-token session.
// This controls the Steam login protocol; this helper writes no password file.
static class SteamLoginPolicy
{
    internal static SteamUser.LogOnDetails CreateLogOnDetails(string name,string token) =>
        new() { Username=name,AccessToken=token,ShouldRememberPassword=true };
}

enum SteamOperationStage
{
    Request,Connecting,QRAuthentication,LogOn,OwnershipTicket,Library,LaunchInfo,
    OwnershipResponse,OwnershipDecision,OwnershipClearTicket,OwnershipLogOff,
    OwnershipCancel,OwnershipDisconnect,OwnershipPump,OwnershipComplete
}
sealed class SteamOwnershipFacts
{
    internal bool ResponseReceived;
    internal bool? AppMatched,TicketNonEmpty,SteamIDPresent,DecisionAuthorized;
    internal SteamOperationStage? CleanupFailureStage;
    internal string? CleanupExceptionKind;
    internal void Observe(uint requested,uint returned,byte[]? ticket,ulong? steamID)
    {
        AppMatched=requested==returned;TicketNonEmpty=ticket is {Length:>0};SteamIDPresent=steamID is not null and not 0;
    }
}
sealed record SteamOwnershipFailure(Exception Error,SteamOperationStage Stage);
static class SteamOwnershipCleanup
{
    internal static readonly SteamOperationStage[] Stages={SteamOperationStage.OwnershipClearTicket,
        SteamOperationStage.OwnershipLogOff,SteamOperationStage.OwnershipCancel,
        SteamOperationStage.OwnershipDisconnect,SteamOperationStage.OwnershipPump};
    internal static async Task<SteamOwnershipFailure?> Run(Func<SteamOperationStage,Task> cleanup,SteamOwnershipFacts facts)
    {
        SteamOwnershipFailure? first=null;
        foreach(var stage in Stages)
        {
            try{await cleanup(stage);}
            catch(Exception error)
            {
                first??=new(error,stage);
                facts.CleanupFailureStage??=stage;
                facts.CleanupExceptionKind??=SteamSafeFailure.ExceptionKind(error);
            }
        }
        return first;
    }
}
static class SteamSafeFailure
{
    internal sealed record Response(string type,string code,string message,string stage,string? steamResult,
        string exceptionKind,bool? ownershipResponseReceived,bool? ownershipAppMatched,bool? ownershipTicketNonEmpty,
        bool? ownershipSteamIDPresent,bool? ownershipDecisionAuthorized,string? cleanupFailureStage,string? cleanupExceptionKind);
    private static readonly HashSet<string> AllowedResults=new(StringComparer.Ordinal)
    {
        "OK","Fail","NoConnection","InvalidPassword","LoggedInElsewhere","InvalidProtocolVer","InvalidParam",
        "AccessDenied","Timeout","AccountNotFound","InvalidSteamID","ServiceUnavailable","NotLoggedOn","Pending",
        "InsufficientPrivilege","LimitExceeded","Revoked","Expired","DuplicateRequest","LogonSessionReplaced",
        "ConnectFailed","HandshakeFailed","IOFailure","RemoteDisconnect","AccountDisabled","TryAnotherCM",
        "AlreadyLoggedInElsewhere","Suspended","Cancelled","AccountLogonDenied","InvalidLoginAuthCode",
        "AccountLogonDeniedNoMail","ExpiredLoginAuthCode","AccountLockedDown","AccountLogonDeniedVerifiedEmailRequired",
        "RateLimitExceeded","AccountLoginDeniedNeedTwoFactor","AccountLoginDeniedThrottle","TwoFactorCodeMismatch"
    };
    internal static string StageName(SteamOperationStage value) => value switch
    {
        SteamOperationStage.Connecting=>"connecting",SteamOperationStage.QRAuthentication=>"qr_authentication",
        SteamOperationStage.LogOn=>"logon",SteamOperationStage.OwnershipTicket=>"ownership_ticket",
        SteamOperationStage.Library=>"library",SteamOperationStage.LaunchInfo=>"launch_info",
        SteamOperationStage.OwnershipResponse=>"ownership_response",SteamOperationStage.OwnershipDecision=>"ownership_decision",
        SteamOperationStage.OwnershipClearTicket=>"ownership_clear_ticket",SteamOperationStage.OwnershipLogOff=>"ownership_logoff",
        SteamOperationStage.OwnershipCancel=>"ownership_cancel",SteamOperationStage.OwnershipDisconnect=>"ownership_disconnect",
        SteamOperationStage.OwnershipPump=>"ownership_pump",SteamOperationStage.OwnershipComplete=>"ownership_complete",_=>"request"
    };
    internal static string? ResultName(EResult? value)
    {
        if(value is null)return null;
        string? name=Enum.GetName(value.Value);
        return name!=null&&AllowedResults.Contains(name)?name:"Unknown";
    }
    internal static string ExceptionKind(Exception error) => error switch
    {
        AuthenticationException=>"AuthenticationException",OperationCanceledException=>"OperationCanceledException",
        TimeoutException=>"TimeoutException",DllNotFoundException=>"DllNotFoundException",
        EntryPointNotFoundException=>"EntryPointNotFoundException",BadImageFormatException=>"BadImageFormatException",
        TypeInitializationException=>"TypeInitializationException",CryptographicException=>"CryptographicException",
        IOException=>"IOException",ObjectDisposedException=>"ObjectDisposedException",
        InvalidOperationException=>"InvalidOperationException",ArgumentException=>"ArgumentException",
        NullReferenceException=>"NullReferenceException",AggregateException=>"AggregateException",
        _=>error.GetType()==typeof(Exception)?"Exception":"Unknown"
    };
    internal static Response Create(Exception error,SteamOperationStage stage,EResult? result,SteamOwnershipFacts? facts=null)
    {
        if(result is null && error is AuthenticationException authenticationError)
            result=authenticationError.Result;
        string code=error is OperationCanceledException?"timeout":error.Message switch
        {
            "authentication_required"=>"authentication_required","invalid_request"=>"invalid_request",
            "unsupported_operation"=>"unsupported_operation","license_error"=>"license_error",
            "invalid_game_id"=>"invalid_game_id","disconnected"=>"disconnected",
            "not_authorized"=>"not_authorized","steam_login_failed"=>"steam_login_failed",_=>"steam_error"
        };
        return new("error",code,code=="timeout"?"Steam operation timed out or was cancelled":"Steam operation failed; no credentials were logged",
            StageName(stage),ResultName(result),ExceptionKind(error),facts?.ResponseReceived,facts?.AppMatched,
            facts?.TicketNonEmpty,facts?.SteamIDPresent,facts?.DecisionAuthorized,
            facts?.CleanupFailureStage is { } cleanupStage?StageName(cleanupStage):null,facts?.CleanupExceptionKind);
    }
}
