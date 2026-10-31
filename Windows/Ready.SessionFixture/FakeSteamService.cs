// SPDX-License-Identifier: GPL-3.0-only
// Owned process fixture. No SteamKit, network, genuine account or entitlement.
using System.Text.Json;

internal static class FakeSteamService
{
    public const string Secret = "fixture-private-refresh-token";
    public static async Task<int> Run()
    {
        string? profile = null, generation = null, auth = null; long sequence = 0; bool online = false; string display = "Fixture persona";
        var challenge = Guid.NewGuid().ToString("D");
        void Emit(string type, string? id, Dictionary<string, object?>? fields = null, bool wrongProfile = false)
        {
            var record = fields ?? new(); record["type"] = type; record["id"] = id; record["profileID"] = wrongProfile ? Guid.NewGuid().ToString("D") : profile;
            record["profileGeneration"] = generation; record["sequence"] = ++sequence;
            Console.WriteLine(JsonSerializer.Serialize(record)); Console.Out.Flush();
        }
        object Account() => new { steamID = "76561198000000001", accountName = "fixture_account", displayName = display, presence = "Online" };
        object[] Friends() => [new { steamID = "76561198000000002", displayName = "Fixture friend", presence = "Away", gameName = "Fixture game", relationship = "Friend" }];
        void State() => Emit("state", null, new() { ["state"] = online ? "online" : "offline" });
        void Complete()
        {
            Emit("credentials", auth, new() { ["credentials"] = new { username = "fixture_account", refresh_token = Secret } });
            online = true; State(); Emit("persona", null, new() { ["displayName"] = display, ["presence"] = "Online" });
            Emit("result", auth, new() { ["account"] = Account() }); auth = null;
        }
        while (await Console.In.ReadLineAsync() is { } line)
        {
            using var json = JsonDocument.Parse(line); var root = json.RootElement;
            profile ??= root.GetProperty("profileID").GetString(); generation ??= root.GetProperty("profileGeneration").GetString();
            if (root.GetProperty("profileID").GetString() != profile || root.GetProperty("profileGeneration").GetString() != generation) return 3;
            string id = root.GetProperty("id").GetString()!, operation = root.GetProperty("operation").GetString()!; var options = root.GetProperty("options");
            if (Environment.CommandLine.Contains(Secret) || Environment.GetEnvironmentVariables().Values.Cast<object>().Any(v => v.ToString()?.Contains(Secret) == true)) return 4;
            switch (operation)
            {
                case "snapshot":
                    Emit("result", id, new() { ["state"] = online ? "online" : "offline", ["account"] = online ? Account() : null, ["friends"] = online ? Friends() : Array.Empty<object>(), ["backendSessionReady"] = false },
                        options.TryGetProperty("wrongProfile", out var wrong) && wrong.GetBoolean()); break;
                case "authenticate":
                    auth = id; Emit("state", null, new() { ["state"] = "authenticating" });
                    if (options.GetProperty("method").GetString() == "qr") Emit("qr", auth, new() { ["url"] = "https://s.team/q/fixture-private-challenge" });
                    else Emit("guard", auth, new() { ["challengeID"] = challenge, ["method"] = "device_code" }); break;
                case "guard_code":
                    if (options.GetProperty("challengeID").GetString() != challenge || options.GetProperty("code").GetString() != "A1B2C") { Emit("error", id, new() { ["code"] = "invalid_guard_response" }); break; }
                    Complete(); Emit("result", id); break;
                case "connect":
                    if (root.GetProperty("credentials").GetProperty("refresh_token").GetString() != Secret) { Emit("error", id, new() { ["code"] = "authentication_failed" }); break; }
                    online = true; State(); Emit("result", id, new() { ["account"] = Account() }); break;
                case "library":
                    var games = new object[] {
                        new { storeID = "480", title = "Owned Windows fixture", metadata = new { libraryKind = "game" }, variants = new[] { new { platform = "windows" } } },
                        new { storeID = "481", title = "DLC fixture", metadata = new { libraryKind = "dlc" }, variants = new[] { new { platform = "windows" } } },
                        new { storeID = "482", title = "Mac fixture", metadata = new { libraryKind = "game" }, variants = new[] { new { platform = "macOS" } } } };
                    if (options.TryGetProperty("paged", out var paged) && paged.GetBoolean())
                    { Emit("library_page", id, new() { ["games"] = games, ["pageIndex"] = 0 }); Emit("result", id, new() { ["recordCount"] = games.Length, ["pageCount"] = 1 }); }
                    else Emit("result", id, new() { ["games"] = games }); break;
                case "cancel":
                    if (auth == options.GetProperty("requestID").GetString())
                    {
                        // A late success cannot retain request authority after cancellation.
                        Emit("credentials", auth, new() { ["credentials"] = new { username = "fixture_account", refresh_token = Secret } });
                        Emit("error", auth, new() { ["code"] = "cancelled" }); auth = null; online = false; State();
                    }
                    Emit("result", id); break;
                case "set_persona_name": display = options.GetProperty("displayName").GetString()!; Emit("result", id, new() { ["account"] = Account(), ["serverAcknowledged"] = true }); break;
                case "set_presence": Emit("persona", null, new() { ["displayName"] = display, ["presence"] = options.GetProperty("presence").GetString() }); Emit("result", id); break;
                case "add_friend": case "remove_friend": case "block_friend": case "unblock_friend": Emit("result", id, new() { ["friends"] = Friends(), ["serverAcknowledged"] = false, ["requestSent"] = true }); break;
                case "offline": online = false; State(); Emit("result", id); break;
                case "logout": online = false; Emit("state", null, new() { ["state"] = "logged_out", ["invalidateCredentials"] = true }); Emit("result", id); break;
                case "fixture_error": Emit("error", id, new() { ["code"] = Secret }); break;
                case "fixture_stderr": Console.Error.WriteLine(Secret); Emit("result", id); break;
                case "fixture_hang": break;
                case "fixture_replay": sequence--; Emit("result", id); break;
                case "shutdown": Emit("result", id); return 0;
                default: Emit("error", id, new() { ["code"] = "unsupported_operation" }); break;
            }
        }
        return 0;
    }
}
