// SPDX-License-Identifier: GPL-3.0-only
// Synthetic files and progress only. No SteamKit, account, CDN or game content.
using System.Globalization;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;
using Ready.Windows.Core;

internal static class FakeDownloader
{
    public static async Task<int> Run(string[] args)
    {
        string Value(string key) => args[Array.IndexOf(args, key) + 1];
        uint app = uint.Parse(Value("-app")); string directory = Value("-dir");
        const string secret = "fixture-private-refresh-token";
        if (Environment.CommandLine.Contains(secret) || Environment.CommandLine.Contains("fixture_account")
            || Environment.GetEnvironmentVariables().Values.Cast<object>().Any(v => v.ToString()?.Contains(secret) == true)) return 12;
        using var input = JsonDocument.Parse(await Console.In.ReadLineAsync() ?? "{}");
        if (input.RootElement.GetProperty("refresh_token").GetString() != secret || Environment.GetEnvironmentVariable("READY_TOKEN_STDIN") != "1") return 13;
        Console.Error.WriteLine(secret); Console.WriteLine("discard unstructured " + secret); Console.Out.Flush();
        void Emit(object value) { Console.WriteLine(DownloadProgress.Prefix + JsonSerializer.Serialize(value)); Console.Out.Flush(); }
        Emit(new { kind = "plan", phase = "verifying", totalBytes = 8, completedBytes = 0, networkBytesReceived = 0 });
        if (app == 494) { Emit(new { kind = "error", code = "network_error" }); return 4; }
        string file = Path.Combine(directory, "fixture.bin");
        long existing = File.Exists(file) ? new FileInfo(file).Length : 0; existing = Math.Clamp(existing, 0, 8);
        using (var content = new FileStream(file, FileMode.OpenOrCreate, FileAccess.Write, FileShare.Read))
        {
            for (long i = existing; i < 8; i++)
            {
                if (app == 481) await Task.Delay(200);
                content.Position = i; content.WriteByte((byte)(65 + i)); content.Flush(true);
                Emit(new { kind = "progress", phase = "downloading", totalBytes = 8, completedBytes = i + 1, networkBytesReceived = i + 1 - existing });
            }
        }
        if (app == 490) return 0;
        string[] Depots(string key) => args.Skip(Array.IndexOf(args, key) + 1).TakeWhile(a => !a.StartsWith('-')).ToArray();
        var depots = Depots("-depot"); var manifests = Depots("-manifest");
        string cache = Path.Combine(directory, ".DepotDownloader"); Directory.CreateDirectory(cache);
        using var payload = new MemoryStream();
        void Number(Stream stream, ulong value) { while (value >= 128) { stream.WriteByte((byte)((value & 127) | 128)); value >>= 7; } stream.WriteByte((byte)value); }
        var map = new Dictionary<string, string>();
        for (int i = 0; i < depots.Length; i++)
        {
            map[depots[i]] = app == 492 ? "43" : manifests[i];
            using var entry = new MemoryStream(); entry.WriteByte(8); Number(entry, ulong.Parse(depots[i], CultureInfo.InvariantCulture)); entry.WriteByte(16); Number(entry, ulong.Parse(manifests[i], CultureInfo.InvariantCulture));
            payload.WriteByte(10); Number(payload, (ulong)entry.Length); payload.Write(entry.ToArray());
            string manifest = Path.Combine(cache, depots[i] + "_" + manifests[i] + ".manifest");
            byte[] bytes = "synthetic-manifest-only"u8.ToArray(); File.WriteAllBytes(manifest, bytes); File.WriteAllBytes(manifest + ".sha", app == 491 ? new byte[20] : SHA1.HashData(bytes));
        }
        using (var config = File.Create(Path.Combine(cache, "depot.config"))) using (var compressed = new DeflateStream(config, CompressionLevel.Optimal)) compressed.Write(payload.ToArray());
        Emit(new { kind = "completed", phase = "verifying", totalBytes = 8, completedBytes = 8, networkBytesReceived = 8 - existing, manifests = map }); return 0;
    }
}
