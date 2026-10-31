// SPDX-License-Identifier: GPL-3.0-only
using System.Security.Cryptography;
using System.Text.Json;
using Ready.Windows.Core;

namespace Ready.Windows;

internal static class DownloadChecks
{
    public static async Task<int> Actual(string executable, string report)
    {
        string root = Path.Combine(Path.GetTempPath(), "ready-depot-startup-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
        try
        {
            using var child = OwnedChild.Start(executable, ["--version"], root, new Dictionary<string, string>(), []); child.Input.Close();
            var output = child.Output.ReadToEndAsync(); var errors = child.Error.ReadToEndAsync();
            using var budget = new CancellationTokenSource(TimeSpan.FromSeconds(15)); await child.WaitAsync(budget.Token);
            string text = await output; _ = await errors;
            if (child.ExitCode != 0 || !text.Contains("3.4.0")) throw new InvalidOperationException("Pinned downloader version startup failed");
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(report))!);
            File.WriteAllText(report, JsonSerializer.Serialize(new { passed = true, checks = new[] { "Actual pinned source-built downloader starts under production private-pipe/job launcher", "Version command exits without credentials or download request" }, assemblySHA256 = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(Path.ChangeExtension(executable, ".dll")))).ToLowerInvariant(), scope = "Actual executable version/startup only; no account, network denial, CDN or genuine installation." }, new JsonSerializerOptions { WriteIndented = true }));
            return 0;
        }
        finally { Directory.Delete(root, true); }
    }
    public static SteamInstallPlan Plan(uint app)
    {
        SteamDepot[] depots = [new(1, app, 42, 4, 8)]; string arch = "64";
        string hash = Convert.ToHexString(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(new { AppID = app, Platform = "windows", Branch = "public", Language = "english", Architecture = arch, depots }))).ToLowerInvariant();
        return new(app, arch, 4, 8, depots, hash, DateTimeOffset.UtcNow);
    }
    public static async Task<int> Run(string fixture, string report)
    {
        string root = Path.Combine(Path.GetTempPath(), "ready-download-check-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
        List<string> checks = [];
        void Check(bool condition, string label) { if (!condition) throw new InvalidOperationException(label); checks.Add(label); }
        bool Reject(Action action) { try { action(); return false; } catch (Exception e) when (e is IOException or InvalidDataException or InvalidOperationException) { return true; } }
        async Task Until(Func<bool> predicate) { using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15)); while (!predicate()) await Task.Delay(20, timeout.Token); }
        try
        {
            string profile = Guid.NewGuid().ToString("D"), other = Guid.NewGuid().ToString("D"); var vault = new SteamCredentialStore(root); vault.Write(profile, new("fixture_account", "fixture-private-refresh-token"));
            string path = Path.Combine(root, "game"); Directory.CreateDirectory(path); Directory.CreateDirectory(Path.Combine(path, "sub"));
            using (var read = InstallationLease.Acquire(root, path, false))
            {
                using var parallel = InstallationLease.Acquire(root, path, false);
                Check(Reject(() => InstallationLease.Acquire(root, Path.Combine(path, "sub"), true).Dispose()), "Parent game reader blocks child installation writer");
                using var sibling = InstallationLease.Acquire(root, Path.Combine(root, "sibling"), true);
                Check(Reject(() => InstallationLease.Acquire(root, path, true).Dispose()), "Readers coexist while same-root writer is excluded");
            }
            using (var write = InstallationLease.Acquire(root, path, true))
            {
                using var child = OwnedChild.Start(fixture, ["lease-keeper"], path, new Dictionary<string, string>(), write.Handles);
                Check(await child.Output.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(8)) == "lease-ready", "Owned child starts with private standard pipes and atomic job admission");
                write.Dispose(); Check(Reject(() => InstallationLease.Acquire(root, path, true).Dispose()), "Inherited kernel lease survives parent handle release");
                child.Stop(); using var stop = new CancellationTokenSource(TimeSpan.FromSeconds(5)); await child.WaitAsync(stop.Token);
            }
            using (InstallationLease.Acquire(root, path, true)) { }
            Check(true, "Writer lease becomes available after owned child exit");
            string readerMarker = Path.Combine(root, "native-reader.txt");
            var game = new Game("lease-fixture", "Owned game reader", GameSource.Local, path, fixture);
            using (var session = NativeGameSession.Start(game, ["child", readerMarker], root))
            {
                await Until(() => File.Exists(readerMarker));
                Check(Reject(() => InstallationLease.Acquire(root, path, true).Dispose()), "Production native game session holds a reader lease while its process is alive");
                session.Stop(); using var stop = new CancellationTokenSource(TimeSpan.FromSeconds(5)); await session.WaitAsync(stop.Token);
            }
            await using var queue = new SteamDownloadQueue(root, fixture, vault, fixture: true);
            var normal = queue.Enqueue(profile, "Synthetic Windows game", Path.Combine(root, "normal"), Plan(480)); await queue.StartAsync(profile, normal.Id);
            Check(queue.List(profile).Single(j => j.Id == normal.Id).State == DownloadState.Completed, "Exit zero plus exact cached manifests and checksums completes installation");
            Check(queue.Installed().GetValueOrDefault(480u) == normal.Directory, "Verified shared content registration is distinct from per-profile account/queue ownership");
            await using (var restored = new SteamDownloadQueue(root, fixture, vault, fixture: true))
                Check(restored.List(profile).Single(j => j.Id == normal.Id).State == DownloadState.Completed && restored.List(other).Count == 0, "Durable queue survives controller recreation and isolates profiles");
            var slow = queue.Enqueue(profile, "Pause fixture", Path.Combine(root, "slow"), Plan(481)); var running = queue.StartAsync(profile, slow.Id);
            await Until(() => queue.List(profile).Single(j => j.Id == slow.Id).CompletedBytes >= 2);
            await using (var observer = new SteamDownloadQueue(root, fixture, vault, fixture: true))
                Check(SteamDownloadJob.Active(observer.List(profile).Single(j => j.Id == slow.Id).State), "Live kernel worker lock prevents false interrupted-state recovery");
            queue.Control(profile, slow.Id, DownloadDesire.Paused); await running;
            var paused = queue.List(profile).Single(j => j.Id == slow.Id);
            Check(paused.State == DownloadState.Paused && File.Exists(Path.Combine(slow.Directory, "fixture.bin")), "Pause stops only owned worker and retains partial files");
            queue.Control(profile, slow.Id, DownloadDesire.Run); await queue.StartAsync(profile, slow.Id);
            Check(queue.List(profile).Single(j => j.Id == slow.Id).State == DownloadState.Completed, "Resume reuses retained files and the exact pinned manifest selection");
            var cancel = queue.Enqueue(profile, "Cancel fixture", Path.Combine(root, "cancel"), Plan(481)); var cancelling = queue.StartAsync(profile, cancel.Id);
            await Until(() => queue.List(profile).Single(j => j.Id == cancel.Id).CompletedBytes >= 2); queue.Control(profile, cancel.Id, DownloadDesire.Cancelled); await cancelling;
            Check(queue.List(profile).Single(j => j.Id == cancel.Id).State == DownloadState.Cancelled && File.Exists(Path.Combine(cancel.Directory, "fixture.bin")), "Cancel preserves partial game files and does not report completion");
            foreach (uint app in new uint[] { 490, 491, 492, 494 })
            {
                var bad = queue.Enqueue(profile, "Negative fixture", Path.Combine(root, "negative-" + app), Plan(app)); await queue.StartAsync(profile, bad.Id);
                var final = queue.List(profile).Single(j => j.Id == bad.Id);
                Check(final.State == (app == 494 ? DownloadState.RetryWait : DownloadState.Failed), "Reject incomplete/cache/selection/network result " + app);
            }
            var noLogin = queue.Enqueue(other, "No login", Path.Combine(root, "no-login"), Plan(480)); await queue.StartAsync(other, noLogin.Id);
            Check(queue.List(other).Single().Error == "authentication_required" && !File.Exists(Path.Combine(noLogin.Directory, "fixture.bin")), "Missing profile credential never starts anonymous download");
            Check(Reject(() => queue.Enqueue(profile, "Reserved", Path.Combine(root, "Credentials", "game"), Plan(480))), "Game installation cannot overlap protected application state");
            string existing = Path.Combine(root, "user-game"); Directory.CreateDirectory(existing); File.WriteAllText(Path.Combine(existing, "save.txt"), "keep original");
            Check(Reject(() => queue.Enqueue(profile, "Unknown folder", existing, Plan(480))) && File.ReadAllText(Path.Combine(existing, "save.txt")) == "keep original", "Unknown existing content is preserved rather than adopted or overwritten");
            Check(Reject(() => (Plan(480) with { InstalledBytes = 99 }).Validate()), "Tampered verified payload totals are rejected");
            Check(!Directory.EnumerateFiles(Path.Combine(root, "Downloads"), "*.json", SearchOption.AllDirectories).Any(p => File.ReadAllText(p).Contains("fixture-private-refresh-token")), "Queue metadata never persists credentials or raw helper output");
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(report))!);
            File.WriteAllText(report, JsonSerializer.Serialize(new { passed = true, checks, architecture = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString(), scope = "Real Windows handles/jobs and synthetic downloader bytes only; no Steam account, CDN, commercial game or genuine installation." }, new JsonSerializerOptions { WriteIndented = true }));
            return 0;
        }
        catch (Exception error)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(report))!);
            File.WriteAllText(report, JsonSerializer.Serialize(new { passed = false, checks, error = error.GetType().Name, message = error.Message, location = error.StackTrace })); return 1;
        }
        finally { Directory.Delete(root, true); }
    }
}
