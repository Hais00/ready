// SPDX-License-Identifier: GPL-3.0-only
using Ready.Windows.Core;
using System.Text.Json;

namespace Ready.Windows;

internal sealed partial class ReadyWindow
{
    private SteamDownloadQueue? downloads;
    private SteamInstallPlan? installPlan;
    private string DownloadRoot
    {
        get
        {
            string setting = Path.Combine(store.Root, "storage-windows.json");
            return File.Exists(setting) ? JsonSerializer.Deserialize<string>(File.ReadAllText(setting)) ?? throw new InvalidDataException("storage_invalid") : Path.Combine(store.Root, "Games");
        }
    }
    private void EnsureDownloads(string? fixture = null)
    {
        if (downloads is not null) return;
        steamVault ??= new SteamCredentialStore(store.Root);
        downloads = new(store.Root, fixture ?? Path.Combine(AppContext.BaseDirectory, "DepotDownloader", "DepotDownloader.exe"), steamVault, fixture is not null);
        downloads.Changed += job =>
        {
            if (closing || !IsHandleCreated) return;
            try
            {
                BeginInvoke(() =>
                {
                    if (closing || job.Profile != library.ActiveProfile) return;
                    if (job.State == DownloadState.Completed) UpdateCatalog();
                    if (shell.Page is Destination.Downloads or Destination.Game) { UpdatePage(); Invalidate(); }
                });
            }
            catch (InvalidOperationException) when (closing || !IsHandleCreated) { }
        };
    }
    private static string Bytes(ulong? value) => value is null ? "—" : value >= 1073741824 ? $"{value / 1073741824.0:0.0} GB" : value >= 1048576 ? $"{value / 1048576.0:0.0} MB" : $"{value} B";
    private CanvasPage InstallPage() => new("Libreria", selectedGame?.Title ?? "Installa gioco",
        installPlan is null ? "Verifica del contenuto Steam…" : $"Download: {Bytes(installPlan.DownloadBytes)} · Installazione: {Bytes(installPlan.InstalledBytes)}\nSpazio temporaneo e picco di utilizzo non sono inclusi in queste dimensioni.",
        Field: input, FieldLabel: "Cartella di installazione", Actions: [new("download:start", "Installa", installPlan is not null), new("nav:library", "Indietro")]);
    private CanvasPage DownloadsPage()
    {
        EnsureDownloads(); var jobs = downloads!.List(library.ActiveProfile); List<PageAction> actions = [];
        foreach (var job in jobs.Where(j => j.State != DownloadState.Completed))
        {
            if (SteamDownloadJob.Active(job.State) || job.State == DownloadState.Queued) actions.Add(new("download:pause:" + job.Id, "Pausa · " + job.Title));
            else actions.Add(new("download:resume:" + job.Id, "Riprendi · " + job.Title));
            if (job.Desired != DownloadDesire.Cancelled) actions.Add(new("download:cancel:" + job.Id, "Annulla · " + job.Title));
        }
        string State(SteamDownloadJob j) => j.State switch
        { DownloadState.Queued => "In coda", DownloadState.Preparing => "Preparazione", DownloadState.Downloading => "Download", DownloadState.Verifying => "Verifica", DownloadState.Completed => "Completato", DownloadState.Paused => "In pausa", DownloadState.Cancelled => "Annullato", DownloadState.Interrupted => "Interrotto", DownloadState.RetryWait => "Connessione interrotta · riprova", _ => "Non completato" };
        return new("Download", jobs.Count == 0 ? "Nessun download in corso" : "Download Steam", "Pausa e annullamento conservano i file parziali per una successiva ripresa.",
            Rows: jobs.Select(j => new PageRow("download:show:" + j.Id, j.Title, $"{State(j)} · {Bytes(j.CompletedBytes)} / {Bytes(j.TotalBytes)} · Rete {Bytes(j.NetworkBytes)}")).ToArray(), Actions: actions, Offset: steamPageOffset);
    }
    private async Task<bool> DownloadAction(string action)
    {
        if (!action.StartsWith("download:", StringComparison.Ordinal)) return false;
        try
        {
            EnsureDownloads();
            if (action == "download:prepare")
            {
                if (selectedGame?.AppId is not { } app || steam?.State.State != "online") { shell.Error = "Accedi a Steam prima di installare un gioco."; return true; }
                installPlan = null; var game = selectedGame; Navigate(Destination.Install); input = Path.Combine(DownloadRoot, app.ToString()); UpdatePage(); Invalidate();
                var plan = await steam.InstallPlanAsync(app);
                if (shell.Page == Destination.Install && selectedGame == game) { installPlan = plan; UpdatePage(); }
            }
            else if (action == "download:start")
            {
                if (selectedGame is null || installPlan is null) return true;
                var job = downloads!.Enqueue(library.ActiveProfile, selectedGame.Title, input, installPlan); _ = downloads.StartAsync(job.Profile, job.Id);
                Navigate(Destination.Downloads);
            }
            else if (action == "download:storage")
            {
                string path = InstallationLease.Canonical(input);
                foreach (string part in new[] { "Credentials", "Profiles", "Downloads", "InstallLocks" }) if (InstallationLease.Overlaps(path, Path.Combine(store.Root, part))) throw new InvalidDataException("storage_overlap");
                InstallationLease.Atomic(Path.Combine(store.Root, "storage-windows.json"), path); shell.Error = null;
            }
            else
            {
                string[] parts = action.Split(':'); if (parts.Length != 3) return true;
                var job = downloads!.List(library.ActiveProfile).First(j => j.Id == parts[2]);
                if (parts[1] == "show") { selectedGame = CurrentSteamGames().FirstOrDefault(g => g.AppId == job.AppID); Navigate(Destination.Game); return true; }
                if (parts[1] == "resume") { downloads.Control(job.Profile, job.Id, DownloadDesire.Run); _ = downloads.StartAsync(job.Profile, job.Id); }
                else if (parts[1] is "pause" or "cancel") downloads.Control(job.Profile, job.Id, parts[1] == "pause" ? DownloadDesire.Paused : DownloadDesire.Cancelled);
                UpdatePage();
            }
        }
        catch (Exception error) when (error is IOException or InvalidDataException or InvalidOperationException or FormatException or JsonException or UnauthorizedAccessException)
        { shell.Error = error.Message == "installation_busy" ? "L’installazione è usata da un’altra sessione." : "Non è possibile preparare questo download. Controlla account, cartella e dati della versione Steam."; }
        return true;
    }
    internal async Task ExerciseDownloadsAsync(string fixture, string report)
    {
        var checks = new List<string>();
        void Check(bool condition, string label) { if (!condition) throw new InvalidOperationException(label); checks.Add(label); }
        async Task Until(Func<bool> condition) { using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15)); while (!condition()) await Task.Delay(10, timeout.Token); }
        steamEnabled = true; steamFixtureExecutable = fixture; await InitializeSteam(); await Task.Delay(50); EnsureDownloads(fixture);
        Navigate(Destination.Friends); steamFields["account"] = "fixture_account"; steamFields["password"] = "fixture_password";
        var login = Act("steam:password"); await Until(() => steam!.State.GuardChallenge is { Length: > 0 }); steamFields["guard"] = "A1B2C"; await Act("steam:guard"); await login;
        await Act("game:steam:480"); Check(page!.Actions!.Any(a => a.Id == "download:prepare"), "Uninstalled owned Windows game offers installation");
        await Act("download:prepare"); Check(shell.Page == Destination.Install && installPlan?.Depots.Single().ManifestID == 42 && page!.Field is not null, "Production detail requests verified plan and shows install folder/size preview");
        await Act("download:start"); Check(shell.Page == Destination.Downloads, "Install action enters actual downloads navigation page");
        await Until(() => downloads!.List(library.ActiveProfile).Single().State is DownloadState.Completed or DownloadState.Failed);
        var job = downloads!.List(library.ActiveProfile).Single(); Check(job.State == DownloadState.Completed, "UI owns native worker and commits only verified synthetic completion");
        await Act("download:show:" + job.Id); Check(selectedGame is { Installed: true, Source: GameSource.Steam }, "Verified completion projects installed game into the owned catalog");
        await Act("game:play"); Check(session is null && shell.Error is not null, "Downloaded Steam content still requires genuine game host; no direct-EXE bypass");
        Navigate(Destination.Downloads); Refresh();
        using (var raster = painter.Draw(shell, page, ClientSize.Width, ClientSize.Height, ScaleFactor))
        using (var image = canvas!.Readback(raster)) image.Save(Path.ChangeExtension(report, ".png"), System.Drawing.Imaging.ImageFormat.Png);
        await downloads.DisposeAsync(); await StopSteam();
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(report))!);
        File.WriteAllText(report, JsonSerializer.Serialize(new { passed = true, checks, architecture = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString(), scope = "Actual form/Vulkan download UI, verified synthetic plan and owned synthetic file worker only; no genuine account/CDN/game launch." }, new JsonSerializerOptions { WriteIndented = true }));
    }
}
