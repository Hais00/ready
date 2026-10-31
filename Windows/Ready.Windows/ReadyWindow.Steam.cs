// SPDX-License-Identifier: GPL-3.0-only
using Ready.Windows.Core;

namespace Ready.Windows;

internal sealed partial class ReadyWindow
{
    private bool steamEnabled;
    private SteamCredentialStore? steamVault;
    private SteamAccountClient? steam;
    private int steamEpoch;
    private float steamPageOffset;
    private string? steamNotice, steamFixtureExecutable;
    private string lastSteamName = "";
    private IReadOnlyList<Game>? lastSteamCatalog;
    private (string Operation, string Target, long Until)? armedSteamAction;
    private readonly Dictionary<string, string> steamFields = new()
    { ["account"] = "", ["password"] = "", ["guard"] = "", ["display"] = "", ["friend"] = "" };
    private bool steamSelectAll;
    private IEnumerable<Game> CurrentSteamGames()
    {
        var owned = steam?.State.Games ?? [];
        if (owned.Count == 0) return steamGames;
        var installed = steamGames.ToDictionary(g => g.Id);
        return owned.Select(g => installed.TryGetValue(g.Id, out var local) ? g with { InstallDirectory = local.InstallDirectory, Artwork = local.Artwork, Installed = true } : g);
    }
    private async Task InitializeSteam()
    {
        if (!steamEnabled || closing || steam is not null) return;
        int epoch = ++steamEpoch; string profile = library.ActiveProfile;
        try
        {
            steamVault ??= new SteamCredentialStore(store.Root);
            var client = new SteamAccountClient(steamFixtureExecutable ?? Path.Combine(AppContext.BaseDirectory, "SteamBridge", "ReadySteamBridge.exe"), profile, steamVault);
            steam = client;
            client.Changed += () =>
            {
                if (closing || !IsHandleCreated) return;
                try
                {
                    BeginInvoke(() =>
                    {
                        if (closing || steam != client || steamEpoch != epoch || library.ActiveProfile != profile) return;
                        var snapshot = client.State;
                        if (shell.Focus != "field:steam:display" && (steamFields["display"].Length == 0 || steamFields["display"] == lastSteamName)) steamFields["display"] = snapshot.DisplayName;
                        lastSteamName = snapshot.DisplayName;
                        if (shell.Page == Destination.Friends) UpdatePage();
                        if (!ReferenceEquals(lastSteamCatalog, snapshot.Games))
                        { bool changed = snapshot.Games.Count > 0 || lastSteamCatalog?.Count > 0; lastSteamCatalog = snapshot.Games; if (changed) UpdateCatalog(); }
                        Invalidate();
                    });
                }
                catch (InvalidOperationException) when (closing || !IsHandleCreated) { }
            };
            await client.InitializeAsync();
        }
        catch (Exception error) when (error is SteamServiceException or IOException or UnauthorizedAccessException or System.Security.SecurityException or NotSupportedException or System.Security.Cryptography.CryptographicException or System.ComponentModel.Win32Exception or InvalidOperationException)
        { if (epoch == steamEpoch && !closing) steamNotice = SteamError(error); }
        if (!closing && epoch == steamEpoch) { UpdatePage(); Invalidate(); }
    }
    private async Task SwitchSteamProfile()
    {
        await StopSteam(); ClearSteamInputs(); steamNotice = null; UpdateCatalog();
        await InitializeSteam();
    }
    private async Task StopSteam()
    {
        ++steamEpoch; var old = steam; steam = null; lastSteamCatalog = null; lastSteamName = "";
        if (old is not null) await old.DisposeAsync();
    }
    private void ClearSteamInputs()
    { foreach (var key in steamFields.Keys) steamFields[key] = ""; armedSteamAction = null; steamSelectAll = false; }
    private bool HandleSteamCharacter(KeyPressEventArgs e)
    {
        if (shell.Page != Destination.Friends || shell.Focus is not { } id || !id.StartsWith("field:steam:", StringComparison.Ordinal)) return false;
        string key = id[12..]; if (!steamFields.TryGetValue(key, out var value)) return false;
        if (!char.IsControl(e.KeyChar) && value.Length < (key == "password" ? 1024 : 128))
        { steamFields[key] = (steamSelectAll ? "" : value) + e.KeyChar; steamSelectAll = false; UpdatePage(); }
        e.Handled = true; return true;
    }
    private bool HandleSteamEditing(KeyEventArgs e)
    {
        if (shell.Page != Destination.Friends || shell.Focus is not { } id || !id.StartsWith("field:steam:", StringComparison.Ordinal)) return false;
        string key = id[12..]; if (!steamFields.TryGetValue(key, out var value)) return false;
        if (e.Control && e.KeyCode == Keys.A) steamSelectAll = true;
        else if (e.KeyCode == Keys.Back)
        {
            steamFields[key] = steamSelectAll || value.Length == 0 ? "" : value[..(value.Length - (char.IsLowSurrogate(value[^1]) && value.Length > 1 ? 2 : 1))];
            steamSelectAll = false;
        }
        else if (e.Control && e.KeyCode == Keys.V)
        {
            string text = Clipboard.ContainsText() ? Clipboard.GetText() : "";
            steamFields[key] = string.Concat(steamSelectAll ? "" : value, new string(text.Where(c => !char.IsControl(c)).ToArray()));
            steamFields[key] = steamFields[key][..Math.Min(steamFields[key].Length, key == "password" ? 1024 : 128)]; steamSelectAll = false;
        }
        else if (e.KeyCode == Keys.Enter)
        { _ = Act(key == "guard" ? "steam:guard" : key is "account" or "password" ? "steam:password" : "steam:rename"); }
        else return false;
        e.Handled = true; e.SuppressKeyPress = true; UpdatePage(); return true;
    }
    private CanvasPage SteamPage()
    {
        var state = steam?.State ?? SteamAccountState.Empty;
        bool online = state.State == "online", pending = state.State is "connecting" or "authenticating" or "reconnecting";
        string status = state.State switch
        { "connecting" => "Connessione a Steam…", "authenticating" => "Accesso a Steam in corso…", "reconnecting" => "Riconnessione in corso…", "online" => "Connesso · " + state.Presence, "authorization_required" => "Accedi nuovamente a Steam.", "logged_out" => "Account disconnesso", _ => "Non connesso" };
        List<CanvasField> fields = []; List<PageAction> actions = [];
        if (state.QR is not null)
        { status += "\nScansiona il QR con l’app Steam e approva l’accesso."; actions.Add(new("steam:cancel", "Annulla accesso")); }
        else if (state.GuardMethod is { Length: > 0 } method)
        {
            if (method == "device_confirmation") status += "\nApprova l’accesso nell’app Steam.";
            else
            {
                fields.Add(new("field:steam:guard", "Codice Steam Guard", steamFields["guard"], true));
                actions.Add(new("steam:guard", "Conferma codice"));
            }
            actions.Add(new("steam:cancel", "Annulla accesso"));
        }
        else if (!online)
        {
            fields.Add(new("field:steam:account", "Nome account Steam (diverso dal nome pubblico)", steamFields["account"]));
            fields.Add(new("field:steam:password", "Password · usata solo per questo accesso", steamFields["password"], true));
            actions.AddRange([new("steam:qr", "Accedi con QR", steam is not null && !pending), new("steam:password", "Accedi con password", steam is not null && !pending), new("steam:reconnect", "Riconnetti", steam is not null && !pending)]);
            if (pending) actions.Add(new("steam:cancel", "Annulla accesso"));
            if (steam is not null) actions.AddRange([new("steam:offline", "Modalità offline"), new("steam:logout", "Esci dall’account")]);
        }
        else
        {
            fields.Add(new("field:steam:display", "Nome pubblico Steam", steamFields["display"]));
            fields.Add(new("field:steam:friend", "SteamID64 dell’amico", steamFields["friend"]));
            actions.AddRange([new("steam:rename", "Aggiorna nome pubblico"), new("steam:presence:Online", "Online"), new("steam:presence:Away", "Assente"), new("steam:presence:Busy", "Occupato"), new("steam:presence:Invisible", "Invisibile"), new("steam:refresh", "Aggiorna libreria"), new("steam:offline", "Modalità offline"), new("steam:logout", "Esci dall’account"), new("steam:friend:add_friend", "Aggiungi"), new("steam:friend:remove_friend", "Rimuovi"), new("steam:friend:block_friend", "Blocca"), new("steam:friend:unblock_friend", "Sblocca")]);
        }
        return new("Amici", state.DisplayName.Length > 0 && online ? state.DisplayName : "Account Steam", status + (steamNotice is null ? "" : "\n" + steamNotice),
            Actions: actions, Fields: fields, QR: state.QR, Offset: steamPageOffset,
            Rows: online ? state.Friends.Select(f => new PageRow("steam:select:" + f.Id, f.Name.Length > 0 ? f.Name : f.Id,
                f.Presence + (string.IsNullOrEmpty(f.Game) ? "" : " · " + f.Game) + " · " + f.Relationship)).ToArray() : []);
    }
    private async Task<bool> SteamAction(string action)
    {
        if (!action.StartsWith("steam:", StringComparison.Ordinal)) return false;
        if (steam is null || !steam.IsAlive) { await StopSteam(); await InitializeSteam(); if (steam is null) { UpdatePage(); return true; } }
        var client = steam;
        try
        {
            steamNotice = null;
            switch (action)
            {
                case "steam:qr": steamPageOffset = 0; await client.AuthenticateAsync(); break;
                case "steam:password":
                    string account = steamFields["account"], password = steamFields["password"]; steamFields["password"] = ""; UpdatePage();
                    if (account.Length == 0 || password.Length == 0) { steamNotice = "Inserisci nome account e password, oppure usa il QR."; break; }
                    var passwordLogin = client.AuthenticateAsync(account, password); account = password = ""; await passwordLogin; break;
                case "steam:guard": string code = steamFields["guard"]; steamFields["guard"] = ""; await client.GuardAsync(code); break;
                case "steam:cancel": client.CancelAuthentication(); break;
                case "steam:reconnect": await client.ReconnectAsync(); break;
                case "steam:refresh": await client.RefreshAsync(); await DiscoverSteam(); break;
                case "steam:offline": await client.OfflineAsync(); break;
                case "steam:logout": await client.LogoutAsync(); ClearSteamInputs(); break;
                case "steam:rename":
                    await client.RenameAsync(steamFields["display"].Length > 0 ? steamFields["display"] : client.State.DisplayName); steamNotice = "Richiesta inviata a Steam."; break;
                default:
                    if (action.StartsWith("steam:select:", StringComparison.Ordinal)) { steamFields["friend"] = action[13..]; steamPageOffset = 0; }
                    else if (action.StartsWith("steam:presence:", StringComparison.Ordinal)) await client.PresenceAsync(action[15..]);
                    else if (action.StartsWith("steam:friend:", StringComparison.Ordinal))
                    {
                        string operation = action[13..], target = steamFields["friend"];
                        if (operation is "remove_friend" or "block_friend" && (armedSteamAction is not { } armed || armed.Operation != operation || armed.Target != target || Environment.TickCount64 > armed.Until))
                        { armedSteamAction = (operation, target, Environment.TickCount64 + 8000); steamNotice = "Premi di nuovo entro 8 secondi per confermare."; break; }
                        armedSteamAction = null; await client.FriendActionAsync(operation, target); steamNotice = "Richiesta inviata a Steam.";
                    }
                    break;
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception error) when (error is SteamServiceException or IOException or System.Security.Cryptography.CryptographicException or InvalidOperationException)
        { if (steam == client) steamNotice = SteamError(error); }
        if (!closing && steam == client) { UpdateCatalog(); if (shell.Page == Destination.Friends) UpdatePage(); }
        return true;
    }
    private static string SteamError(Exception error) => error is SteamServiceException service ? service.Code switch
    {
        "service_missing" => "Componente Steam non installato. Completa la build con il servizio Steam.",
        "authentication_required" => "Accedi con QR o password.", "authentication_failed" => "Steam non ha accettato l’accesso.",
        "invalid_guard_response" => "Controlla il codice Steam Guard.", "busy" => "Un’operazione Steam è già in corso.",
        "not_online" => "Steam è offline.", "network_error" or "disconnected" => "Connessione Steam interrotta. Puoi riconnetterti senza eliminare il login salvato.",
        "timeout" => "Steam non ha risposto in tempo.", _ => "Operazione Steam non riuscita. Riprova o riconnetti l’account."
    } : error is System.Security.Cryptography.CryptographicException ? "Non è possibile leggere o proteggere il login Windows di questo profilo." : "Il servizio Steam non è disponibile.";

    internal async Task ExerciseSteamAsync(string fixture, string report)
    {
        List<string> checks = [];
        void Check(bool value, string label) { if (!value) throw new InvalidOperationException(label); checks.Add(label); }
        async Task Until(Func<bool> predicate)
        { using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10)); while (!predicate()) await Task.Delay(5, timeout.Token); }
        steamFixtureExecutable = fixture; steamEnabled = true;
        await InitializeSteam(); await Task.Delay(50); Navigate(Destination.Friends);
        Check(steam?.State.State == "offline" && page?.Fields?.Count == 2, "Actual canvas presents account/password login fields");
        var qrFlow = Act("steam:qr"); await Until(() => steam!.State.QR is not null && page?.QR is not null);
        using (var raster = painter.Draw(shell, page, ClientSize.Width, ClientSize.Height, ScaleFactor))
        using (var image = canvas!.Readback(raster)) Check(image.Width == ClientSize.Width, "QR challenge renders through the actual Vulkan canvas without disk output");
        Navigate(Destination.Settings); await qrFlow;
        Check(steamVault!.Read(library.ActiveProfile) is null && steam!.State.QR is null, "Navigation cancels QR and rejects late credentials");
        Navigate(Destination.Friends); await Until(() => steam!.State.State == "offline");
        shell.Focus = "field:steam:account"; foreach (char c in "fixture_account") OnKeyPress(new(c));
        shell.Focus = "field:steam:password"; foreach (char c in "fixture_password") OnKeyPress(new(c));
        Check(page!.Fields!.Single(f => f.Id == "field:steam:password").Secret && !page.ToString().Contains("fixture_password"), "Password field and page diagnostic masking");
        byte[] Pixels(CanvasPage value)
        {
            using var source = painter.Draw(shell, value, ClientSize.Width, ClientSize.Height, ScaleFactor); using var image = canvas!.Readback(source);
            var bits = image.LockBits(new Rectangle(0, 0, image.Width, image.Height), System.Drawing.Imaging.ImageLockMode.ReadOnly, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
            try { byte[] bytes = new byte[bits.Stride * image.Height]; System.Runtime.InteropServices.Marshal.Copy(bits.Scan0, bytes, 0, bytes.Length); return System.Security.Cryptography.SHA256.HashData(bytes); }
            finally { image.UnlockBits(bits); }
        }
        var masked = new CanvasPage("Amici", "Password", "", Fields: [new("field:steam:password", "Password", "secret-A", true)]);
        var alternative = masked with { Fields = [new("field:steam:password", "Password", "secret-B", true)] };
        var unmasked = masked with { Fields = [new("field:steam:password", "Password", "secret-B", false)] };
        Check(Pixels(masked).SequenceEqual(Pixels(alternative)) && !Pixels(masked).SequenceEqual(Pixels(unmasked)), "Actual GPU password pixels hide content with an unmasked negative control");
        var login = Act("steam:password"); await Until(() => steam!.State.GuardChallenge is { Length: > 0 });
        Check(steamFields["password"].Length == 0, "Submitting password clears the UI input immediately");
        shell.Focus = "field:steam:guard"; foreach (char c in "A1B2C") OnKeyPress(new(c)); await Act("steam:guard"); await login;
        Check(steam!.State.State == "online" && CurrentSteamGames().Single().AppId == 480 && steam.State.Friends.Count == 1, "Steam Guard completes into real account/friends/library UI routing with synthetic transport");
        string original = library.ActiveProfile; Navigate(Destination.Profiles); input = "Profilo Steam isolato"; await Act("profile:create");
        Check(steam!.State.State == "offline" && !CurrentSteamGames().Any() && steamVault.Read(original) is not null, "Changing profile closes the old helper and isolates owned catalog and credential");
        await Act("profile:" + original);
        Check(steam!.State.State == "online" && CurrentSteamGames().Single().AppId == 480, "Returning to profile restores its encrypted login and catalog");
        Navigate(Destination.Friends); await Act("steam:logout");
        Check(steamVault.Read(original) is null && steam!.State.Games.Count == 0, "Explicit logout clears profile credential and owned catalog");
        if (page!.QR is not null || page.Fields!.Any(f => f.Secret && f.Value.Length > 0)) throw new InvalidOperationException("Preview must not contain an authentication challenge");
        using (var raster = painter.Draw(shell, page, ClientSize.Width, ClientSize.Height, ScaleFactor))
        using (var image = canvas!.Readback(raster)) image.Save(Path.ChangeExtension(report, ".png"), System.Drawing.Imaging.ImageFormat.Png);
        await StopSteam();
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(report))!);
        File.WriteAllText(report, System.Text.Json.JsonSerializer.Serialize(new { schema = 1, passed = true, checks,
            architecture = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString(),
            scope = "Actual Windows form, Vulkan QR raster and DPAPI with an owned synthetic helper only; no genuine account/network/authentication or game host." }, new System.Text.Json.JsonSerializerOptions { WriteIndented = true }));
    }
}
