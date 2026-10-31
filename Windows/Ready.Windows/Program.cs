// SPDX-License-Identifier: GPL-3.0-only
using System.Text.Json;

namespace Ready.Windows;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
        string? Value(string key)
        {
            int i = Array.IndexOf(args, key); return i < 0 ? null : i + 1 < args.Length ? args[i + 1] : throw new ArgumentException("Valore mancante per " + key);
        }
        var dataRoot = Value("--data-root") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Ready");
        try
        {
            if (args.Contains("--graphics-self-test")) return WindowsChecks.Run(Value("--report") ?? Path.Combine(dataRoot, "graphics-check.json"));
            if (args.Contains("--session-self-test")) return WindowsChecks.Sessions(Value("--fixture") ?? throw new ArgumentException("Specificare --fixture."), Value("--report") ?? Path.Combine(dataRoot, "session-check.json"));
            if (args.Contains("--steam-client-self-test")) return SteamClientChecks.Run(Value("--fixture") ?? throw new ArgumentException("Specificare --fixture."), Value("--report") ?? Path.Combine(dataRoot, "steam-client-check.json")).GetAwaiter().GetResult();
            if (args.Contains("--steam-service-client-self-test")) return SteamClientChecks.Actual(Value("--service") ?? throw new ArgumentException("Specificare --service."), Value("--report") ?? Path.Combine(dataRoot, "steam-service-client-check.json")).GetAwaiter().GetResult();
            if (args.Contains("--window-self-test") || args.Contains("--steam-window-self-test"))
            {
                if (Value("--data-root") is null || !Path.IsPathFullyQualified(dataRoot)
                    || Directory.Exists(dataRoot) && Directory.EnumerateFileSystemEntries(dataRoot).Any())
                    throw new ArgumentException("La prova della finestra richiede --data-root con una cartella assoluta nuova e vuota.");
                Directory.CreateDirectory(dataRoot);
                var report = Value("--report") ?? Path.Combine(dataRoot, "window-check.json");
                int result = 1;
                using var test = new ReadyWindow(dataRoot, discoverSteam: false);
                test.Shown += async (_, _) =>
                {
                    try
                    {
                        string fixture = Value("--fixture") ?? throw new ArgumentException("Specificare --fixture.");
                        if (args.Contains("--steam-window-self-test")) await test.ExerciseSteamAsync(fixture, report); else await test.ExerciseAsync(fixture, report);
                        result = 0;
                    }
                    catch (Exception e) { File.WriteAllText(report, JsonSerializer.Serialize(new { passed = false, error = e.GetType().Name, message = e.Message })); }
                    finally { test.Close(); }
                };
                Application.Run(test); return result;
            }
            using var window = new ReadyWindow(dataRoot);
            Application.Run(window); return 0;
        }
        catch (Exception error)
        {
            Directory.CreateDirectory(dataRoot);
            File.WriteAllText(Path.Combine(dataRoot, "startup-error.json"), JsonSerializer.Serialize(new { error = error.GetType().Name, message = error.Message }));
            if (!args.Any(a => a.EndsWith("self-test", StringComparison.Ordinal)))
            {
                using var failure = new Form { Text = "Ready — avvio non riuscito", ClientSize = new(740, 240), BackColor = Color.FromArgb(20, 20, 20) };
                failure.Controls.Add(new Label { Text = "Impossibile avviare il canvas Vulkan.\n" + error.Message, Dock = DockStyle.Fill, ForeColor = Color.White, Padding = new Padding(32), AutoSize = false });
                Application.Run(failure);
            }
            return 1;
        }
    }
}
