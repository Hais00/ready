// SPDX-License-Identifier: GPL-3.0-only
using System.Text.Json;
using SteamKit2;
using SteamKit2.Authentication;

// Compiled with the production service and actual SteamKit assembly. This fake
// never instantiates SteamClient, authenticates an account, or opens a socket.
static class PersistentSteamServiceChecks
{
    const string Profile="00000000-0000-4000-8000-000000000001",Generation="00000000-0000-4000-8000-000000000002";
    const string Secret="fixture_private_refresh_never_diagnostic",Password="fixture_private_password",Code="A1B2C";
    static readonly Dictionary<string,bool> checks=new();
    static void Check(bool value,string name){if(!value)throw new Exception(name);checks[name]=true;}
    static async Task Until(Func<bool> condition)
    {using var budget=new CancellationTokenSource(TimeSpan.FromSeconds(5));while(!condition())await Task.Delay(2,budget.Token);}
    sealed class Output:StringWriter
    {
        readonly object sync=new();
        public override void WriteLine(string? value){lock(sync)base.WriteLine(value);}
        internal JsonElement[] Events {get{lock(sync)return ToString().Split('\n',StringSplitOptions.RemoveEmptyEntries).Select(value=>JsonDocument.Parse(value).RootElement.Clone()).ToArray();}}
    }
    sealed class Fake:ISteamServiceTransport
    {
        public event Action<SteamTransportNotice>? Notice;
        internal int Connects,Auths,Stops,Logons,OwnershipCalls;
        internal bool FailConnect,FailStop,WaitAuth,WaitOwnership,IgnoreOwnershipCancellation,WaitLogin,IgnoreLoginCancellation;
        internal EResult LoginResult=EResult.OK;
        internal EResult OwnershipResult=EResult.OK;
        internal uint? ReturnedApp;
        internal bool TicketPresent=true;
        internal ulong? OwnershipSteamID=76561198000000001UL;
        internal Exception? OwnershipException;
        internal string LastUsername="",LastToken="",Presence="Online";
        internal string DisplayName="Fixture persona";
        internal SteamServiceMutation Mutation=new(true,true,EResult.OK,"server_acknowledged");
        internal string? LastSocialAction;internal ulong LastSocialTarget;
        internal uint[] Activity=Array.Empty<uint>();
        internal TaskCompletionSource<bool> AuthGate=new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal TaskCompletionSource<bool> OwnershipGate=new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal TaskCompletionSource<bool> LoginGate=new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Task ConnectAsync(CancellationToken cancel){Interlocked.Increment(ref Connects);cancel.ThrowIfCancellationRequested();return FailConnect?Task.FromException(new IOException(Secret)):Task.CompletedTask;}
        public async Task<SteamServiceCredentials> AuthenticateAsync(string method,string username,string password,Action<string> qr,IAuthenticator guard,CancellationToken cancel)
        {
            Interlocked.Increment(ref Auths);
            if(method=="qr"){qr("https://s.team/q/one");qr("https://s.team/q/two");}
            else {if(username!="fixture_account"||password!=Password)throw new ArgumentException();if(await guard.GetDeviceCodeAsync(false)!=Code)throw new ArgumentException();}
            if(WaitAuth)await AuthGate.Task.WaitAsync(cancel);
            cancel.ThrowIfCancellationRequested();return new("fixture_account",Secret);
        }
        public async Task<EResult> LogOnAsync(SteamServiceCredentials credentials,CancellationToken cancel)
        {
            Interlocked.Increment(ref Logons);LastUsername=credentials.Username;LastToken=credentials.RefreshToken;
            if(WaitLogin){if(IgnoreLoginCancellation)await LoginGate.Task;else await LoginGate.Task.WaitAsync(cancel);}
            if(!IgnoreLoginCancellation)cancel.ThrowIfCancellationRequested();return LoginResult;
        }
        public Task StopAsync(){Interlocked.Increment(ref Stops);return FailStop?Task.FromException(new IOException(Secret)):Task.CompletedTask;}
        public SteamServiceAccount Account(string username)=>new("76561198000000001",username,DisplayName,Presence);
        public IReadOnlyList<SteamServiceFriend> Friends()=>new[]{
            new SteamServiceFriend("76561198000000002","Friend fixture","Away","480","Fixture game","Friend"),
            new SteamServiceFriend("76561198000000003","Blocked fixture","Offline",null,null,"Blocked"),
            new SteamServiceFriend("76561198000000004","Incoming fixture","Online",null,null,"RequestRecipient"),
            new SteamServiceFriend("76561198000000005","Outgoing fixture","Offline",null,null,"RequestInitiator")};
        public void SetPresence(EPersonaState presence)=>Presence=presence.ToString();
        public void SetActivity(IReadOnlyCollection<uint> apps)=>Activity=apps.ToArray();
        public Task<SteamServiceMutation> SetPersonaNameAsync(string displayName,CancellationToken cancel)
        {cancel.ThrowIfCancellationRequested();LastSocialAction="set_persona_name";if(Mutation.ServerAcknowledged&&Mutation.Result==EResult.OK)DisplayName=displayName;return Task.FromResult(Mutation);}
        public Task<SteamServiceMutation> FriendActionAsync(string operation,ulong target,CancellationToken cancel)
        {cancel.ThrowIfCancellationRequested();LastSocialAction=operation;LastSocialTarget=target;return Task.FromResult(Mutation);}
        public async Task<SteamServiceOwnership> AuthorizeAsync(uint app,CancellationToken cancel)
        {
            Interlocked.Increment(ref OwnershipCalls);
            if(WaitOwnership){if(IgnoreOwnershipCancellation)await OwnershipGate.Task;else await OwnershipGate.Task.WaitAsync(cancel);}
            if(OwnershipException is {} failure)throw failure;
            return SteamServiceOwnership.Observe(app,OwnershipResult,ReturnedApp??app,TicketPresent?new byte[]{1,2,3}:Array.Empty<byte>(),OwnershipSteamID);
        }
        public Task LibraryAsync(Action<object[]> page,CancellationToken cancel)
        {cancel.ThrowIfCancellationRequested();page(new object[]{new{id="steam:480",storeID="480",variants=Array.Empty<object>()}});return Task.CompletedTask;}
        internal void Drop()=>Notice?.Invoke(new("disconnected"));
        internal void LogOff(EResult result)=>Notice?.Invoke(new("logged_off",result));
        internal void ChangeFriends()=>Notice?.Invoke(new("friends"));
        public ValueTask DisposeAsync()=>ValueTask.CompletedTask;
    }
    sealed class Session:IAsyncDisposable
    {
        internal readonly Output Output=new();internal readonly Fake Transport=new();internal readonly PersistentSteamService Service;
        internal Session(Func<TimeSpan,CancellationToken,Task>? delay=null,TimeSpan? budget=null)
        {Service=new(Transport,Output,delay,budget,TimeSpan.FromMilliseconds(20));}
        internal string Send(string operation,object? options=null,object? credentials=null)
        {
            string id=Guid.NewGuid().ToString("D");
            Service.Accept(JsonSerializer.Serialize(new{id,profileID=Profile,profileGeneration=Generation,operation,options=options??new{},credentials=credentials??new{}}));return id;
        }
        internal string SendFlat(string operation,object fields)
        {
            string id=Guid.NewGuid().ToString("D").ToUpperInvariant();
            var values=JsonSerializer.Deserialize<Dictionary<string,object?>>(JsonSerializer.Serialize(fields))!;
            values["id"]=id;values["profileID"]=Profile.ToUpperInvariant();values["profileGeneration"]=Generation.ToUpperInvariant();values["operation"]=operation;
            Service.Accept(JsonSerializer.Serialize(values));return id;
        }
        internal Task Done(string id)=>Until(()=>Output.Events.Any(e=>S(e,"id")==id&&S(e,"type") is "result" or "error"&&!B(e,"partial")));
        internal JsonElement Terminal(string id)=>Output.Events.Last(e=>S(e,"id")==id&&S(e,"type") is "result" or "error");
        internal Task Connect()=>Done(Send("connect",credentials:new{username="fixture_account",refresh_token=Secret}));
        public ValueTask DisposeAsync()=>Service.DisposeAsync();
    }
    static string? S(JsonElement e,string key)=>e.TryGetProperty(key,out var value)&&value.ValueKind==JsonValueKind.String?value.GetString():null;
    static bool B(JsonElement e,string key)=>e.TryGetProperty(key,out var value)&&value.ValueKind==JsonValueKind.True;
    static async Task<int> Main()
    {
        await using(var s=new Session())
        {
            string snap=s.Send("snapshot");await s.Done(snap);
            Check(S(s.Terminal(snap),"state")=="offline"&&s.Transport.Connects==0,"offline-snapshot-does-not-connect");
            await s.Connect();Check(s.Transport.Logons==1&&s.Transport.Auths==0&&s.Transport.LastToken==Secret,"saved-refresh-connect-no-QR");
            string friends=s.Send("friends");await s.Done(friends);
            Check(s.Terminal(friends).GetProperty("friends")[0].GetProperty("gameID").GetString()=="480","friends-presence-game-snapshot");
            s.Transport.ChangeFriends();Check(s.Output.Events.Any(e=>S(e,"type")=="friends"&&B(e,"changed")),"unsolicited-friends-update");
            string presence=s.SendFlat("set_presence",new{presence="Away"});await s.Done(presence);Check(s.Transport.Presence=="Away","presence-control-genuine-transport-boundary");
            string own=s.SendFlat("authorize_game",new{gameID="480"});await s.Done(own);
            Check(S(s.Terminal(own),"id")==own,"flattened-Swift-envelope-preserves-uppercase-request-ID");
            Check(B(s.Terminal(own),"authorized")&&B(s.Terminal(own),"ownershipTicketReceived")&&!B(s.Terminal(own),"backendSessionReady"),"ownership-no-gamehost-readiness-claim");
            string deniedActivity=s.Send("set_activity",new{gameID="481",running=true});await s.Done(deniedActivity);
            Check(S(s.Terminal(deniedActivity),"code")=="not_authorized","activity-requires-current-session-owned-app");
            string activity=s.Send("set_activity",new{gameID="480",running=true});await s.Done(activity);
            Check(s.Transport.Activity.SequenceEqual(new uint[]{480}),"activity-after-caller-launch-success-boundary");
            string stopped=s.Send("set_activity",new{gameID="480",running=false});await s.Done(stopped);
            Check(s.Transport.Activity.Length==0,"stopped-game-clears-Steam-activity");
            string library=s.Send("library");await s.Done(library);
            Check(s.Terminal(library).GetProperty("games")[0].GetProperty("storeID").GetString()=="480"&&s.Terminal(library).GetProperty("gameCount").GetInt32()==1,"library-compatible-games-terminal-result");
            string paged=s.Send("library",new{paged=true});await s.Done(paged);
            var page=s.Output.Events.Single(e=>S(e,"id")==paged&&S(e,"type")=="library_page");
            Check(page.GetProperty("pageIndex").GetInt32()==0&&page.GetProperty("games")[0].GetProperty("storeID").GetString()=="480"&&s.Terminal(paged).GetProperty("gameCount").GetInt32()==1&&s.Terminal(paged).GetProperty("pageCount").GetInt32()==1&&!s.Terminal(paged).TryGetProperty("games",out _),"paged-library-nonterminal-page-terminal-counts");
            string invalidPaged=s.Send("library",new{paged="true"});await s.Done(invalidPaged);Check(S(s.Terminal(invalidPaged),"code")=="invalid_request","paged-library-requires-strict-bool");
            await Until(()=>s.Output.Events.Any(e=>S(e,"type")=="heartbeat"));
            var events=s.Output.Events;Check(events.Select(e=>e.GetProperty("sequence").GetInt64()).SequenceEqual(Enumerable.Range(1,events.Length).Select(n=>(long)n))&&events.All(e=>S(e,"profileID")==Profile&&S(e,"profileGeneration")==Generation),"all-events-monotonic-sequence-profile-generation");
            Check(events.All(e=>!e.TryGetProperty("credentials",out _))&&!s.Output.ToString().Contains(Secret),"saved-refresh-not-echoed-or-diagnostic");
            string offline=s.Send("offline");await s.Done(offline);int count=s.Transport.Connects;s.Transport.Drop();await Task.Delay(30);
            Check(s.Transport.Connects==count&&S(s.Terminal(snap),"type")=="result","manual-offline-prevents-reconnect");
            string reconnect=s.Send("reconnect");await s.Done(reconnect);Check(s.Transport.Connects==count+1,"explicit-reconnect-reuses-private-credentials");
        }
        await using(var s=new Session())
        {
            string id=s.Send("authenticate",new{method="qr"});await s.Done(id);
            Check(s.Output.Events.Count(e=>S(e,"id")==id&&S(e,"type")=="qr")==2,"QR-rotations-share-request-ID");
            var credential=s.Output.Events.Single(e=>S(e,"type")=="credentials");
            Check(S(credential,"id")==id&&credential.GetProperty("credentials").GetProperty("refresh_token").GetString()==Secret&&s.Output.Events.Where(e=>S(e,"type")!="credentials").All(e=>!e.ToString().Contains(Secret)),"new-refresh-only-in-private-credentials-event");
        }
        await using(var s=new Session())
        {
            string id=s.SendFlat("authenticate",new{method="password",username="fixture_account",password=Password});
            await Until(()=>s.Output.Events.Any(e=>S(e,"type")=="guard"));
            var guard=s.Output.Events.First(e=>S(e,"type")=="guard");string challenge=S(guard,"challengeID")!;
            string wrong=s.Send("guard_code",new{challengeID=Guid.NewGuid().ToString("D"),code=Code});await s.Done(wrong);
            Check(S(s.Terminal(wrong),"code")=="invalid_guard_response","Guard-response-bound-to-active-challenge");
            string reply=s.Send("guard_code",new{challengeID=challenge,code=Code});await s.Done(reply);await s.Done(id);
            Check(s.Transport.Logons==1&&!s.Output.ToString().Contains(Password)&&!s.Output.ToString().Contains(Code),"password-Guard-only-anonymous-input-no-echo");
            string replay=s.Send("guard_code",new{challengeID=challenge,code=Code});await s.Done(replay);
            Check(S(s.Terminal(replay),"code")=="invalid_guard_response","Guard-challenge-single-use");
        }
        await using(var s=new Session())
        {
            s.Transport.WaitAuth=true;string id=s.Send("authenticate",new{method="qr"});await Until(()=>s.Transport.Auths==1);
            string cancel=s.Send("cancel",new{requestID=id});await s.Done(cancel);await s.Done(id);
            s.Transport.AuthGate.TrySetResult(true);await Task.Delay(20);
            Check(S(s.Terminal(id),"code")=="cancelled"&&!s.Output.Events.Any(e=>S(e,"type")=="credentials")&&s.Transport.Logons==0,"cancelled-auth-cannot-save-late-credentials");
        }
        await using(var s=new Session((_,cancel)=>Task.Delay(1,cancel)))
        {
            await s.Connect();s.Transport.Drop();await Until(()=>s.Transport.Connects==2&&s.Output.Events.Any(e=>S(e,"reason")=="reconnected"));
            Check(s.Transport.Auths==0&&s.Transport.Logons==2&&!s.Output.Events.Any(e=>B(e,"invalidateCredentials")),"network-drop-reconnects-without-new-auth-or-vault-invalidation");
        }
        await using(var s=new Session())
        {
            s.Transport.FailConnect=true;string failed=s.Send("connect",credentials:new{username="fixture_account",refresh_token=Secret});await s.Done(failed);
            s.Transport.FailConnect=false;string retry=s.Send("reconnect");await s.Done(retry);
            Check(S(s.Terminal(retry),"type")=="result"&&s.Transport.LastToken==Secret&&s.Transport.Auths==0,"initial-network-failure-preserves-saved-refresh-for-explicit-retry");
        }
        await using(var s=new Session())
        {
            s.Transport.LoginResult=EResult.NoConnection;string failed=s.Send("authenticate",new{method="qr"});await s.Done(failed);
            Check(s.Output.Events.Count(e=>S(e,"type")=="credentials")==1&&!s.Output.Events.Any(e=>B(e,"invalidateCredentials")),"genuine-QR-refresh-preserved-before-transient-CM-logon-failure");
            s.Transport.LoginResult=EResult.OK;string retry=s.Send("reconnect");await s.Done(retry);
            Check(s.Transport.Auths==1&&S(s.Terminal(retry),"type")=="result","retry-CM-logon-without-second-QR");
        }
        var attempts=new List<double>();
        await using(var s=new Session((duration,cancel)=>{lock(attempts)attempts.Add(duration.TotalSeconds);cancel.ThrowIfCancellationRequested();return Task.CompletedTask;}))
        {
            await s.Connect();s.Transport.FailConnect=true;s.Transport.Drop();await Until(()=>s.Output.Events.Any(e=>S(e,"reason")=="reconnect_exhausted"));
            Check(attempts.SequenceEqual(new double[]{1,2,4,8,16,30})&&s.Transport.Connects==7,"network-reconnect-exponential-finite-six-attempts");
        }
        foreach(var result in new[]{EResult.LogonSessionReplaced,EResult.LoggedInElsewhere,EResult.Revoked,EResult.Expired,
            EResult.InvalidPassword,EResult.AccountDisabled,EResult.AccountLockedDown})
        await using(var s=new Session((_,cancel)=>Task.Delay(1,cancel)))
        {
            await s.Connect();int count=s.Transport.Connects;s.Transport.LogOff(result);s.Transport.Drop();await Task.Delay(30);
            Check(s.Transport.Connects==count&&s.Output.Events.Any(e=>S(e,"steamResult")==result.ToString()&&
                e.TryGetProperty("invalidateCredentials",out var invalidate)&&invalidate.ValueKind==JsonValueKind.False),"remote-logoff-blocks-reconnect-and-preserves-refresh-"+result);
            string snapshot=s.Send("snapshot");await s.Done(snapshot);
            Check(S(s.Terminal(snapshot),"state")== (result is EResult.AccountDisabled or EResult.AccountLockedDown?"authorization_required":"logged_out")&&
                S(s.Terminal(snapshot),"connectionResultContext")=="logged_off","loggedoff-session-state-and-context-"+result);
            string expectedReason=result switch
            {
                EResult.Expired=>"session_expired",EResult.Revoked=>"server_session_revoked",EResult.InvalidPassword=>"server_session_rejected",
                EResult.AccountDisabled=>"account_disabled",EResult.AccountLockedDown=>"account_locked",
                EResult.LogonSessionReplaced=>"session_replaced",_=>"logged_in_elsewhere"
            };
            Check(S(s.Terminal(snapshot),"reason")==expectedReason&&S(s.Terminal(snapshot),"steamResult")==result.ToString(),"loggedoff-reason-describes-session-without-claiming-refresh-expiry-"+result);
            string denied=s.Send("authorize_game",new{gameID="480"});await s.Done(denied);
            Check(S(s.Terminal(denied),"code")=="not_online"&&s.Transport.OwnershipCalls==0,"loggedoff-preserved-refresh-never-bypasses-ownership-gate-"+result);
            string retry=s.Send("reconnect");await s.Done(retry);
            Check(S(s.Terminal(retry),"type")=="result"&&s.Transport.LastToken==Secret&&s.Transport.Auths==0,"loggedoff-explicit-reconnect-reuses-preserved-refresh-"+result);
        }
        foreach(var result in new[]{EResult.Expired,EResult.Revoked,EResult.InvalidPassword,EResult.AccountDisabled,EResult.AccountLockedDown})
        await using(var s=new Session())
        {
            await s.Connect();s.Transport.LogOff(result);await Until(()=>s.Transport.Stops>=2);
            Check(!s.Output.Events.Any(e=>B(e,"invalidateCredentials")),"loggedoff-alone-is-not-proof-refresh-rejected-"+result);
            s.Transport.LoginResult=result;string reconnect=s.Send("reconnect");await s.Done(reconnect);
            Check(S(s.Terminal(reconnect),"code")=="steam_login_failed"&&S(s.Terminal(reconnect),"steamResult")==result.ToString()&&
                s.Output.Events.Any(e=>S(e,"connectionResultContext")=="logon_response"&&B(e,"invalidateCredentials")),
                "subsequent-real-logon-rejection-invalidates-refresh-"+result);
            string snapshot=s.Send("snapshot");await s.Done(snapshot);
            Check(S(s.Terminal(snapshot),"state")=="authorization_required"&&S(s.Terminal(snapshot),"connectionResultContext")=="logon_response"&&
                S(s.Terminal(snapshot),"steamResult")==result.ToString(),"definitive-refresh-rejection-context-survives-snapshot-"+result);
            string again=s.Send("reconnect");await s.Done(again);
            Check(S(s.Terminal(again),"code")=="authentication_required"&&s.Transport.Auths==0,"definitively-rejected-refresh-never-reused-or-replaced-by-implicit-QR-"+result);
        }
        await using(var s=new Session())
        {
            await s.Connect();s.Transport.WaitOwnership=true;s.Transport.IgnoreOwnershipCancellation=true;
            string ownership=s.Send("authorize_game",new{gameID="480"});await Until(()=>s.Transport.OwnershipCalls==1);
            s.Transport.LogOff(EResult.Expired);s.Transport.OwnershipGate.TrySetResult(true);await s.Done(ownership);
            Check(S(s.Terminal(ownership),"code")=="disconnected"&&!B(s.Terminal(ownership),"authorized")&&
                !s.Output.Events.Any(e=>B(e,"invalidateCredentials")),"session-expiry-stops-inflight-ownership-without-refresh-erasure");
            string activity=s.Send("set_activity",new{gameID="480",running=true});await s.Done(activity);
            Check(S(s.Terminal(activity),"code")=="not_online"&&s.Transport.Activity.Length==0,"session-expiry-clears-app-authority-and-prevents-activity");
        }
        await using(var s=new Session())
        {
            await s.Connect();string logout=s.Send("logout",new{forgetCredentials=true});await s.Done(logout);
            string retry=s.Send("reconnect");await s.Done(retry);
            Check(B(s.Terminal(logout),"invalidateCredentials")&&S(s.Terminal(retry),"code")=="authentication_required","explicit-forget-logout-closes-and-invalidates");
        }
        await using(var s=new Session())
        {
            await s.Connect();
            string rename=s.SendFlat("set_persona_name",new{displayName="Fixture public name"});await s.Done(rename);
            Check(B(s.Terminal(rename),"serverAcknowledged")&&s.Terminal(rename).GetProperty("account").GetProperty("displayName").GetString()=="Fixture public name"&&s.Transport.LastUsername=="fixture_account","public-display-name-change-keeps-login-account-immutable");
            foreach(var name in new[]{"","  ","bad\nname",new string('x',129)})
            {string invalid=s.SendFlat("set_persona_name",new{displayName=name});await s.Done(invalid);Check(S(s.Terminal(invalid),"code")=="invalid_request","invalid-public-name-"+name.Length+"-"+name.Contains('\n'));}
            foreach(var operation in new[]{"add_friend","remove_friend","block_friend","unblock_friend"})
            {
                string action=s.SendFlat(operation,new{steamID="76561198000000002"});await s.Done(action);
                Check(B(s.Terminal(action),"serverAcknowledged")&&s.Transport.LastSocialAction==operation&&s.Transport.LastSocialTarget==76561198000000002UL,"explicit-social-command-"+operation);
            }
            s.Transport.Mutation=new(false,true,null,"awaiting_server_confirmation");string pending=s.SendFlat("add_friend",new{steamID="76561198000000003"});await s.Done(pending);
            Check(!B(s.Terminal(pending),"serverAcknowledged")&&B(s.Terminal(pending),"pending")&&!s.Terminal(pending).TryGetProperty("friendshipAccepted",out _),"unconfirmed-social-request-remains-pending-not-friendship-accepted");
            s.Transport.Mutation=new(true,true,EResult.AccessDenied,"server_rejected");string rejected=s.SendFlat("block_friend",new{steamID="76561198000000003"});await s.Done(rejected);
            Check(S(s.Terminal(rejected),"code")=="social_request_failed"&&S(s.Terminal(rejected),"steamResult")=="AccessDenied","genuine-social-server-rejection-not-success");
            foreach(string target in new[]{"76561198000000001","0","76561197960265728","+76561198000000002"," 76561198000000002","18446744073709551616","not-an-id","103582791429521412"})
            {string invalid=s.SendFlat("add_friend",new{steamID=target});await s.Done(invalid);Check(S(s.Terminal(invalid),"code")=="invalid_request","reject-invalid-or-self-social-target-"+target);}
            string snapshot=s.Send("snapshot");await s.Done(snapshot);var relationships=s.Terminal(snapshot).GetProperty("friends").EnumerateArray().Select(friend=>S(friend,"relationship")).ToArray();
            Check(relationships.Contains("Blocked")&&relationships.Contains("RequestRecipient")&&relationships.Contains("RequestInitiator"),"snapshot-retains-blocked-incoming-and-outgoing-relations");
        }
        {
            var confirmation=new SteamSocialConfirmation();var persona=confirmation.Begin("set_persona_name","New name")!;
            confirmation.Persona("Old name",EResult.OK);Check(!persona.Completion.Task.IsCompleted,"rename-unrelated-persona-callback-cannot-confirm");
            var waiting=await SteamSocialConfirmation.Wait(persona,default,TimeSpan.FromMilliseconds(1));
            Check(!waiting.ServerAcknowledged&&waiting.RequestSent&&waiting.Status=="awaiting_server_confirmation"&&confirmation.Begin("set_persona_name","Another name")==null,"rename-timeout-retains-pending-owner-no-resend");
            confirmation.Persona("New name",EResult.OK);Check((await persona.Completion.Task).ServerAcknowledged,"rename-matching-server-callback-confirms");
            var added=confirmation.Begin("add_friend","76561198000000002")!;
            confirmation.Added(76561198000000003UL,EResult.OK);Check(!added.Completion.Task.IsCompleted,"add-friend-callback-target-must-match");
            confirmation.Added(76561198000000002UL,EResult.AccessDenied);Check((await added.Completion.Task).Result==EResult.AccessDenied,"add-friend-matched-denial-preserved");
            var removed=confirmation.Begin("remove_friend","76561198000000002")!;
            confirmation.Relationships(true,new Dictionary<ulong,EFriendRelationship>{{76561198000000003UL,EFriendRelationship.None}});Check(!removed.Completion.Task.IsCompleted,"incremental-unrelated-removal-cannot-confirm");
            confirmation.Relationships(true,new Dictionary<ulong,EFriendRelationship>{{76561198000000002UL,EFriendRelationship.None}});Check((await removed.Completion.Task).Status=="relationship_removed","remove-friend-matching-relationship-callback-confirms");
            var full=confirmation.Begin("remove_friend","76561198000000002")!;confirmation.Relationships(false,new Dictionary<ulong,EFriendRelationship>());Check((await full.Completion.Task).ServerAcknowledged,"complete-friends-list-absence-confirms-removal");
            var old=confirmation.Begin("block_friend","76561198000000002")!;confirmation.Reset();var current=confirmation.Begin("unblock_friend","76561198000000002")!;
            confirmation.Complete(old,EResult.OK,"server_acknowledged");Check(!current.Completion.Task.IsCompleted,"old-job-cannot-complete-new-epoch-social-request");
            confirmation.Complete(current,EResult.OK,"server_acknowledged");Check((await current.Completion.Task).ServerAcknowledged,"block-unblock-complete-only-exact-job-owner");
            var failed=confirmation.Begin("block_friend","76561198000000003")!;confirmation.Failed(failed);bool noAck=false;
            try{await failed.Completion.Task;}catch(IOException){noAck=true;}
            Check(noAck,"failed-SDK-job-is-not-a-server-acknowledgement");
            var cancelled=confirmation.Begin("add_friend","76561198000000004")!;using var cancel=new CancellationTokenSource();cancel.Cancel();bool cancelledWait=false;
            try{await SteamSocialConfirmation.Wait(cancelled,cancel.Token);}catch(OperationCanceledException){cancelledWait=true;}
            Check(cancelledWait&&confirmation.Begin("remove_friend","76561198000000004")==null,"cancelled-social-wait-keeps-slot-until-late-callback");confirmation.Reset();
        }
        await using(var s=new Session())
        {
            await s.Connect();s.Transport.WaitOwnership=true;string id=s.Send("authorize_game",new{gameID="480"});await Until(()=>s.Transport.OwnershipCalls==1);
            string offline=s.Send("offline");await s.Done(offline);s.Transport.OwnershipGate.TrySetResult(true);await s.Done(id);
            Check(!B(s.Terminal(id),"authorized"),"offline-epoch-rejects-in-flight-ownership");
        }
        await using(var s=new Session())
        {
            await s.Connect();
            for(int run=0;run<3;run++)
            {
                string id=s.Send("authorize_game",new{gameID="480"});await s.Done(id);
                Check(B(s.Terminal(id),"authorized")&&B(s.Terminal(id),"ownershipTicketReceived"),"same-session-repeat-ownership-"+run);
                string stop=s.Send("set_activity",new{gameID="480",running=false});await s.Done(stop);
            }
            Check(s.Transport.OwnershipCalls==3&&s.Transport.Logons==1&&s.Transport.Auths==0,"repeat-game-shutdown-no-extra-login-or-ownership-cache");
            s.Transport.LogOff(EResult.OK);await Until(()=>s.Output.Events.Any(e=>S(e,"state")=="logged_out"));
            string denied=s.Send("authorize_game",new{gameID="480"});await s.Done(denied);
            Check(S(s.Terminal(denied),"code")=="not_online"&&s.Transport.OwnershipCalls==3,"native-style-logoff-blocks-ownership-without-assuming-license-loss");
            string reconnect=s.Send("reconnect");await s.Done(reconnect);
            string after=s.Send("authorize_game",new{gameID="480"});await s.Done(after);
            Check(B(s.Terminal(after),"authorized")&&s.Transport.Auths==0&&s.Transport.OwnershipCalls==4,"explicit-reconnect-after-native-style-logoff-can-authorize-again");
        }
        foreach(var item in new[]{(EResult.AccessDenied,"not_authorized","not_owned"),
            (EResult.InsufficientPrivilege,"not_authorized","permission_denied"),(EResult.Timeout,"timeout","timeout"),
            (EResult.NoConnection,"network_error","network"),(EResult.ServiceUnavailable,"network_error","network"),
            (EResult.NotLoggedOn,"authentication_required","session_unavailable"),(EResult.Expired,"authentication_required","session_unavailable"),
            (EResult.RateLimitExceeded,"rate_limited","rate_limited"),((EResult)int.MaxValue,"ownership_request_failed","request_failed")})
        {
            await using var s=new Session();await s.Connect();s.Transport.OwnershipResult=item.Item1;s.Transport.TicketPresent=false;
            string id=s.Send("authorize_game",new{gameID="480"});await s.Done(id);var failure=s.Terminal(id);
            Check(S(failure,"type")=="error"&&S(failure,"code")==item.Item2&&S(failure,"ownershipFailure")==item.Item3&&
                B(failure,"ownershipResponseReceived")&&B(failure,"ownershipAppMatched")&&!B(failure,"ownershipTicketNonEmpty")&&
                B(failure,"ownershipSteamIDPresent")&&!B(failure,"ownershipDecisionAuthorized"),"sanitized-ownership-server-result-"+item.Item1);
            Check(S(failure,"steamResult")==SteamSafeFailure.ResultName(item.Item1),"ownership-preserves-safe-EResult-"+item.Item1);
            string activity=s.Send("set_activity",new{gameID="480",running=true});await s.Done(activity);
            Check(S(s.Terminal(activity),"code")=="not_authorized","ownership-failure-never-authorizes-activity-"+item.Item1);
        }
        foreach(string fault in new[]{"wrong_app","empty_ticket","missing_identity"})
        {
            await using var s=new Session();await s.Connect();
            if(fault=="wrong_app")s.Transport.ReturnedApp=481;
            if(fault=="empty_ticket")s.Transport.TicketPresent=false;
            if(fault=="missing_identity")s.Transport.OwnershipSteamID=null;
            string id=s.Send("authorize_game",new{gameID="480"});await s.Done(id);var failure=s.Terminal(id);
            Check(S(failure,"code")=="ownership_invalid_response"&&S(failure,"steamResult")=="OK"&&S(failure,"ownershipFailure")=="invalid_callback"&&
                B(failure,"ownershipAppMatched")== (fault!="wrong_app")&&B(failure,"ownershipTicketNonEmpty")== (fault!="empty_ticket")&&
                B(failure,"ownershipSteamIDPresent")== (fault!="missing_identity")&&!B(failure,"ownershipDecisionAuthorized"),"invalid-ownership-callback-facts-"+fault);
        }
        foreach(var item in new[]{((Exception)new TimeoutException(Secret),"timeout"),
            (new TaskCanceledException(Secret),"timeout"),(new IOException(Secret),"network_error"),
            (new AsyncJobFailedException(Secret),"ownership_request_failed"),(new InvalidOperationException(Secret),"steam_error")})
        {
            await using var s=new Session();await s.Connect();s.Transport.OwnershipException=item.Item1;
            string id=s.Send("authorize_game",new{gameID="480"});await s.Done(id);var failure=s.Terminal(id);
            Check(S(failure,"code")==item.Item2&&!B(failure,"ownershipResponseReceived")&&
                failure.GetProperty("ownershipAppMatched").ValueKind==JsonValueKind.Null&&!failure.ToString().Contains(Secret),"ownership-exception-safe-classification-"+item.Item1.GetType().Name);
        }
        await using(var s=new Session(budget:TimeSpan.FromMilliseconds(100)))
        {
            await s.Connect();s.Transport.WaitOwnership=true;string id=s.Send("authorize_game",new{gameID="480"});await s.Done(id);
            Check(S(s.Terminal(id),"code")=="timeout","ownership-request-budget-is-timeout-not-user-cancellation");
        }
        foreach(bool logoff in new[]{false,true})
        {
            await using var s=new Session();await s.Connect();s.Transport.WaitOwnership=true;s.Transport.IgnoreOwnershipCancellation=true;
            string id=s.Send("authorize_game",new{gameID="480"});await Until(()=>s.Transport.OwnershipCalls==1);
            if(logoff)s.Transport.LogOff(EResult.OK);
            else {string cancel=s.Send("cancel",new{requestID=id});await s.Done(cancel);}
            s.Transport.OwnershipGate.TrySetResult(true);await s.Done(id);await Task.Delay(20);var failure=s.Terminal(id);
            Check(S(failure,"type")=="error"&&S(failure,"code")== (logoff?"disconnected":"cancelled")&&
                B(failure,"ownershipDecisionAuthorized")&&s.Output.Events.Count(e=>S(e,"id")==id&&S(e,"type")is "error"or"result")==1,
                logoff?"logoff-epoch-rejects-late-success-once":"cancel-rejects-late-success-once");
            string text=failure.ToString();
            Check(!text.Contains("76561198000000001")&&!text.Contains("fixture_account")&&!text.Contains(Secret)&&
                !text.Contains("TicketSHA256")&&!failure.TryGetProperty("steamID",out _)&&!failure.TryGetProperty("authorized",out _),
                logoff?"epoch-failure-never-emits-private-decision-metadata":"cancel-failure-never-emits-private-decision-metadata");
        }
        await using(var s=new Session())
        {
            await s.Connect();s.Transport.FailStop=true;s.Transport.LogOff(EResult.Expired);
            await Until(()=>s.Output.Events.Any(e=>S(e,"reason")=="cleanup_failed"));
            string id=s.Send("snapshot");await s.Done(id);var snapshot=s.Terminal(id);
            Check(S(snapshot,"steamResult")=="Expired"&&S(snapshot,"connectionResultContext")=="logged_off"&&
                S(snapshot,"state")=="logged_out"&&S(snapshot,"reason")=="cleanup_failed",
                "snapshot-preserves-loggedoff-result-and-context-after-cleanup-failure");
            Check(s.Output.Events.Where(e=>S(e,"state")=="logged_out").All(e=>S(e,"steamResult")=="Expired"&&
                S(e,"connectionResultContext")=="logged_off"),"all-loggedoff-state-events-include-safe-connection-result");
            Check(!snapshot.ToString().Contains(Secret)&&!snapshot.ToString().Contains("76561198000000001"),"offline-connection-snapshot-does-not-expose-identity-or-secret");
        }
        await using(var s=new Session())
        {
            s.Transport.LoginResult=EResult.Expired;string login=s.Send("connect",credentials:new{username="fixture_account",refresh_token=Secret});await s.Done(login);
            string id=s.Send("snapshot");await s.Done(id);var snapshot=s.Terminal(id);
            Check(S(snapshot,"steamResult")=="Expired"&&S(snapshot,"connectionResultContext")=="logon_response"&&
                S(snapshot,"state")=="authorization_required","snapshot-distinguishes-refresh-logon-rejection-from-loggedoff");
        }
        foreach(bool reconnect in new[]{false,true})
        {
            await using var s=new Session((_,cancel)=>Task.Delay(1,cancel));
            if(reconnect)await s.Connect();
            s.Transport.WaitLogin=true;s.Transport.IgnoreLoginCancellation=true;s.Transport.LoginResult=EResult.Expired;
            string? original=null;
            if(reconnect)s.Transport.Drop();
            else original=s.Send("connect",credentials:new{username="fixture_account",refresh_token=Secret});
            await Until(()=>s.Transport.Logons==(reconnect?2:1));
            string offline=s.Send("offline");await Until(()=>s.Output.Events.Any(e=>S(e,"state")=="offline"&&S(e,"reason")=="manual_offline"));
            s.Transport.LoginGate.TrySetResult(true);await s.Done(offline);if(original is not null)await s.Done(original);
            string id=s.Send("snapshot");await s.Done(id);var snapshot=s.Terminal(id);
            Check(S(snapshot,"state")=="offline"&&S(snapshot,"reason")=="manual_offline"&&!s.Output.Events.Any(e=>B(e,"invalidateCredentials")),
                reconnect?"reconnect-failed-response-after-new-epoch-cannot-invalidate-refresh":"initial-logon-failed-response-after-new-epoch-cannot-invalidate-refresh");
            Check(S(snapshot,"steamResult")== (reconnect?"OK":null)&&S(snapshot,"steamResult")!="Expired",
                reconnect?"stale-reconnect-failure-cannot-replace-current-connection-diagnostics":"stale-logon-failure-cannot-replace-current-connection-diagnostics");
        }
        await using(var s=new Session())
        {
            string id=s.Send("snapshot");await s.Done(id);bool duplicate=false,foreign=false;
            try{s.Service.Accept(JsonSerializer.Serialize(new{id,profileID=Profile,profileGeneration=Generation,operation="snapshot"}));}catch(InvalidDataException){duplicate=true;}
            try{s.Service.Accept(JsonSerializer.Serialize(new{id=Guid.NewGuid().ToString("D"),profileID=Profile,profileGeneration=Guid.NewGuid().ToString("D"),operation="snapshot"}));}catch(InvalidDataException){foreign=true;}
            Check(duplicate&&foreign,"duplicate-ID-and-foreign-generation-fail-closed");
        }
        bool oversized=false,truncated=false;
        try{await PersistentSteamService.ReadBoundedLine(new StringReader(new string('x',PersistentSteamService.MaximumLine+1)+"\n"),default);}catch(InvalidDataException){oversized=true;}
        try{await PersistentSteamService.ReadBoundedLine(new StringReader("{}"),default);}catch(InvalidDataException){truncated=true;}
        Check(oversized&&truncated,"bounded-JSONL-rejects-oversized-and-truncated-frame");
        Check(new SteamServiceCredentials("fixture_account",Secret).ToString()=="[private Steam credentials]","private-credential-repr-redacted");
        Console.WriteLine(JsonSerializer.Serialize(new{passed=true,checkCount=checks.Count,checks,fixtureOnly=true,realSteamAccountUsed=false,steamClientCreated=false}));return 0;
    }
}
