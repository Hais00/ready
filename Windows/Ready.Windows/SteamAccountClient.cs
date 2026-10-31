// SPDX-License-Identifier: GPL-3.0-only
using System.Text.Json;
using Ready.Windows.Core;

namespace Ready.Windows;

internal sealed record SteamFriend(string Id, string Name, string Presence, string? Game, string Relationship);
internal sealed record SteamAccountState(string State, string DisplayName, string Presence, string? QR,
    string? GuardChallenge, string? GuardMethod, string? Notice, IReadOnlyList<SteamFriend> Friends, IReadOnlyList<Game> Games)
{
    public static SteamAccountState Empty => new("offline", "", "Offline", null, null, null, null, [], []);
    public override string ToString() => "[private Steam account state]";
}

internal sealed class SteamAccountClient : IAsyncDisposable
{
    private readonly string profile;
    private readonly SteamCredentialStore vault;
    private readonly SteamServiceProcess service;
    private readonly object sync = new();
    private SteamAccountState state = SteamAccountState.Empty;
    private CancellationTokenSource? authentication;
    private bool disposed;
    public event Action? Changed;
    public SteamAccountState State { get { lock (sync) return state; } }
    public bool IsAlive => service.IsAlive;
    public SteamAccountClient(string executable, string profile, SteamCredentialStore vault)
    {
        this.profile = profile; this.vault = vault; service = new(executable, profile);
        service.Received += Apply;
        service.CredentialReceived += Save;
    }
    private void Save(SteamCredential credential)
    {
        lock (sync)
        {
            if (disposed || authentication is null || authentication.IsCancellationRequested) return;
            vault.Write(profile, credential);
        }
    }
    private static string Text(JsonElement e, string key, int limit = 512)
    {
        if (!e.TryGetProperty(key, out var v) || v.ValueKind != JsonValueKind.String) return "";
        string value = v.GetString()!;
        return new string(value.Where(c => !char.IsControl(c)).Take(limit).ToArray());
    }
    private void Apply(SteamServiceEvent message)
    {
        bool changed;
        lock (sync)
        {
            if (disposed) return;
            var previous = state;
            var value = message.Data;
            if (value.TryGetProperty("invalidateCredentials", out var invalid) && invalid.ValueKind == JsonValueKind.True) vault.Forget(profile);
            if (message.Type is "state" or "heartbeat" || message.Type == "result" && value.TryGetProperty("state", out _))
            {
                string status = Text(value, "state");
                if (status is "offline" or "connecting" or "authenticating" or "online" or "reconnecting" or "logged_out" or "authorization_required")
                    state = state with { State = status, QR = status == "authenticating" ? state.QR : null,
                        GuardChallenge = status == "authenticating" ? state.GuardChallenge : null,
                        GuardMethod = status == "authenticating" ? state.GuardMethod : null };
            }
            if (message.Type == "qr")
            {
                string url = Text(value, "url", 4096);
                if (Uri.TryCreate(url, UriKind.Absolute, out var uri) && uri.Scheme == "https" && uri.Host == "s.team" && uri.AbsolutePath.StartsWith("/q/", StringComparison.Ordinal))
                    state = state with { QR = url, GuardChallenge = null, GuardMethod = null };
            }
            if (message.Type == "guard") state = state with { QR = null, GuardChallenge = Text(value, "challengeID", 36), GuardMethod = Text(value, "method", 32) };
            if (message.Type == "persona") state = state with { DisplayName = Text(value, "displayName"), Presence = Text(value, "presence", 32) };
            if (value.TryGetProperty("account", out var account) && account.ValueKind == JsonValueKind.Object)
                state = state with { DisplayName = Text(account, "displayName"), Presence = Text(account, "presence", 32) };
            if (value.TryGetProperty("friends", out var friends) && friends.ValueKind == JsonValueKind.Array)
            {
                if (friends.GetArrayLength() > 20000) throw new SteamServiceException("friends_too_large");
                state = state with { Friends = friends.EnumerateArray().Select(f => new SteamFriend(Text(f, "steamID", 20), Text(f, "displayName"), Text(f, "presence", 32), Text(f, "gameName"), Text(f, "relationship", 32))).ToArray() };
            }
            changed = state != previous;
        }
        if (changed) Changed?.Invoke();
    }
    public async Task InitializeAsync()
    {
        await service.RequestAsync("snapshot");
        var credential = vault.Read(profile);
        if (credential is not null) { await service.RequestAsync("connect", credential: credential); await RefreshAsync(); }
    }
    public async Task AuthenticateAsync(string? username = null, string? password = null)
    {
        CancellationTokenSource flow;
        lock (sync)
        {
            if (authentication is not null) throw new SteamServiceException("busy");
            authentication = flow = new(); state = state with { Notice = null, QR = null, GuardChallenge = null, GuardMethod = null };
        }
        try
        {
            var login = service.RequestAsync("authenticate", new { method = username is null ? "qr" : "password" }, cancellation: flow.Token,
                authentication: username is null ? null : new { username, password });
            username = password = null; await login;
            await RefreshAsync();
        }
        finally
        {
            lock (sync) { authentication = null; state = state with { QR = null, GuardChallenge = null, GuardMethod = null }; }
            flow.Dispose(); Changed?.Invoke();
        }
    }
    public void CancelAuthentication()
    {
        lock (sync) { authentication?.Cancel(); state = state with { QR = null, GuardChallenge = null, GuardMethod = null }; }
        Changed?.Invoke();
    }
    public async Task GuardAsync(string code)
    {
        string challenge = State.GuardChallenge ?? throw new SteamServiceException("invalid_guard_response");
        await service.RequestAsync("guard_code", new { challengeID = challenge, code });
    }
    public async Task RefreshAsync()
    {
        await service.RequestAsync("snapshot"); if (State.State != "online") return;
        List<JsonElement> entries = []; int pageCount = 0;
        var result = await service.RequestAsync("library", new { paged = true }, page: frame =>
        {
            if (frame.GetProperty("pageIndex").GetInt32() != pageCount++ || !frame.TryGetProperty("games", out var page)
                || page.ValueKind != JsonValueKind.Array || page.GetArrayLength() > 50 || entries.Count + page.GetArrayLength() > 20000) throw new SteamServiceException("library_invalid");
            entries.AddRange(page.EnumerateArray().Select(e => e.Clone()));
        });
        if (result.GetProperty("pageCount").GetInt32() != pageCount || result.GetProperty("recordCount").GetInt32() != entries.Count) throw new SteamServiceException("library_incomplete");
        List<Game> catalog = [];
        HashSet<uint> ids = [];
        foreach (var game in entries)
        {
            if (!uint.TryParse(Text(game, "storeID", 10), out uint app) || app is 0 or uint.MaxValue) continue;
            if (!ids.Add(app)) throw new SteamServiceException("library_duplicate");
            if (!game.TryGetProperty("metadata", out var metadata) || Text(metadata, "libraryKind", 32) != "game") continue;
            if (game.TryGetProperty("variants", out var variants) && variants.ValueKind == JsonValueKind.Array && variants.GetArrayLength() > 0
                && !variants.EnumerateArray().Any(v => Text(v, "platform", 32) == "windows")) continue;
            catalog.Add(new("steam:" + app, Text(game, "title"), GameSource.Steam, "", AppId: app, Installed: false));
        }
        lock (sync) { if (disposed) return; state = state with { Games = catalog }; }
        Changed?.Invoke();
    }
    public async Task ReconnectAsync()
    {
        var credential = vault.Read(profile) ?? throw new SteamServiceException("authentication_required");
        await service.RequestAsync("connect", credential: credential); await RefreshAsync();
    }
    public Task PresenceAsync(string presence) => service.RequestAsync("set_presence", new { presence });
    public Task RenameAsync(string displayName) => service.RequestAsync("set_persona_name", new { displayName });
    public Task FriendActionAsync(string operation, string steamID) => service.RequestAsync(operation, new { steamID });
    public async Task OfflineAsync() { CancelAuthentication(); await service.RequestAsync("offline"); }
    public async Task LogoutAsync()
    {
        CancelAuthentication(); await service.RequestAsync("logout", new { forgetCredentials = true }); vault.Forget(profile);
        lock (sync) state = SteamAccountState.Empty with { State = "logged_out" }; Changed?.Invoke();
    }
    public async ValueTask DisposeAsync()
    {
        lock (sync) { if (disposed) return; disposed = true; authentication?.Cancel(); }
        service.Received -= Apply; service.CredentialReceived -= Save; await service.DisposeAsync();
    }
}
