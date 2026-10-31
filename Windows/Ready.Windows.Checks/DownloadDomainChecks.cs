// SPDX-License-Identifier: GPL-3.0-only
using Ready.Windows.Core;
using System.Text.Json;

internal static class DownloadDomainChecks
{
    public static void Run(Action<bool, string> check)
    {
        void Reject(Action action, string label)
        { bool rejected = false; try { action(); } catch (Exception e) when (e is InvalidDataException or InvalidOperationException or JsonException or OverflowException) { rejected = true; } check(rejected, label); }
        const string fingerprint = "bd5bd21f482d3b1e99b418489c754e62f7d20d1193e510fc20352d242cfaa084";
        var payload = JsonSerializer.SerializeToElement(new { platform = "windows", branch = "public", language = "english", architecture = "64", verified = true, source = "steam_pics", status = "available", basis = "selected_depot_payload_totals",
            selectedDepotCount = 1, selectedDepots = new[] { new { depotID = 1, sourceAppID = 480, manifestID = 42, downloadBytes = 4, installedBytes = 8 } }, downloadBytes = 4, installedBytes = 8, fingerprint, calculatedAt = DateTimeOffset.UtcNow.ToString("O") });
        var plan = SteamInstallPlan.Parse(480, payload);
        check(plan.Fingerprint == fingerprint && plan.Depots.Single().ManifestID == 42, "Steam payload fingerprint agrees with independent canonical JSON vector");
        var arguments = plan.Arguments(@"C:\Games\a path", 0xD0000001);
        check(arguments.Take(6).SequenceEqual(new[] { "-app", "480", "-depot", "1", "-manifest", "42" }) && arguments.Contains(@"C:\Games\a path") && !arguments.Contains("-username"), "Pinned depot/manifest pairs are literal arguments without credential switches");
        Reject(() => (plan with { InstalledBytes = 9 }).Validate(), "Plan payload totals cannot be silently changed");
        Reject(() => (plan with { Fingerprint = new string('0', 64) }).Validate(), "Plan fingerprint mismatch is rejected");
        Reject(() => (plan with { CalculatedAt = DateTimeOffset.UtcNow.AddHours(-2) }).Validate(true), "New installation admission rejects stale plans");
        Reject(() => (plan with { AppID = uint.MaxValue }).Validate(), "Reserved app sentinel cannot become an install plan");
        check(DownloadProgress.Parse("unstructured private diagnostic") is null, "Ordinary engine output is discarded");
        var completed = DownloadProgress.Parse(DownloadProgress.Prefix + "{\"kind\":\"completed\",\"phase\":\"verifying\",\"totalBytes\":8,\"completedBytes\":8,\"networkBytesReceived\":4,\"manifests\":{\"1\":\"42\"}}");
        check(completed?.Completed == 8 && completed.Network == 4 && completed.Manifests!["1"] == "42", "Numeric progress separates verified bytes and actual network bytes");
        foreach (string body in new[] {
            "{\"kind\":\"progress\",\"phase\":\"downloading\",\"totalBytes\":8,\"completedBytes\":9,\"networkBytesReceived\":1}",
            "{\"kind\":\"progress\",\"phase\":\"downloading\",\"totalBytes\":true,\"completedBytes\":1,\"networkBytesReceived\":1}",
            "{\"kind\":\"completed\",\"phase\":\"verifying\",\"totalBytes\":8,\"completedBytes\":7,\"networkBytesReceived\":1,\"manifests\":{\"1\":\"42\"}}" })
            Reject(() => DownloadProgress.Parse(DownloadProgress.Prefix + body), "Invalid numeric/completion progress rejected");
        check(DownloadProgress.Parse(DownloadProgress.Prefix + "{\"kind\":\"error\",\"code\":\"untrusted private error\"}")!.Error == "download_failed", "Raw engine errors are replaced by an allowed code");
    }
}
