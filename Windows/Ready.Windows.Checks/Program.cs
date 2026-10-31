// SPDX-License-Identifier: GPL-3.0-only
using Ready.Windows.Core;
using System.Text.Json;

int passed = 0;
void Check(bool value, string label) { if (!value) throw new InvalidOperationException(label); passed++; Console.WriteLine("PASS " + label); }
void Reject(Action action, string label)
{
    try { action(); }
    catch (Exception e) when (e is InvalidDataException or ArgumentException or JsonException) { Check(true, label); return; }
    throw new InvalidOperationException("Expected rejection: " + label);
}
var temp = Path.Combine(Path.GetTempPath(), "ready-windows-check-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(temp);
try
{
    var parsed = ValveKeyValues.Parse("// comment\n\"Root\" { \"path\" \"C:\\\\Games\\\\Steam\" \"name\" \"The \\\"Game\\\"\" child { id 42 } id 1 id 2 }");
    Check(parsed.Object("root")?.String("path") == @"C:\Games\Steam", "VDF escaped Windows path");
    Check(parsed.Object("ROOT")?.String("name") == "The \"Game\"", "VDF escaped quotes and case-insensitive keys");
    Check(parsed.Object("root")?.Object("child")?.String("id") == "42" && parsed.Object("root")?.String("id") == "2", "VDF nested and duplicate keys");
    foreach (string text in new[] { "root {", "}", "{ a b }", "root { a }", "root \"unterminated" }) Reject(() => ValveKeyValues.Parse(text), "Malformed VDF " + text);
    Reject(() => ValveKeyValues.Parse(string.Concat(Enumerable.Repeat("a { ", 66)) + string.Concat(Enumerable.Repeat("}", 66))), "Bounded VDF depth");
    Reject(() => ValveKeyValues.Parse(new string('x', 8 * 1024 * 1024 + 1)), "Bounded VDF input");
    var steam = Path.Combine(temp, "steam"); var apps = Path.Combine(steam, "steamapps"); Directory.CreateDirectory(Path.Combine(apps, "common", "Fixture"));
    File.WriteAllText(Path.Combine(apps, "appmanifest_42.acf"), "AppState { appid 42 name \"Fixture Game\" installdir Fixture StateFlags 4 }");
    File.WriteAllText(Path.Combine(apps, "appmanifest_43.acf"), "AppState { appid 43 name Incomplete installdir Fixture StateFlags 2 }");
    var discovered = SteamLibrary.Discover(steam);
    Check(discovered.Games.Count == 1 && discovered.Games[0].AppId == 42 && discovered.Games[0].Executable is null, "Installed manifests only, without guessing launch executables");
    File.WriteAllText(Path.Combine(apps, "appmanifest_44.acf"), "AppState { appid 44 name Escape installdir ../outside StateFlags 4 }");
    File.WriteAllText(Path.Combine(apps, "appmanifest_45.acf"), "AppState { appid 45 name Broken");
    discovered = SteamLibrary.Discover(steam);
    Check(discovered.Games.Count == 1 && discovered.Errors.Count == 2, "Corrupt/escaping manifests isolated from valid games");
    var second = Path.Combine(temp, "second"); Directory.CreateDirectory(Path.Combine(second, "steamapps", "common", "Other"));
    File.WriteAllText(Path.Combine(second, "steamapps", "appmanifest_46.acf"), "AppState { appid 46 name Other installdir Other StateFlags 4 }");
    string Escape(string path) => path.Replace("\\", "\\\\");
    File.WriteAllText(Path.Combine(apps, "libraryfolders.vdf"), $"libraryfolders {{ 0 {{ path \"{Escape(steam)}\" }} 1 {{ path \"{Escape(second)}\" }} }}");
    Check(SteamLibrary.Discover(steam).Games.Count == 2, "Multiple Steam libraries and duplicate default root");
    File.WriteAllText(Path.Combine(apps, "libraryfolders.vdf"), $"libraryfolders {{ 1 \"{Escape(second)}\" }}");
    Check(SteamLibrary.Discover(steam).Games.Count == 2, "Legacy Steam library folders");
    var shell = new Shell();
    shell.SetCatalog(Enumerable.Range(0, 5000).Select(i => new Game(i.ToString(), "Game " + i.ToString("D4"), GameSource.Local, temp)), "");
    Check(shell.Columns(1100) == 5 && shell.CardWidth(1100) == 176 && shell.Card(0, 1100) == new Rect(112, 103, 176, 306), "Original Swift grid geometry at 1100 points");
    Check(shell.Visible(1100, 720).Count() <= 15, "Bounded visible work for 5000 games");
    shell.Hits.Add(new("game", new(100, 100, 50, 50), "Game")); shell.Down(110, 110);
    Check(shell.Up(160, 110) is null, "Dragging outside does not activate");
    shell.Down(110, 110); shell.Navigate(Destination.Settings);
    Check(shell.Up(110, 110) is null && shell.Hits.Count == 0, "Navigation invalidates a pending game press");
    shell.Navigate(Destination.Library); shell.Hits.Add(new("game", new(100, 100, 50, 50), "Game")); shell.Down(110, 110); shell.ScrollBy(300, 1100, 720);
    Check(shell.Up(110, 110) is null, "Scrolling cancels pending activation");
    shell.ScrollBy(float.PositiveInfinity, 1100, 720); Check(shell.Scroll == 300, "Nonfinite scrolling ignored");
    shell.ScrollBy(float.MaxValue, 1100, 720); Check(shell.Scroll == shell.MaximumScroll(1100, 720), "Scroll bound");
    shell.Reveal("game:0", 1100, 720); Check(shell.Scroll == 0, "First-row keyboard navigation restores top inset");
    shell.SetCatalog(shell.Games, "game 0042"); Check(shell.Games.Count == 1 && shell.Games[0].Id == "42", "Case-insensitive library search");
    foreach (var (machine, expected) in new[] { ((ushort)0x14c, PeArchitecture.X86), ((ushort)0x8664, PeArchitecture.X64), ((ushort)0xaa64, PeArchitecture.Arm64) })
    {
        var image = new byte[128]; image[0] = 0x4D; image[1] = 0x5A; BitConverter.GetBytes(64u).CopyTo(image, 60); BitConverter.GetBytes(0x4550u).CopyTo(image, 64); BitConverter.GetBytes(machine).CopyTo(image, 68); image[86] = 2;
        var exe = Path.Combine(temp, expected + ".exe"); File.WriteAllBytes(exe, image);
        Check(PeImage.ReadArchitecture(exe) == expected, "PE architecture " + expected);
        var library = Library.Empty().Import(exe).Import(exe);
        Check(library.ActiveGames.Count() == 1 && library.ActiveGames.First().Architecture == expected, "Idempotent import " + expected);
        image[87] = 0x20; File.WriteAllBytes(exe, image); Check(PeImage.ReadArchitecture(exe) == PeArchitecture.Unknown, "Reject DLL as game " + expected);
    }
    var invalid = Path.Combine(temp, "invalid.exe"); File.WriteAllText(invalid, "Not a PE"); Reject(() => Library.Empty().Import(invalid), "Reject text disguised as executable");
    var store = new LibraryStore(Path.Combine(temp, "data")); var saved = store.Load().AddProfile("Secondo"); store.Save(saved);
    Check(store.Load().ActiveProfile == saved.ActiveProfile && store.Load().Profiles.Count == 2, "Durable profiles and active selection");
    Check(!File.ReadAllText(Path.Combine(store.Root, "library-windows.json")).Contains("ActiveGames"), "Computed active catalog is not duplicated into profile state");
    Reject(() => saved.AddProfile(" Secondo "), "Duplicate profiles"); Reject(() => saved.AddProfile("  "), "Empty profiles");
    File.WriteAllText(Path.Combine(store.Root, "library-windows.json"), "broken-json");
    Reject(() => store.Load(), "Damaged library is not reset"); Check(File.ReadAllText(Path.Combine(store.Root, "library-windows.json")) == "broken-json", "Damaged library preserved");
    DownloadDomainChecks.Run(Check);
    Console.WriteLine($"{passed} checks passed."); return 0;
}
finally { Directory.Delete(temp, true); }
