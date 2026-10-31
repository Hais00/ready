// SPDX-License-Identifier: GPL-3.0-only
using Microsoft.Win32;
using Ready.Windows.Core;
using System.Runtime.InteropServices;

namespace Ready.Windows;

internal sealed partial class ReadyWindow : Form
{
    private readonly Shell shell = new();
    private readonly CanvasPainter painter = new();
    private readonly LibraryStore store;
    private Library library;
    private VulkanCanvas? canvas;
    private CanvasPage? page;
    private IReadOnlyList<Game> steamGames = [];
    private NativeGameSession? session;
    private Game? selectedGame;
    private string input = "", settingsTab = "general";
    private string browserDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    private List<string> browserEntries = [];
    private int browserOffset, browserEpoch;
    private bool suspended, closing;
    private readonly System.Windows.Forms.Timer clock = new() { Interval = 1000 };
    private float ScaleFactor => DeviceDpi / 96f;
    private float LogicalWidth => ClientSize.Width / ScaleFactor;
    private float LogicalHeight => ClientSize.Height / ScaleFactor;
    public ReadyWindow(string dataRoot, bool discoverSteam = true)
    {
        Text = "Ready"; ClientSize = new(1100, 720); MinimumSize = new(820, 580); StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(16, 16, 16); KeyPreview = true;
        SetStyle(ControlStyles.Opaque | ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint, true);
        store = new(dataRoot); library = store.Load(); UpdateCatalog();
        steamEnabled = discoverSteam;
        clock.Tick += (_, _) => { var now = DateTime.Now.ToString("HH:mm"); if (painter.Clock != now) { painter.Clock = now; if (!suspended) Invalidate(); } };
        if (discoverSteam) Shown += async (_, _) => { await DiscoverSteam(); await InitializeSteam(); }; clock.Start();
    }
    protected override void OnHandleCreated(EventArgs e)
    { base.OnHandleCreated(e); canvas = new VulkanCanvas(Handle, ClientSize.Width, ClientSize.Height); }
    protected override void OnHandleDestroyed(EventArgs e)
    { canvas?.Dispose(); canvas = null; base.OnHandleDestroyed(e); }
    protected override void OnPaintBackground(PaintEventArgs e) { }
    protected override void OnPaint(PaintEventArgs e)
    {
        if (suspended || ClientSize.Width <= 0 || ClientSize.Height <= 0 || canvas is null) return;
        using var raster = painter.Draw(shell, page, ClientSize.Width, ClientSize.Height, ScaleFactor); canvas.Present(raster);
    }
    protected override void OnResize(EventArgs e)
    { base.OnResize(e); shell.ClearInteraction(); if (WindowState != FormWindowState.Minimized) { canvas?.Resize(ClientSize.Width, ClientSize.Height); Invalidate(); } }
    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e); string? old = shell.Hover; shell.Move(e.X / ScaleFactor, e.Y / ScaleFactor);
        Cursor = shell.Hover is null ? Cursors.Default : shell.Hover == "field" ? Cursors.IBeam : Cursors.Hand;
        if (old != shell.Hover) Invalidate();
    }
    protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); shell.Move(-1, -1); Invalidate(); }
    protected override void OnMouseDown(MouseEventArgs e)
    { base.OnMouseDown(e); if (e.Button != MouseButtons.Left) return; Focus(); Capture = true; shell.Down(e.X / ScaleFactor, e.Y / ScaleFactor); Invalidate(); }
    protected override async void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e); if (e.Button != MouseButtons.Left) return;
        string? action = shell.Up(e.X / ScaleFactor, e.Y / ScaleFactor); Capture = false; Invalidate();
        if (action is not null) await Act(action);
    }
    protected override void OnMouseCaptureChanged(EventArgs e) { base.OnMouseCaptureChanged(e); if (!Capture) { shell.Up(-1, -1); Invalidate(); } }
    protected override void OnMouseWheel(MouseEventArgs e)
    {
        base.OnMouseWheel(e);
        if (shell.Page == Destination.Friends || shell.Page == Destination.Downloads)
        { steamPageOffset = Math.Clamp(steamPageOffset - e.Delta / 120f * 72, 0, painter.MaximumPageOffset); UpdatePage(); Invalidate(); return; }
        if (shell.Page == Destination.Import)
        { browserOffset = Math.Clamp(browserOffset - Math.Sign(e.Delta) * 3, 0, Math.Max(0, browserEntries.Count - 1)); UpdateBrowserPage(); }
        else shell.ScrollBy(-e.Delta / 120f * 72, LogicalWidth, LogicalHeight);
        Invalidate();
    }
    protected override bool IsInputKey(Keys keyData) => (keyData & Keys.KeyCode) is Keys.Left or Keys.Right or Keys.Up or Keys.Down or Keys.Tab || base.IsInputKey(keyData);
    protected override async void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (HandleSteamEditing(e)) { Invalidate(); return; }
        if (e.KeyCode == Keys.F11)
        {
            if (FormBorderStyle == FormBorderStyle.None) { WindowState = FormWindowState.Normal; FormBorderStyle = FormBorderStyle.Sizable; }
            else { FormBorderStyle = FormBorderStyle.None; WindowState = FormWindowState.Maximized; }
        }
        else if (e.Control && e.KeyCode == Keys.F) { Navigate(Destination.Search); input = shell.Query; UpdatePage(); shell.Focus = "field"; }
        else if (e.KeyCode == Keys.Escape) { if (FormBorderStyle == FormBorderStyle.None) { WindowState = FormWindowState.Normal; FormBorderStyle = FormBorderStyle.Sizable; } else Navigate(Destination.Library); }
        else if (e.KeyCode == Keys.Tab) shell.CycleFocus(e.Shift);
        else if (e.KeyCode == Keys.Back && page?.Field is not null && shell.Focus == "field")
        { if (input.Length > 0) input = input[..(input.Length - (char.IsLowSurrogate(input[^1]) && input.Length > 1 ? 2 : 1))]; UpdatePage(); }
        else if (e.KeyCode == Keys.Enter) await Act(shell.Focus == "field" ? page?.Actions?.FirstOrDefault()?.Id ?? "" : shell.Focus ?? "");
        else if (e.KeyCode == Keys.Space && shell.Focus != "field") await Act(shell.Focus ?? "");
        else if (shell.Page == Destination.Library && e.KeyCode is Keys.Left or Keys.Right or Keys.Up or Keys.Down)
        {
            int selected = shell.Games.ToList().FindIndex(g => "game:" + g.Id == shell.Focus);
            int delta = e.KeyCode switch { Keys.Left => -1, Keys.Right => 1, Keys.Up => -shell.Columns(LogicalWidth), _ => shell.Columns(LogicalWidth) };
            if (shell.Games.Count > 0) shell.Reveal("game:" + shell.Games[Math.Clamp(selected < 0 ? 0 : selected + delta, 0, shell.Games.Count - 1)].Id, LogicalWidth, LogicalHeight);
        }
        else return;
        e.Handled = true; e.SuppressKeyPress = true; Invalidate();
    }
    protected override void OnKeyPress(KeyPressEventArgs e)
    {
        base.OnKeyPress(e);
        if (HandleSteamCharacter(e)) { Invalidate(); return; }
        if (page?.Field is not null && shell.Focus == "field" && !char.IsControl(e.KeyChar) && input.Length < 4096)
        { input += e.KeyChar; UpdatePage(); e.Handled = true; Invalidate(); }
    }
    private void UpdateCatalog()
    {
        shell.SetCatalog(library.ActiveGames.Concat(CurrentSteamGames()).DistinctBy(g => g.Id), shell.Query);
        painter.ProfileName = library.Profiles.First(p => p.Id == library.ActiveProfile).Name;
    }
    private async Task DiscoverSteam()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Valve\Steam");
        string? root = key?.GetValue("SteamPath") as string; if (root is null) return;
        var discovered = await Task.Run(() => SteamLibrary.Discover(root)); if (closing) return;
        steamGames = discovered.Games; UpdateCatalog(); if (discovered.Errors.Count > 0) shell.Error = discovered.Errors[0]; Invalidate();
    }
    private void Navigate(Destination destination)
    {
        if (shell.Page == Destination.Friends && destination != Destination.Friends) { steam?.CancelAuthentication(); ClearSteamInputs(); }
        steamPageOffset = 0;
        browserEpoch++; shell.Navigate(destination); shell.Error = null; input = "";
        if (destination == Destination.Import) { _ = Browse(browserDirectory); return; }
        UpdatePage(); Invalidate();
    }
    private void UpdatePage()
    {
        if (shell.Page == Destination.Import) { UpdateBrowserPage(); return; }
        string architecture = RuntimeInformation.OSArchitecture.ToString();
        var tabs = new[] { new PageAction("settings:general", "Generali"), new("settings:account", "Account"), new("settings:storage", "Archiviazione"), new("settings:runtime", "Motori"), new("settings:data", "Dati e ripristino") };
        page = shell.Page switch
        {
            Destination.Library => null,
            Destination.Search => new("Libreria", "Cerca nella libreria", "Cerca per titolo o ID.", input, "Titolo o ID", [new("search:apply", "Cerca"), new("nav:library", "Indietro")]),
            Destination.Profiles => new("Profili", "I tuoi profili", "Ogni profilo mantiene la propria libreria di giochi locali.", input, "Nome nuovo profilo", [new("profile:create", "Crea profilo")], library.Profiles.Select(p => new PageRow("profile:" + p.Id, p.Name, p.Id == library.ActiveProfile ? "Profilo attivo" : "Seleziona profilo")).ToArray()),
            Destination.Friends => SteamPage(),
            Destination.Downloads => DownloadsPage(),
            Destination.Install => InstallPage(),
            Destination.Game => new("Gioco", selectedGame?.Title ?? "Gioco", selectedGame is null ? "" : selectedGame.InstallDirectory + "\n" + (selectedGame.Source == GameSource.Local ? $"Windows · {selectedGame.Architecture}" : "Steam · Windows"), Actions: selectedGame is { Source: GameSource.Steam, Installed: false } ? [new("download:prepare", "Installa"), new("nav:library", "Indietro")] : [new("game:play", "Gioca"), new("nav:library", "Indietro")]),
            Destination.Settings => new("Impostazioni", settingsTab switch { "runtime" => "Motore Windows nativo", "account" => "Account", "storage" => "Archiviazione", "data" => "Dati e ripristino", _ => "Generali" },
                settingsTab switch
                {
                    "runtime" => $"Windows {architecture} · Vulkan\nI giochi Windows usano direttamente le API del sistema. Non sono richiesti Wine, DXVK, D3DMetal o prefissi.",
                    "account" => "Gestisci il tuo account Steam nella pagina Amici.",
                    "storage" => "Dati di Ready: " + store.Root + "\nLe installazioni Steam rimangono nelle librerie Steam rilevate.",
                    "data" => "La libreria locale viene salvata con sostituzione atomica. I giochi importati e i loro salvataggi rimangono nelle cartelle originali.",
                    _ => "Ready per Windows\nF11: schermo intero · Ctrl+F: cerca · Tab e frecce: navigazione · Invio: apri"
                }, Field: settingsTab == "storage" ? input : null, FieldLabel: "Cartella predefinita per i nuovi giochi", Actions: settingsTab == "account" ? [new("nav:friends", "Steam")] : settingsTab == "storage" ? [new("download:storage", "Salva cartella")] : null, Tabs: tabs, SelectedTab: "settings:" + settingsTab),
            Destination.Import => page,
            _ => null
        };
    }
    private async Task Browse(string directory)
    {
        int epoch = ++browserEpoch; shell.Error = null; browserOffset = 0;
        page = new("Libreria", "Importa un gioco Windows", "Lettura della cartella…", directory, "Percorso cartella o eseguibile"); Invalidate();
        try
        {
            var entries = await Task.Run(() => Directory.EnumerateFileSystemEntries(directory).Where(p => Directory.Exists(p) || p.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
                .OrderBy(p => !Directory.Exists(p)).ThenBy(p => Path.GetFileName(p), StringComparer.CurrentCultureIgnoreCase).ToList());
            if (epoch != browserEpoch || closing || shell.Page != Destination.Import) return;
            browserDirectory = Path.GetFullPath(directory); browserEntries = entries; input = browserDirectory; UpdateBrowserPage();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        { if (epoch == browserEpoch && !closing) { browserEntries = []; shell.Error = e.Message; input = directory; UpdateBrowserPage(); } }
        if (!closing) Invalidate();
    }
    private void UpdateBrowserPage()
    {
        page = new("Libreria", "Importa un gioco Windows", "Seleziona una cartella o un eseguibile. Puoi anche inserire il percorso completo.", input, "Percorso cartella o eseguibile",
            [new("browser:open", "Apri percorso"), new("browser:up", "Cartella superiore"), new("browser:drives", "Unità")],
            browserEntries.Skip(browserOffset).Take(16).Select((p, i) => new PageRow("browser:item:" + (i + browserOffset), Path.GetFileName(p).Length == 0 ? p : Path.GetFileName(p), Directory.Exists(p) ? "Cartella" : "Eseguibile Windows")).ToArray());
    }
    private async Task Act(string action)
    {
        try
        {
            if (action == "toolbar:friends") action = "nav:friends";
            if (action == "empty:import") action = "nav:import";
            if (action == "field" || action.StartsWith("field:", StringComparison.Ordinal)) { shell.Focus = action; return; }
            shell.Error = null;
            if (await DownloadAction(action)) { Invalidate(); return; }
            if (await SteamAction(action)) { Invalidate(); return; }
            if (action.StartsWith("nav:", StringComparison.Ordinal))
                Navigate(action[4..] switch { "library" => Destination.Library, "friends" => Destination.Friends, "downloads" => Destination.Downloads, "settings" => Destination.Settings, "profiles" => Destination.Profiles, "import" => Destination.Import, _ => Destination.Library });
            else if (action.StartsWith("game:", StringComparison.Ordinal) && action != "game:play")
            { selectedGame = shell.Games.FirstOrDefault(g => g.Id == action[5..]); Navigate(Destination.Game); }
            else if (action.StartsWith("settings:", StringComparison.Ordinal)) { settingsTab = action[9..]; if (settingsTab == "storage") input = DownloadRoot; shell.ClearInteraction(); UpdatePage(); }
            else if (action == "profile:create") { var updated = library.AddProfile(input); store.Save(updated); library = updated; input = ""; await SwitchSteamProfile(); UpdateCatalog(); UpdatePage(); }
            else if (action.StartsWith("profile:", StringComparison.Ordinal))
            { var updated = library with { ActiveProfile = library.Profiles.First(p => p.Id == action[8..]).Id }; store.Save(updated); library = updated; await SwitchSteamProfile(); UpdateCatalog(); UpdatePage(); }
            else if (action == "search:apply") { shell.SetCatalog(library.ActiveGames.Concat(CurrentSteamGames()), input.Trim()); Navigate(Destination.Library); }
            else if (action == "browser:open") { if (File.Exists(input)) Import(input); else await Browse(input); }
            else if (action == "browser:up") await Browse(Directory.GetParent(browserDirectory)?.FullName ?? browserDirectory);
            else if (action == "browser:drives") { browserEntries = DriveInfo.GetDrives().Select(d => d.RootDirectory.FullName).ToList(); browserOffset = 0; UpdateBrowserPage(); }
            else if (action.StartsWith("browser:item:", StringComparison.Ordinal))
            { var path = browserEntries[int.Parse(action[13..])]; if (Directory.Exists(path)) await Browse(path); else Import(path); }
            else if (action == "game:play") await Play();
        }
        catch (Exception e) when (e is IOException or InvalidDataException or ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception or UnauthorizedAccessException)
        { shell.Error = e.Message; }
        Invalidate();
    }
    private void Import(string executable)
    { var updated = library.Import(executable); store.Save(updated); library = updated; UpdateCatalog(); Navigate(Destination.Library); }
    private async Task Play()
    {
        if (selectedGame is null || session is not null) return;
        var ownedSession = NativeGameSession.Start(selectedGame, dataRoot: store.Root); session = ownedSession;
        suspended = true; clock.Stop(); shell.ClearInteraction(); painter.ReleaseArtwork(); canvas?.ReleaseCanvas(); Hide();
        try { await ownedSession.WaitAsync(); }
        catch (ObjectDisposedException) when (closing) { }
        finally
        {
            ownedSession.Dispose(); session = null;
            if (!closing) { suspended = false; Navigate(Destination.Library); Show(); Activate(); clock.Start(); Invalidate(); }
        }
    }
    protected override void OnFormClosing(FormClosingEventArgs e)
    { closing = true; browserEpoch++; clock.Stop(); session?.Dispose(); steam?.CancelAuthentication(); _ = StopSteam(); if (downloads is not null) _ = downloads.DisposeAsync(); ClearSteamInputs(); base.OnFormClosing(e); }
    protected override void Dispose(bool disposing)
    {
        if (disposing) { clock.Dispose(); session?.Dispose(); painter.Dispose(); canvas?.Dispose(); canvas = null; }
        base.Dispose(disposing);
    }

    internal async Task ExerciseAsync(string fixture, string report)
    {
        void Require(bool value, string label) { if (!value) throw new InvalidOperationException(label); }
        List<string> checks = [];
        Require(!InvokeRequired && Visible && canvas is not null, "Window did not enter its WinForms event loop");
        Navigate(Destination.Profiles); shell.Focus = "field";
        foreach (char c in "Prova Windows") OnKeyPress(new KeyPressEventArgs(c));
        Require(page?.Field == "Prova Windows", "Typed profile name is not visible in canvas");
        await Act("profile:create"); Require(library.Profiles.Any(p => p.Name == "Prova Windows"), "Profile create failed");
        checks.Add("Real form keypress editing and persistent profile creation");
        Navigate(Destination.Import); await Browse(Path.GetDirectoryName(fixture)!); shell.Focus = "field"; input = "";
        foreach (char c in fixture) OnKeyPress(new KeyPressEventArgs(c));
        Require(page?.Field == fixture, "Internal browser does not update typed path");
        await Act("browser:open"); Require(shell.Page == Destination.Library && shell.Games.Count == 1, "PE import did not return to the library");
        checks.Add("Internal file browser, explicit path editing, PE import and library return");
        var game = shell.Games[0]; await Act("game:" + game.Id);
        Require(shell.Page == Destination.Game && page?.Heading == game.Title, "Game detail navigation failed");
        await Act("game:play"); Require(Visible && shell.Page == Destination.Library && session is null && !suspended, "Owned native process did not return to the actual library window");
        checks.Add("Production native launch, UI suspension and library reconstruction after fixture exit");
        await Act("game:" + game.Id); OnKeyDown(new KeyEventArgs(Keys.Escape)); Require(shell.Page == Destination.Library, "Escape did not restore library");
        OnKeyDown(new KeyEventArgs(Keys.Control | Keys.F)); input = "no-such-title"; UpdatePage(); await Act("search:apply");
        Require(shell.Page == Destination.Library && shell.Games.Count == 0, "Search did not filter library");
        OnKeyDown(new KeyEventArgs(Keys.Control | Keys.F)); input = ""; UpdatePage(); await Act("search:apply");
        Require(shell.Games.Count == 1, "Clearing search did not restore game");
        checks.Add("Game detail, Escape, Ctrl+F and clearing search through production handlers");
        foreach (var tab in new[] { "general", "account", "storage", "runtime", "data" })
        { await Act("nav:settings"); await Act("settings:" + tab); Require(page?.SelectedTab == "settings:" + tab, "Settings tab failed"); }
        checks.Add("All five Windows settings sections");
        Navigate(Destination.Library); Refresh();
        using (var raster = painter.Draw(shell, page, ClientSize.Width, ClientSize.Height, ScaleFactor))
        using (var image = canvas!.Readback(raster)) image.Save(Path.ChangeExtension(report, ".png"), System.Drawing.Imaging.ImageFormat.Png);
        int frames = canvas!.Submitted; await Task.Delay(120);
        Require(canvas.Submitted == frames, "Idle window submitted unnecessary GPU work");
        checks.Add("Actual form Vulkan readback and idle window submits no frames");
        var saved = store.Load(); Require(saved.Profiles.Count == 2 && saved.ActiveGames.Count() == 1, "Profile/library persistence failed");
        File.WriteAllText(report, System.Text.Json.JsonSerializer.Serialize(new { schema = 1, passed = true, checks,
            architecture = RuntimeInformation.ProcessArchitecture.ToString(), scope = "Owned test form and synthetic fixture import; no Steam account, physical input or game injection." },
            new System.Text.Json.JsonSerializerOptions { WriteIndented = true }));
    }
}
