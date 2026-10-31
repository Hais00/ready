// SPDX-License-Identifier: GPL-3.0-only
using System.Diagnostics;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;

namespace Ready.Windows;

internal static class SteamClientChecks
{
    public static async Task<int> Actual(string executable, string report)
    {
        await using var service = new SteamServiceProcess(executable, Guid.NewGuid().ToString("D"));
        bool credential = false; service.CredentialReceived += _ => credential = true;
        var snapshot = await service.RequestAsync("snapshot");
        if (snapshot.GetProperty("state").GetString() != "offline" || snapshot.GetProperty("backendSessionReady").GetBoolean() || credential)
            throw new InvalidOperationException("Actual adapter snapshot is not offline");
        using var child = Process.GetProcessById(service.ProcessId); await service.DisposeAsync();
        if (!child.WaitForExit(5000)) throw new InvalidOperationException("Actual adapter did not shut down");
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(report))!);
        File.WriteAllText(report, JsonSerializer.Serialize(new { schema = 1, passed = true, checks = new[] { "Production C# supervisor binds actual SteamKit adapter snapshot", "Offline state does not claim a game backend", "No credential/authentication request", "Owned actual adapter exits on supervisor shutdown" },
            executableSHA256 = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(executable))).ToLowerInvariant(),
            scope = "Actual SteamKit adapter through the production C# supervisor without connect/authenticate requests. No account, network-denial or game launch claim." }, new JsonSerializerOptions { WriteIndented = true }));
        return 0;
    }
    public static async Task<int> Run(string fixture, string report)
    {
        const string secret = "fixture-private-refresh-token";
        string root = Path.Combine(Path.GetTempPath(), "ready-steam-client-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
        var checks = new List<string>();
        void Check(bool value, string label) { if (!value) throw new InvalidOperationException(label); checks.Add(label); }
        async Task Until(Func<bool> condition)
        { using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(8)); while (!condition()) await Task.Delay(5, timeout.Token); }
        string profile = Guid.NewGuid().ToString("D"), other = Guid.NewGuid().ToString("D");
        try
        {
            var vault = new SteamCredentialStore(root); var credential = new SteamCredential("fixture_account", secret);
            vault.Write(profile, credential); Check(vault.Read(profile)?.RefreshToken == secret && vault.Read(other) is null, "DPAPI current-user credential roundtrip and profile separation");
            string[] files = Directory.GetFiles(root, "*.dpapi", SearchOption.AllDirectories);
            Check(files.Length == 1 && !Encoding.UTF8.GetString(File.ReadAllBytes(files[0])).Contains(secret), "Only encrypted credential bytes persist");
            string otherFile = Path.Combine(Path.GetDirectoryName(files[0])!, other + ".steam.dpapi"); File.Copy(files[0], otherFile);
            bool rejected = false; try { vault.Read(other); } catch (CryptographicException) { rejected = true; }
            Check(rejected, "DPAPI purpose entropy rejects ciphertext copied to another profile"); File.Delete(otherFile);
            var acl = new DirectoryInfo(Path.Combine(root, "Credentials")).GetAccessControl();
            var allowed = new[] { WindowsIdentity.GetCurrent().User!.Value, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null).Value };
            Check(acl.AreAccessRulesProtected && acl.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().All(r => allowed.Contains(r.IdentityReference.Value)), "Credential directory DACL restricted to owner and SYSTEM");
            Check(!credential.ToString().Contains(secret), "Private credential diagnostics are redacted"); vault.Forget(profile);
            var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true };
            if (string.Equals(Path.GetFileNameWithoutExtension(Environment.ProcessPath), "dotnet", StringComparison.OrdinalIgnoreCase)) start.ArgumentList.Add(typeof(SteamClientChecks).Assembly.Location);
            foreach (string argument in new[] { "--steam-window-self-test", "--fixture", fixture, "--data-root", root, "--report", Path.Combine(root, "must-not-render.json") }) start.ArgumentList.Add(argument);
            using (var guarded = Process.Start(start)!)
            {
                if (!guarded.WaitForExit(5000)) { guarded.Kill(entireProcessTree: true); throw new InvalidOperationException("Nonempty form fixture root was not rejected"); }
                Check(guarded.ExitCode != 0 && !File.Exists(Path.Combine(root, "library-windows.json")), "Form fixture refuses an existing data root before loading profile credentials");
            }
            await using (var client = new SteamAccountClient(fixture, profile, vault))
            {
                int changes = 0; client.Changed += () => Interlocked.Increment(ref changes);
                await client.InitializeAsync(); Check(client.State.State == "offline", "Native process offline initialization without saved login");
                var flow = client.AuthenticateAsync(); await Until(() => client.State.QR is not null);
                Check(!client.State.ToString().Contains("s.team"), "QR/account state diagnostics are redacted");
                client.CancelAuthentication(); try { await flow; } catch (OperationCanceledException) { }
                await Task.Delay(100); Check(vault.Read(profile) is null && client.State.QR is null, "Late credential after cancellation is not persisted");
                flow = client.AuthenticateAsync("fixture_account", "fixture_password"); await Until(() => client.State.GuardChallenge is { Length: > 0 });
                await client.GuardAsync("A1B2C"); await flow;
                Check(client.State.State == "online" && vault.Read(profile)?.RefreshToken == secret, "Password/Guard request correlation and encrypted refresh storage");
                Check(client.State.Friends.Count == 1 && client.State.Games.Count == 1 && client.State.Games[0].AppId == 480 && !client.State.Games[0].Installed, "Authenticated catalog filters DLC/Mac-only content without faking installation");
                int previousChanges = changes; await client.PresenceAsync("Online"); await Task.Delay(50);
                Check(changes == previousChanges, "Unchanged service state does not invalidate the canvas");
                await client.OfflineAsync(); Check(vault.Read(profile)?.RefreshToken == secret, "Manual offline preserves saved refresh credential");
            }
            await using (var restored = new SteamAccountClient(fixture, profile, vault))
            {
                await restored.InitializeAsync(); Check(restored.State.State == "online" && restored.State.Games.Count == 1, "Process restart restores saved login without another authentication flow");
                await restored.LogoutAsync(); Check(vault.Read(profile) is null && restored.State.Games.Count == 0, "Explicit logout forgets only the selected profile credential and catalog");
            }
            await using (var wire = new SteamServiceProcess(fixture, profile))
            {
                await wire.RequestAsync("fixture_stderr");
                string code = ""; try { await wire.RequestAsync("fixture_error"); } catch (SteamServiceException e) { code = e.Code; }
                Check(code == "steam_request_failed", "Unknown backend error text cannot enter UI diagnostics");
                var watch = Stopwatch.StartNew(); bool cancelled = false;
                using (var deadline = new CancellationTokenSource(TimeSpan.FromMilliseconds(100)))
                    try { await wire.RequestAsync("fixture_hang", cancellation: deadline.Token); } catch (OperationCanceledException) { cancelled = true; }
                Check(cancelled && watch.Elapsed < TimeSpan.FromSeconds(3), "A silent child request cancels within a finite budget");
                bool invalid = false;
                try { await wire.RequestAsync("snapshot", new { wrongProfile = true }).WaitAsync(TimeSpan.FromSeconds(5)); }
                catch (SteamServiceException) { invalid = true; }
                Check(invalid, "Foreign-profile response terminates request authority");
            }
            await using (var wire = new SteamServiceProcess(fixture, profile))
            {
                await wire.RequestAsync("snapshot"); bool rejectedReplay = false;
                try { await wire.RequestAsync("fixture_replay").WaitAsync(TimeSpan.FromSeconds(5)); } catch (SteamServiceException) { rejectedReplay = true; }
                Check(rejectedReplay, "Replayed response sequence cannot complete a newer request");
            }
            Check(!Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories).Any(p => Encoding.UTF8.GetString(File.ReadAllBytes(p)).Contains(secret)), "No plaintext refresh token remains in test application data");
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(report))!);
            File.WriteAllText(report, JsonSerializer.Serialize(new { schema = 1, passed = true, checks, architecture = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString(),
                scope = "Real Windows DPAPI/DACLs and owned synthetic child protocol. No genuine Steam account, networking, game authorization or game launch." }, new JsonSerializerOptions { WriteIndented = true }));
            return 0;
        }
        catch (Exception error)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(report))!);
            File.WriteAllText(report, JsonSerializer.Serialize(new { passed = false, checks, error = error is SteamServiceException service ? service.Code : error.GetType().Name,
                location = error.StackTrace }, new JsonSerializerOptions { WriteIndented = true }));
            return 1;
        }
        finally { Directory.Delete(root, true); }
    }
}
