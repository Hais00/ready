// SPDX-License-Identifier: GPL-3.0-only
using System.Globalization;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;

namespace Ready.Windows.Core;

public sealed record SteamDepot(uint DepotID, uint SourceAppID, ulong ManifestID, ulong DownloadBytes, ulong InstalledBytes);
public sealed record SteamInstallPlan(uint AppID, string Architecture, ulong DownloadBytes, ulong InstalledBytes,
    IReadOnlyList<SteamDepot> Depots, string Fingerprint, DateTimeOffset CalculatedAt)
{
    public static SteamInstallPlan Parse(uint app, JsonElement value, bool fresh = true)
    {
        if (app is 0 or uint.MaxValue || value.GetProperty("platform").GetString() != "windows" || value.GetProperty("branch").GetString() != "public"
            || value.GetProperty("language").GetString() != "english" || value.GetProperty("verified").ValueKind != JsonValueKind.True
            || value.GetProperty("source").GetString() != "steam_pics" || value.GetProperty("status").GetString() != "available"
            || value.GetProperty("basis").GetString() != "selected_depot_payload_totals") throw new InvalidDataException("install_plan_unverified");
        string arch = value.GetProperty("architecture").GetString()!;
        if (arch is not ("32" or "64")) throw new InvalidDataException("install_plan_architecture");
        var depots = value.GetProperty("selectedDepots").EnumerateArray().Select(d => new SteamDepot(d.GetProperty("depotID").GetUInt32(), d.GetProperty("sourceAppID").GetUInt32(),
            d.GetProperty("manifestID").GetUInt64(), d.GetProperty("downloadBytes").GetUInt64(), d.GetProperty("installedBytes").GetUInt64())).OrderBy(d => d.DepotID).ToArray();
        var plan = new SteamInstallPlan(app, arch, value.GetProperty("downloadBytes").GetUInt64(), value.GetProperty("installedBytes").GetUInt64(), depots,
            value.GetProperty("fingerprint").GetString()!, DateTimeOffset.Parse(value.GetProperty("calculatedAt").GetString()!, CultureInfo.InvariantCulture));
        if (value.GetProperty("selectedDepotCount").GetInt32() != depots.Length) throw new InvalidDataException("install_plan_count");
        plan.Validate(fresh); return plan;
    }
    public void Validate(bool fresh = false)
    {
        if (AppID is 0 or uint.MaxValue || Architecture is not ("32" or "64") || Depots.Count is < 1 or > 256
            || Depots.Select(d => d.DepotID).Distinct().Count() != Depots.Count) throw new InvalidDataException("install_plan_invalid");
        ulong download = 0, installed = 0;
        foreach (var d in Depots)
        {
            if (d.DepotID is 0 or uint.MaxValue || d.SourceAppID is 0 or uint.MaxValue || d.ManifestID is 0 or ulong.MaxValue) throw new InvalidDataException("install_plan_depot_invalid");
            download = checked(download + d.DownloadBytes); installed = checked(installed + d.InstalledBytes);
        }
        if (download != DownloadBytes || installed != InstalledBytes || installed > long.MaxValue || download > long.MaxValue) throw new InvalidDataException("install_plan_totals");
        string hash = Convert.ToHexString(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(new { AppID, Platform = "windows", Branch = "public", Language = "english", Architecture, depots = Depots.OrderBy(d => d.DepotID) }))).ToLowerInvariant();
        if (Fingerprint != hash) throw new InvalidDataException("install_plan_fingerprint");
        double age = (DateTimeOffset.UtcNow - CalculatedAt).TotalSeconds;
        if (age < -300 || fresh && age > 3600) throw new InvalidDataException("install_plan_stale");
    }
    public IReadOnlyDictionary<string, string> ManifestMap => Depots.ToDictionary(d => d.DepotID.ToString(CultureInfo.InvariantCulture), d => d.ManifestID.ToString(CultureInfo.InvariantCulture));
    public string[] Arguments(string directory, uint loginID) => ["-app", AppID.ToString(CultureInfo.InvariantCulture), "-depot", .. Depots.OrderBy(d => d.DepotID).Select(d => d.DepotID.ToString(CultureInfo.InvariantCulture)),
        "-manifest", .. Depots.OrderBy(d => d.DepotID).Select(d => d.ManifestID.ToString(CultureInfo.InvariantCulture)), "-dir", directory, "-os", "windows", "-osarch", Architecture,
        "-branch", "public", "-language", "english", "-validate", "-loginid", loginID.ToString(CultureInfo.InvariantCulture)];
}

public enum DownloadState { Queued, Preparing, Downloading, Verifying, Paused, Cancelled, Interrupted, Failed, RetryWait, Completed }
public enum DownloadDesire { Run, Paused, Cancelled }
public sealed record SteamDownloadJob(int Schema, string Id, string Profile, uint AppID, string Title, string Directory, SteamInstallPlan Plan,
    uint LoginID, DownloadState State, DownloadDesire Desired, ulong? CompletedBytes, ulong? TotalBytes, ulong NetworkBytes, string? Error,
    int Attempts, long Revision, DateTimeOffset CreatedAt, DateTimeOffset UpdatedAt)
{
    public static bool Active(DownloadState state) => state is DownloadState.Preparing or DownloadState.Downloading or DownloadState.Verifying;
}

public sealed record DownloadProgress(string Kind, string Phase, ulong Total, ulong Completed, ulong Network,
    IReadOnlyDictionary<string, string>? Manifests = null, string? Error = null)
{
    public const string Prefix = "READY_DOWNLOAD_V1 ";
    public static DownloadProgress? Parse(string line)
    {
        if (!line.StartsWith(Prefix, StringComparison.Ordinal)) return null; // Discard ordinary engine diagnostics.
        if (line.Length > 65536) throw new InvalidDataException("engine_protocol_error");
        using var document = JsonDocument.Parse(line.AsMemory(Prefix.Length), new JsonDocumentOptions { MaxDepth = 8 }); var root = document.RootElement;
        string? kind = root.GetProperty("kind").GetString();
        if (kind == "error")
        {
            string? code = root.GetProperty("code").GetString();
            return new("error", "failed", 0, 0, 0, Error: code is "network_error" or "network_timeout" or "authentication_required" or "not_authorized" or "disk_full" or "local_io" or "integrity_error" or "engine_cancelled" or "rate_limited" ? code : "download_failed");
        }
        if (kind is not ("plan" or "progress" or "completed")) throw new InvalidDataException("engine_protocol_error");
        ulong total = root.GetProperty("totalBytes").GetUInt64(), done = root.GetProperty("completedBytes").GetUInt64(), network = root.GetProperty("networkBytesReceived").GetUInt64();
        string? phase = root.GetProperty("phase").GetString();
        if (total > long.MaxValue || done > total || network > long.MaxValue || phase is not ("verifying" or "downloading")) throw new InvalidDataException("engine_protocol_error");
        Dictionary<string, string>? manifests = null;
        if (kind == "completed")
        {
            manifests = new();
            foreach (var item in root.GetProperty("manifests").EnumerateObject())
            {
                string value = item.Value.GetString()!;
                if (!uint.TryParse(item.Name, NumberStyles.None, CultureInfo.InvariantCulture, out uint depot) || depot is 0 or uint.MaxValue
                    || !ulong.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out ulong manifest) || manifest is 0 or ulong.MaxValue
                    || item.Name != depot.ToString(CultureInfo.InvariantCulture) || value != manifest.ToString(CultureInfo.InvariantCulture) || !manifests.TryAdd(item.Name, value)) throw new InvalidDataException("engine_protocol_error");
            }
            if (done != total || manifests.Count is < 1 or > 256) throw new InvalidDataException("engine_protocol_error");
        }
        return new(kind, phase, total, done, network, manifests);
    }
}

public static class SteamDepotReceipt
{
    public static void Verify(string directory, SteamInstallPlan plan, DownloadProgress complete)
    {
        plan.Validate(); var expected = plan.ManifestMap;
        if (complete.Kind != "completed" || complete.Manifests is null || complete.Completed != complete.Total || complete.Manifests.Count != expected.Count
            || expected.Any(p => complete.Manifests.GetValueOrDefault(p.Key) != p.Value)) throw new InvalidDataException("download_incomplete");
        string cache = Path.Combine(directory, ".DepotDownloader");
        if ((File.GetAttributes(cache) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("unsafe_installation");
        string config = Path.Combine(cache, "depot.config");
        if ((File.GetAttributes(config) & FileAttributes.ReparsePoint) != 0 || new FileInfo(config).Length > 1024 * 1024) throw new InvalidDataException("download_incomplete");
        using var input = File.OpenRead(config); using var deflate = new DeflateStream(input, CompressionMode.Decompress); using var data = new MemoryStream();
        byte[] buffer = new byte[4096]; int count;
        while ((count = deflate.Read(buffer)) > 0) { if (data.Length + count > 1024 * 1024) throw new InvalidDataException("depot_config_too_large"); data.Write(buffer, 0, count); }
        var bytes = data.ToArray(); int cursor = 0; var actual = new Dictionary<string, string>();
        ulong Number(ref int at)
        {
            ulong value = 0;
            for (int i = 0; i < 10 && at < bytes.Length; i++) { byte b = bytes[at++]; if (i == 9 && b > 1) break; value |= (ulong)(b & 127) << (i * 7); if (b < 128) return value; }
            throw new InvalidDataException("depot_config_invalid");
        }
        while (cursor < bytes.Length)
        {
            if (Number(ref cursor) != 10) throw new InvalidDataException("depot_config_invalid");
            ulong size = Number(ref cursor); if (size > (ulong)(bytes.Length - cursor)) throw new InvalidDataException("depot_config_invalid"); int end = cursor + (int)size;
            ulong depot = 0, manifest = 0;
            while (cursor < end) { ulong key = Number(ref cursor), value = Number(ref cursor); if (key == 8) depot = value; else if (key == 16) manifest = value; else throw new InvalidDataException("depot_config_invalid"); }
            if (cursor != end || depot is 0 or >= uint.MaxValue || manifest is 0 or ulong.MaxValue || !actual.TryAdd(depot.ToString(CultureInfo.InvariantCulture), manifest.ToString(CultureInfo.InvariantCulture))) throw new InvalidDataException("depot_config_invalid");
        }
        foreach (var pair in expected)
        {
            if (actual.GetValueOrDefault(pair.Key) != pair.Value) throw new InvalidDataException("download_incomplete");
            string manifest = Path.Combine(cache, pair.Key + "_" + pair.Value + ".manifest"), checksum = manifest + ".sha";
            if ((File.GetAttributes(manifest) & FileAttributes.ReparsePoint) != 0 || (File.GetAttributes(checksum) & FileAttributes.ReparsePoint) != 0
                || new FileInfo(manifest).Length > 64 * 1024 * 1024 || new FileInfo(checksum).Length != 20) throw new InvalidDataException("download_incomplete");
            using var stream = File.OpenRead(manifest);
            if (!CryptographicOperations.FixedTimeEquals(SHA1.HashData(stream), File.ReadAllBytes(checksum))) throw new InvalidDataException("download_incomplete");
        }
    }
}
