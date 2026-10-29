// SPDX-License-Identifier: GPL-3.0-only
using SteamKit2;
using SteamKit2.Internal;

sealed record SteamOwnedGame(uint AppID,string Name,string IconHash,string CapsuleFilename)
{public override string ToString()=>"[private owned-game metadata]";}
sealed record SteamOwnedGamesSnapshot(bool Available,IReadOnlyDictionary<uint,SteamOwnedGame> Games,string Status)
{
    internal static SteamOwnedGamesSnapshot Unavailable(string status="unavailable")=>new(false,new Dictionary<uint,SteamOwnedGame>(),status);
    public override string ToString()=>"[private self-owned catalog]";
}
static class SteamOwnedGamesCatalog
{
    internal static CPlayer_GetOwnedGames_Request Request(ulong self)
    {
        var id=new SteamID(self);
        if(!id.IsValid||!id.IsIndividualAccount)throw new ArgumentException();
        return new(){steamid=self,include_appinfo=true,include_extended_appinfo=true,skip_unvetted_apps=false,
            include_free_sub=true,include_played_free_games=true,include_family_licenses=false,language="english"};
    }
    internal static SteamOwnedGamesSnapshot Parse(EResult result,CPlayer_GetOwnedGames_Response? body)
    {
        if(result!=EResult.OK||body is null)return SteamOwnedGamesSnapshot.Unavailable();
        if(body.games.Count>20000||body.game_count!=body.games.Count)return SteamOwnedGamesSnapshot.Unavailable("invalid_response");
        var games=new Dictionary<uint,SteamOwnedGame>();
        foreach(var item in body.games)
        {
            if(item.appid<=0||!games.TryAdd((uint)item.appid,new((uint)item.appid,
                SteamCatalogMetadata.Clean(item.name,512),item.img_icon_url,item.capsule_filename)))return SteamOwnedGamesSnapshot.Unavailable("invalid_response");
        }
        return new(true,games,"available");
    }
    internal static async Task<SteamOwnedGamesSnapshot> FetchSelfAsync(SteamClient client,CancellationToken cancel)
    {
        ulong self=client.SteamID?.ConvertToUInt64()??0;
        if(self==0||!client.IsConnected)throw new IOException();
        var request=Request(self); // Never accepts an external/account option.
        using var deadline=CancellationTokenSource.CreateLinkedTokenSource(cancel);deadline.CancelAfter(TimeSpan.FromSeconds(15));
        SteamOwnedGamesSnapshot snapshot;
        try
        {
            var player=client.GetHandler<SteamUnifiedMessages>()!.CreateService<Player>();
            var response=await player.GetOwnedGames(request).ToTask().WaitAsync(deadline.Token);
            snapshot=Parse(response.Result,response.Body);
        }
        catch(OperationCanceledException)when(cancel.IsCancellationRequested){throw;}
        catch(OperationCanceledException){snapshot=SteamOwnedGamesSnapshot.Unavailable("timeout");}
        catch(Exception){snapshot=SteamOwnedGamesSnapshot.Unavailable();} // No raw private response/exception diagnostics.
        cancel.ThrowIfCancellationRequested();
        if(client.SteamID?.ConvertToUInt64()!=self||!client.IsConnected)throw new IOException();
        return snapshot;
    }
    internal static async Task<HashSet<uint>> PackageIDsAsync(SteamApps apps,Task<SteamApps.LicenseListCallback> licenseTask,CancellationToken cancel)
    {
        var licenses=await licenseTask.WaitAsync(cancel);if(licenses.Result!=EResult.OK)throw new IOException();
        var ids=new HashSet<uint>();
        foreach(var chunk in licenses.LicenseList.Chunk(100))
        {
            var response=await apps.PICSGetProductInfo(Array.Empty<SteamApps.PICSRequest>(),chunk.Select(x=>new SteamApps.PICSRequest(x.PackageID,x.AccessToken))).ToTask().WaitAsync(cancel);
            if(!response.Complete||response.Failed||response.Results is null)throw new IOException();
            foreach(var part in response.Results)foreach(var package in part.Packages.Values)
                if(package.KeyValues is{} values)foreach(var item in values["appids"].Children)if(uint.TryParse(item.Value,out uint id)&&id>0)ids.Add(id);
        }
        return ids;
    }
    internal static async Task<Dictionary<uint,KeyValue>> AppInfoAsync(SteamApps apps,IReadOnlyCollection<uint> ids,CancellationToken cancel)
    {
        var tokens=await apps.PICSGetAccessTokens(ids,Array.Empty<uint>()).ToTask().WaitAsync(cancel);
        var response=await apps.PICSGetProductInfo(ids.Select(id=>new SteamApps.PICSRequest(id,tokens.AppTokens.GetValueOrDefault(id))),Array.Empty<SteamApps.PICSRequest>()).ToTask().WaitAsync(cancel);
        if(!response.Complete||response.Failed||response.Results is null)throw new IOException();
        var result=new Dictionary<uint,KeyValue>();foreach(var part in response.Results)foreach(var app in part.Apps.Values)if(app.KeyValues is{} values)result[app.ID]=values;return result;
    }
    internal static async Task CollectAsync(Func<CancellationToken,Task<SteamOwnedGamesSnapshot>> owned,
        Func<CancellationToken,Task<HashSet<uint>>> licenses,
        Func<IReadOnlyCollection<uint>,CancellationToken,Task<Dictionary<uint,KeyValue>>> appInfo,
        Action<object[]> page,CancellationToken cancel)
    {
        SteamOwnedGamesSnapshot snapshot;
        try{snapshot=await owned(cancel);}catch(OperationCanceledException)when(cancel.IsCancellationRequested){throw;}
        catch(Exception){snapshot=SteamOwnedGamesSnapshot.Unavailable();}
        cancel.ThrowIfCancellationRequested();HashSet<uint> packageIDs;bool packageComplete=true;
        try{packageIDs=await licenses(cancel);}catch(OperationCanceledException)when(cancel.IsCancellationRequested){throw;}
        catch(Exception)when(snapshot.Available&&snapshot.Games.Count>0){packageIDs=new();packageComplete=false;}
        var ids=new HashSet<uint>(packageIDs);if(snapshot.Available)ids.UnionWith(snapshot.Games.Keys);ids.Remove(0);
        if(ids.Count>20000)throw new SteamLibraryPayloadException("library_too_large");
        foreach(var chunk in ids.Order().Chunk(50))
        {
            cancel.ThrowIfCancellationRequested();Dictionary<uint,KeyValue> info;
            try{info=await appInfo(chunk,cancel);}catch(OperationCanceledException)when(cancel.IsCancellationRequested){throw;}
            catch(Exception){info=new();}
            cancel.ThrowIfCancellationRequested();
            page(chunk.Select(id=>SteamCatalogMetadata.LibraryGame(id,info.GetValueOrDefault(id),snapshot,packageIDs.Contains(id),packageComplete)).ToArray());
        }
    }

}
