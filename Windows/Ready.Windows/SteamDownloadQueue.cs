// SPDX-License-Identifier: GPL-3.0-only
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using Ready.Windows.Core;

namespace Ready.Windows;

internal sealed class SteamDownloadQueue : IAsyncDisposable
{
    private readonly string dataRoot, engine, root;
    private readonly SteamCredentialStore vault;
    private readonly bool fixture;
    private readonly object sync = new();
    private readonly Dictionary<string, Task> running = [];
    private readonly Dictionary<string, OwnedChild> children = [];
    private readonly SemaphoreSlim worker = new(1, 1);
    private bool disposed;
    private static readonly JsonSerializerOptions Json = new() { Converters = { new JsonStringEnumConverter() } };
    public event Action<SteamDownloadJob>? Changed;
    public SteamDownloadQueue(string dataRoot, string engine, SteamCredentialStore vault, bool fixture = false)
    { this.dataRoot = InstallationLease.Canonical(dataRoot); this.engine = engine; this.vault = vault; this.fixture = fixture; root = Path.Combine(this.dataRoot, "Downloads"); Directory.CreateDirectory(root); }
    private string FileName(string profile, string id)
    {
        var folder = Path.Combine(root, Guid.ParseExact(profile, "D").ToString("D")); Directory.CreateDirectory(folder);
        if ((File.GetAttributes(folder) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("download_state_alias");
        return Path.Combine(folder, Guid.ParseExact(id, "D").ToString("D") + ".json");
    }
    private SteamDownloadJob Read(string profile, string id)
    {
        string path = FileName(profile, id);
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0 || new FileInfo(path).Length > 1024 * 1024) throw new InvalidDataException("download_state_invalid");
        var job = JsonSerializer.Deserialize<SteamDownloadJob>(File.ReadAllBytes(path), Json) ?? throw new InvalidDataException("download_state_invalid");
        if (job.Schema != 1 || job.Profile != profile || job.Id != id || job.AppID != job.Plan.AppID) throw new InvalidDataException("download_state_invalid");
        job.Plan.Validate(); return job;
    }
    private SteamDownloadJob Change(string profile, string id, Func<SteamDownloadJob, SteamDownloadJob> update)
    {
        string path = FileName(profile, id); SteamDownloadJob value;
        using (InstallationLease.Exclusive(path + ".meta.lock"))
        {
            var old = Read(profile, id); value = update(old) with { Revision = old.Revision + 1, UpdatedAt = DateTimeOffset.UtcNow };
            Write(path, value);
        }
        Changed?.Invoke(value); return value;
    }
    private static void Write(string path, SteamDownloadJob job)
    {
        // Serialize enum names, but never credentials, process IDs or engine logs.
        InstallationLease.Atomic(path, JsonSerializer.SerializeToElement(job, Json));
    }
    public SteamDownloadJob Enqueue(string profile, string title, string target, SteamInstallPlan plan)
    {
        ObjectDisposedException.ThrowIf(disposed, this); plan.Validate(fresh: true); target = ValidateTarget(target);
        string id = Guid.NewGuid().ToString("D"), path = FileName(profile, id);
        using (var lease = InstallationLease.Acquire(dataRoot, target, true))
        {
            PrepareContent(target, plan.AppID); InstallationLease.ValidateTree(target);
        }
        uint login;
        using (InstallationLease.Exclusive(Path.Combine(root, "loginids.lock")))
        {
            string ledger = Path.Combine(root, "loginids.json");
            uint next = File.Exists(ledger) ? JsonSerializer.Deserialize<uint>(File.ReadAllText(ledger)) : 1;
            if (next is 0 or > 0x0fffffff) throw new InvalidDataException("download_loginid_limit");
            login = 0xD0000000 | next; InstallationLease.Atomic(ledger, next + 1);
        }
        var now = DateTimeOffset.UtcNow;
        var job = new SteamDownloadJob(1, id, profile, plan.AppID, title.Length > 512 ? title[..512] : title, target, plan, login,
            DownloadState.Queued, DownloadDesire.Run, null, null, 0, null, 0, 1, now, now);
        Write(path, job); Changed?.Invoke(job); return job;
    }
    private string ValidateTarget(string target)
    {
        target = InstallationLease.Canonical(target);
        foreach (string part in new[] { "Credentials", "Profiles", "Downloads", "InstallLocks", "Runtimes", "Sessions" })
            if (InstallationLease.Overlaps(target, Path.Combine(dataRoot, part))) throw new InvalidDataException("installation_state_overlap");
        return target;
    }
    private static void PrepareContent(string target, uint app)
    {
        string marker = Path.Combine(target, ".ready-content-owner.json");
        if (File.Exists(marker))
        {
            using var document = JsonDocument.Parse(File.ReadAllBytes(marker));
            if (document.RootElement.GetProperty("schema").GetInt32() != 1 || document.RootElement.GetProperty("appID").GetUInt32() != app) throw new InvalidDataException("installation_owned_by_other_game");
        }
        else
        {
            if (Directory.EnumerateFileSystemEntries(target).Any()) throw new InvalidDataException("installation_folder_not_empty");
            InstallationLease.Atomic(marker, new { schema = 1, appID = app });
        }
    }
    public IReadOnlyList<SteamDownloadJob> List(string profile)
    {
        string folder = Path.GetDirectoryName(FileName(profile, Guid.Empty.ToString("D")))!; var result = new List<SteamDownloadJob>();
        foreach (string path in Directory.EnumerateFiles(folder, "*.json"))
        {
            string id = Path.GetFileNameWithoutExtension(path); var value = Read(profile, id);
            if (SteamDownloadJob.Active(value.State))
            {
                try
                {
                    using var proof = new FileStream(path + ".run.lock", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
                    value = Change(profile, id, j => j with { State = j.Desired == DownloadDesire.Paused ? DownloadState.Paused : j.Desired == DownloadDesire.Cancelled ? DownloadState.Cancelled : DownloadState.Interrupted, Error = "worker_interrupted" });
                }
                catch (IOException) { } // A current kernel handle proves a live worker, independent of metadata age.
            }
            result.Add(value);
        }
        return result.OrderByDescending(j => j.CreatedAt).ToArray();
    }
    public IReadOnlyDictionary<uint, string> Installed()
    {
        string path = Path.Combine(dataRoot, "installed-windows-games.json");
        var entries = File.Exists(path) ? JsonSerializer.Deserialize<Dictionary<uint, string>>(File.ReadAllBytes(path)) ?? throw new InvalidDataException("installation_registry_invalid") : [];
        return entries.Where(p => p.Key is > 0 and < uint.MaxValue && Directory.Exists(p.Value)).ToDictionary(p => p.Key, p => p.Value);
    }
    private void RegisterInstalled(uint app, string directory)
    {
        using var gate = InstallationLease.Exclusive(Path.Combine(dataRoot, "installed-windows-games.lock"));
        var values = Installed().ToDictionary(); values[app] = directory;
        InstallationLease.Atomic(Path.Combine(dataRoot, "installed-windows-games.json"), values);
    }
    public SteamDownloadJob Control(string profile, string id, DownloadDesire desire)
    {
        return Change(profile, id, job =>
        {
            if (job.State == DownloadState.Completed) throw new InvalidOperationException("download_already_completed");
            if (desire == DownloadDesire.Run && SteamDownloadJob.Active(job.State)) throw new InvalidOperationException("download_busy");
            return job with { Desired = desire, State = SteamDownloadJob.Active(job.State) ? job.State : desire == DownloadDesire.Run ? DownloadState.Queued : desire == DownloadDesire.Paused ? DownloadState.Paused : DownloadState.Cancelled, Error = null };
        });
    }
    public Task StartAsync(string profile, string id)
    {
        lock (sync)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (running.TryGetValue(id, out var existing)) return existing;
            var task = Task.Run(async () => { try { await Run(profile, id); } finally { lock (sync) running.Remove(id); } });
            running[id] = task; return task;
        }
    }
    public async Task PauseProfileAsync(string profile)
    {
        var jobs = List(profile).Where(j => SteamDownloadJob.Active(j.State) || j.State == DownloadState.Queued).ToArray();
        var active = jobs.Where(j => SteamDownloadJob.Active(j.State)).Select(j => j.Id).ToHashSet();
        foreach (var job in jobs) Control(profile, job.Id, DownloadDesire.Paused);
        Task[] tasks; lock (sync) tasks = active.Where(running.ContainsKey).Select(id => running[id]).ToArray();
        await Task.WhenAll(tasks).WaitAsync(TimeSpan.FromSeconds(8));
    }
    private async Task Run(string profile, string id)
    {
        await worker.WaitAsync().ConfigureAwait(false);
        try
        {
            if (disposed) { Change(profile, id, j => j with { State = DownloadState.Paused, Desired = DownloadDesire.Paused }); return; }
            using var runLock = new FileStream(FileName(profile, id) + ".run.lock", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            var job = Read(profile, id); if (job.Desired != DownloadDesire.Run || job.State == DownloadState.Completed) return;
            try
            {
                job = Change(profile, id, j => j with { State = DownloadState.Preparing, Error = null, Attempts = j.Attempts + 1, CompletedBytes = null, TotalBytes = null, NetworkBytes = 0 });
                string target = ValidateTarget(job.Directory);
                using var lease = InstallationLease.Acquire(dataRoot, target, true); PrepareContent(target, job.AppID); InstallationLease.ValidateTree(target);
                // Initial admission only; PICS payload totals do not measure staging/peak space or reserve the volume.
                var drive = new DriveInfo(Path.GetPathRoot(target)!);
                if ((ulong)drive.AvailableFreeSpace < job.Plan.InstalledBytes) throw new IOException("disk_full");
                var credential = vault.Read(profile) ?? throw new InvalidOperationException("authentication_required");
                if (!fixture)
                {
                    using var marker = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(Path.GetDirectoryName(engine)!, ".ready-download-protocol.json")));
                    if (marker.RootElement.GetProperty("protocol").GetString() != "READY_DOWNLOAD_V1") throw new InvalidDataException("download_engine_protocol_missing");
                }
                using var child = OwnedChild.Start(engine, job.Plan.Arguments(target, job.LoginID), target,
                    new Dictionary<string, string> { ["READY_TOKEN_STDIN"] = "1", ["READY_DOWNLOAD_PROGRESS_JSON"] = "1" }, [.. lease.Handles, runLock.SafeFileHandle]);
                lock (sync) children[id] = child;
                var discarded = Task.Run(async () => { char[] bytes = new char[4096]; try { while (await child.Error.ReadAsync(bytes) != 0) Array.Clear(bytes); } catch (IOException) { } });
                try
                {
                    byte[] frame = JsonSerializer.SerializeToUtf8Bytes(new { username = credential.Username, refresh_token = credential.RefreshToken }); credential = null;
                    try { await child.Input.WriteAsync(frame); await child.Input.WriteAsync(new byte[] { 10 }); await child.Input.FlushAsync(); }
                    finally { CryptographicOperations.ZeroMemory(frame); child.Input.Close(); }
                    Change(profile, id, j => j with { State = DownloadState.Downloading });
                    DownloadProgress? complete = null; string? engineError = null; ulong lastDone = 0, lastNetwork = 0; bool planSeen = false;
                    Task<string?> line = ReadLine(child.Output); bool eof = false;
                    while (!eof || !child.Exited)
                    {
                        var current = Read(profile, id);
                        if (current.Desired != DownloadDesire.Run) { child.Stop(); using var stop = new CancellationTokenSource(TimeSpan.FromSeconds(5)); await child.WaitAsync(stop.Token); break; }
                        if (eof) { await Task.Delay(50); continue; }
                        if (await Task.WhenAny(line, Task.Delay(50)) != line) continue;
                        string? text = await line; if (text is null) { eof = true; continue; }
                        line = ReadLine(child.Output); var progress = DownloadProgress.Parse(text); if (progress is null) continue;
                        if (progress.Kind == "error") { engineError = progress.Error; continue; }
                        if (complete is not null) throw new InvalidDataException("engine_protocol_error");
                        if (progress.Kind == "plan") { if (planSeen) throw new InvalidDataException("engine_protocol_error"); planSeen = true; }
                        if (!planSeen || progress.Completed < lastDone || progress.Network < lastNetwork) throw new InvalidDataException("engine_protocol_error");
                        lastDone = progress.Completed; lastNetwork = progress.Network;
                        if (progress.Kind == "completed") complete = progress;
                        Change(profile, id, j => j with { State = progress.Kind == "completed" ? DownloadState.Verifying : DownloadState.Downloading, TotalBytes = progress.Total, CompletedBytes = progress.Completed, NetworkBytes = progress.Network });
                    }
                    using var finish = new CancellationTokenSource(TimeSpan.FromSeconds(5)); await child.WaitAsync(finish.Token); await discarded;
                    var final = Read(profile, id);
                    if (final.Desired != DownloadDesire.Run) { Change(profile, id, j => j with { State = j.Desired == DownloadDesire.Paused ? DownloadState.Paused : DownloadState.Cancelled }); return; }
                    if (child.ExitCode != 0) throw new DownloadFailure(engineError ?? "download_failed");
                    if (complete is null) throw new DownloadFailure("engine_protocol_required");
                    InstallationLease.ValidateTree(target); SteamDepotReceipt.Verify(target, job.Plan, complete);
                    RegisterInstalled(job.AppID, target);
                    Change(profile, id, j => j with { State = j.Desired == DownloadDesire.Run ? DownloadState.Completed : j.Desired == DownloadDesire.Paused ? DownloadState.Paused : DownloadState.Cancelled, CompletedBytes = complete.Total, TotalBytes = complete.Total, Error = null });
                }
                finally { child.Stop(); lock (sync) children.Remove(id); }
            }
            catch (Exception error) when (error is DownloadFailure or IOException or InvalidDataException or InvalidOperationException or System.Security.Cryptography.CryptographicException or System.ComponentModel.Win32Exception or JsonException or OperationCanceledException or UnauthorizedAccessException)
            {
                string code = error is DownloadFailure failure ? failure.Code : error.Message is "installation_busy" or "disk_full" or "authentication_required" ? error.Message
                    : error is InvalidDataException ? "integrity_error" : "download_failed";
                Change(profile, id, j => j with { State = j.Desired != DownloadDesire.Run ? j.Desired == DownloadDesire.Paused ? DownloadState.Paused : DownloadState.Cancelled : disposed ? DownloadState.Interrupted : code is "network_error" or "network_timeout" ? DownloadState.RetryWait : DownloadState.Failed, Error = disposed ? "worker_interrupted" : code });
            }
        }
        finally { worker.Release(); }
    }
    private static async Task<string?> ReadLine(StreamReader reader)
    {
        var text = new System.Text.StringBuilder(); char[] one = new char[1]; bool longLine = false;
        while (await reader.ReadAsync(one) != 0)
        {
            if (one[0] == '\n') { if (longLine && text.ToString().StartsWith(DownloadProgress.Prefix, StringComparison.Ordinal)) throw new InvalidDataException("engine_protocol_error"); return longLine ? "" : text.ToString().TrimEnd('\r'); }
            if (text.Length < 65537) text.Append(one[0]); else longLine = true;
        }
        if (text.Length > 0) throw new InvalidDataException("engine_protocol_truncated"); return null;
    }
    public async ValueTask DisposeAsync()
    {
        Task[] tasks;
        lock (sync)
        {
            if (disposed) return; disposed = true;
            foreach (var child in children.Values) child.Stop();
            tasks = running.Values.ToArray();
        }
        try { await Task.WhenAll(tasks).WaitAsync(TimeSpan.FromSeconds(8)); } catch (TimeoutException) { }
    }
    private sealed class DownloadFailure(string code) : Exception { public string Code { get; } = code; }
}
