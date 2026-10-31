// SPDX-License-Identifier: GPL-3.0-only
using System.Text;

namespace Ready.Windows.Core;

// Steam's text VDF/ACF dialect, preserving repeated keys. This reads metadata only.
public sealed record ValveValue(string Key, string? Text, IReadOnlyList<ValveValue> Children)
{
    public string? String(string key) => Children.LastOrDefault(x => x.Key.Equals(key, StringComparison.OrdinalIgnoreCase))?.Text;
    public ValveValue? Object(string key) => Children.LastOrDefault(x => x.Key.Equals(key, StringComparison.OrdinalIgnoreCase) && x.Text is null);
}
public static class ValveKeyValues
{
    public static ValveValue Parse(string text)
    {
        if (text.Length > 8 * 1024 * 1024) throw new InvalidDataException("VDF oltre il limite di 8 MiB.");
        var parser = new Parser(text); return new("root", null, parser.Read(0, false));
    }
    private sealed class Parser(string text)
    {
        private int cursor;
        private string? Next()
        {
            while (cursor < text.Length)
            {
                if (char.IsWhiteSpace(text[cursor]) || text[cursor] == '\uFEFF') { cursor++; continue; }
                if (text[cursor] == '/' && cursor + 1 < text.Length && text[cursor + 1] == '/')
                { while (cursor < text.Length && text[cursor] != '\n') cursor++; continue; }
                break;
            }
            if (cursor == text.Length) return null;
            char c = text[cursor++];
            if (c is '{' or '}') return c.ToString();
            var token = new StringBuilder();
            if (c == '"')
            {
                while (cursor < text.Length)
                {
                    c = text[cursor++];
                    if (c == '"') return token.ToString();
                    if (c == '\\' && cursor < text.Length && text[cursor] is '"' or '\\') c = text[cursor++];
                    token.Append(c);
                }
                throw new InvalidDataException("Stringa VDF non terminata.");
            }
            token.Append(c);
            while (cursor < text.Length && !char.IsWhiteSpace(text[cursor]) && text[cursor] is not '{' and not '}') token.Append(text[cursor++]);
            return token.ToString();
        }
        internal List<ValveValue> Read(int depth, bool nested)
        {
            if (depth > 64) throw new InvalidDataException("VDF troppo annidato.");
            List<ValveValue> entries = [];
            while (Next() is { } key)
            {
                if (key == "}") { if (nested) return entries; throw new InvalidDataException("Chiusura VDF inattesa."); }
                if (key == "{") throw new InvalidDataException("Chiave VDF mancante.");
                var value = Next() ?? throw new InvalidDataException("Valore VDF mancante.");
                if (value == "}") throw new InvalidDataException("Valore VDF mancante.");
                entries.Add(value == "{" ? new(key, null, Read(depth + 1, true)) : new(key, value, []));
            }
            if (nested) throw new InvalidDataException("Oggetto VDF non terminato.");
            return entries;
        }
    }
}

public sealed record SteamDiscovery(IReadOnlyList<Game> Games, IReadOnlyList<string> Errors);
public static class SteamLibrary
{
    public static SteamDiscovery Discover(string steamRoot)
    {
        var games = new Dictionary<uint, Game>(); List<string> errors = [];
        var roots = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { Path.GetFullPath(steamRoot) };
        try
        {
            var path = Path.Combine(steamRoot, "steamapps", "libraryfolders.vdf");
            if (File.Exists(path))
            {
                var folders = ValveKeyValues.Parse(File.ReadAllText(path)).Object("libraryfolders");
                foreach (var entry in folders?.Children ?? [])
                {
                    if (!uint.TryParse(entry.Key, out _)) continue;
                    var root = entry.Text ?? entry.String("path");
                    if (root is not null && Path.IsPathFullyQualified(root)) roots.Add(Path.GetFullPath(root));
                }
            }
        }
        catch (Exception e) when (e is IOException or InvalidDataException or UnauthorizedAccessException or ArgumentException) { errors.Add("libraryfolders.vdf: " + e.Message); }
        foreach (var root in roots)
        {
            var apps = Path.Combine(root, "steamapps");
            try
            {
                if (!Directory.Exists(apps)) continue;
                foreach (var manifest in Directory.EnumerateFiles(apps, "appmanifest_*.acf"))
                {
                    try
                    {
                        var app = ValveKeyValues.Parse(File.ReadAllText(manifest)).Object("AppState");
                        if (app is null || !uint.TryParse(app.String("appid"), out uint id) || id is 0 or uint.MaxValue
                            || !uint.TryParse(app.String("StateFlags"), out uint state) || (state & 4) == 0) continue;
                        if (!string.Equals(Path.GetFileName(manifest), $"appmanifest_{id}.acf", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("AppID incoerente con il manifest.");
                        string? dir = app.String("installdir"), name = app.String("name");
                        if (string.IsNullOrWhiteSpace(dir) || string.IsNullOrWhiteSpace(name)) continue;
                        var common = Path.GetFullPath(Path.Combine(apps, "common"));
                        var installed = Path.GetFullPath(Path.Combine(common, dir));
                        if (!installed.StartsWith(common + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Percorso installazione esterno alla libreria.");
                        if (!Directory.Exists(installed)) continue;
                        var cover = Path.Combine(steamRoot, "appcache", "librarycache", $"{id}_library_600x900.jpg");
                        games[id] = new("steam:" + id, name, GameSource.Steam, installed, AppId: id, Artwork: File.Exists(cover) ? cover : null);
                    }
                    catch (Exception e) when (e is IOException or InvalidDataException or UnauthorizedAccessException or ArgumentException) { errors.Add(Path.GetFileName(manifest) + ": " + e.Message); }
                }
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { errors.Add(apps + ": " + e.Message); }
        }
        return new(games.Values.OrderBy(g => g.Title, StringComparer.CurrentCultureIgnoreCase).ToArray(), errors);
    }
}
