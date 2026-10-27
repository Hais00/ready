// SPDX-License-Identifier: GPL-3.0-or-later
// SteamKit usage follows the upstream LGPL authentication samples. No Valve client binaries.
using System.Text.Json;
using SteamKit2;
using SteamKit2.Authentication;

static class Program
{
    static void Emit(object obj) { Console.WriteLine(JsonSerializer.Serialize(obj)); Console.Out.Flush(); }
    static string Str(JsonElement e, string name, string fallback="") => e.TryGetProperty(name,out var value) ? value.GetString() ?? fallback : fallback;
    static TaskCompletionSource<T> Completion<T>() => new(TaskCreationOptions.RunContinuationsAsynchronously);
    static async Task<int> Main()
    {
        try
        {
            var input=await Console.In.ReadLineAsync();
            if(input is null || input.Length>16*1024*1024) throw new Exception("invalid_request");
            using var doc=JsonDocument.Parse(input); var root=doc.RootElement;
            var op=Str(root,"operation");
            if(op=="self_test") { Emit(new {type="result",helper="SteamKit2",protocolVersion=1,transport="stdin-jsonl",libraryParsing="compiled",version="3.5.1-Alpha.1"});return 0; }
            using var deadline=new CancellationTokenSource(TimeSpan.FromMinutes(4));
            var client=new SteamClient(); var callbacks=new CallbackManager(client);
            var user=client.GetHandler<SteamUser>()!;var apps=client.GetHandler<SteamApps>()!;
            var connected=Completion<bool>();var loggedOn=Completion<SteamUser.LoggedOnCallback>();var licenses=Completion<SteamApps.LicenseListCallback>();
            using var c1=callbacks.Subscribe<SteamClient.ConnectedCallback>(_=>connected.TrySetResult(true));
            using var c2=callbacks.Subscribe<SteamUser.LoggedOnCallback>(c=>loggedOn.TrySetResult(c));
            using var c3=callbacks.Subscribe<SteamApps.LicenseListCallback>(c=>licenses.TrySetResult(c));
            using var c4=callbacks.Subscribe<SteamClient.DisconnectedCallback>(_=>{ if(!deadline.IsCancellationRequested) { connected.TrySetException(new Exception("disconnected"));loggedOn.TrySetException(new Exception("disconnected"));licenses.TrySetException(new Exception("disconnected")); }});
            var pump=Task.Run(async ()=>{try{while(!deadline.IsCancellationRequested)await callbacks.RunWaitCallbackAsync(deadline.Token);}catch(OperationCanceledException){} });
            client.Connect();await connected.Task.WaitAsync(deadline.Token);
            if(op is "auth_begin" or "auth_start")
            {
                var auth=await client.Authentication.BeginAuthSessionViaQRAsync(new AuthSessionDetails { IsPersistentSession=true, DeviceFriendlyName="Ready for macOS" });
                void QR()=>Emit(new {type="qr",url=auth.ChallengeURL,instructions="Scan with the Steam mobile app and approve sign-in."});
                auth.ChallengeURLChanged=QR;QR();
                var result=await auth.PollingWaitForResultAsync(deadline.Token);
                Emit(new {type="result",credentials=new {username=result.AccountName,refresh_token=result.RefreshToken,access_token=result.AccessToken}});
                deadline.Cancel();client.Disconnect();await pump;return 0;
            }
            if(!root.TryGetProperty("credentials",out var cred))throw new Exception("authentication_required");
            var name=Str(cred,"username");var token=Str(cred,"refresh_token");
            if(name.Length==0 || token.Length==0)throw new Exception("authentication_required");
            user.LogOn(new SteamUser.LogOnDetails { Username=name,AccessToken=token,ShouldRememberPassword=false });
            var login=await loggedOn.Task.WaitAsync(deadline.Token);
            if(login.Result!=EResult.OK)throw new Exception("authentication_required");
            if(op=="library")
            {
                var licenseList=await licenses.Task.WaitAsync(deadline.Token);
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
                        var launch=app.KeyValues["config"]["launch"].Children.Select(k=>new {executable=k["executable"].Value,arguments=k["arguments"].Value,oslist=k["config"]["oslist"].Value}).ToArray();
                        games.Add(new {id="steam:"+app.ID,store="steam",storeID=app.ID.ToString(),title=common["name"].Value ?? app.ID.ToString(),artworkURL=$"https://cdn.cloudflare.steamstatic.com/steam/apps/{app.ID}/library_600x900.jpg",variants,engine="automatic",saveRules=Array.Empty<object>(),metadata=new {launch}});
                    }
                    Emit(new {type="progress",phase="library",completed=games.Count});
                }
                Emit(new {type="result",games,steamID=client.SteamID?.ConvertToUInt64().ToString()});
            }
            else if(op=="launch_info")
            {
                var options=root.GetProperty("options");var id=Str(options,"gameID");
                if(!uint.TryParse(id,out _))throw new Exception("invalid_game_id");
                Emit(new {type="result",environment=new Dictionary<string,string>{{"SteamAppId",id},{"SteamGameId",id}},arguments=Array.Empty<string>(),requiresSteamClient=true,note="DRM-free games may run directly. Steamworks/DRM games need a genuine compatible Steam client; this bridge does not emulate or bypass it."});
            }
            else throw new Exception("unsupported_operation");
            user.LogOff();deadline.Cancel();client.Disconnect();await pump;return 0;
        }
        catch(OperationCanceledException){Emit(new {type="error",code="timeout",message="Steam operation timed out or was cancelled"});return 1;}
        catch(Exception e){var safe=new[]{"authentication_required","invalid_request","unsupported_operation","license_error","invalid_game_id","disconnected"};var code=safe.Contains(e.Message)?e.Message:"steam_error";Emit(new {type="error",code,message="Steam operation failed; no credentials were logged"});return 1;}
    }
}
