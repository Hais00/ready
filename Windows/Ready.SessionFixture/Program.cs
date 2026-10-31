// SPDX-License-Identifier: GPL-3.0-only
using System.Diagnostics;
using System.Text.Json;

if (args.SequenceEqual(new[] { "--service" })) return await FakeSteamService.Run();
if (args.Length > 0 && args[0] == "-app") return await FakeDownloader.Run(args);
if (args.SequenceEqual(new[] { "lease-keeper" })) { Console.WriteLine("lease-ready"); Console.Out.Flush(); await Task.Delay(60000); return 0; }
if (args.Length == 0) { Thread.Sleep(500); return 0; }
if (args.Length < 2) return 2;
if (args[0] == "arguments") { File.WriteAllText(args[1], JsonSerializer.Serialize(args[2..])); return 0; }
if (args[0] == "parent")
{
    var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false };
    start.ArgumentList.Add("child"); start.ArgumentList.Add(args[1]);
    using var child = Process.Start(start)!; return 0;
}
if (args[0] == "child")
{ File.WriteAllText(args[1], Environment.ProcessId.ToString()); Thread.Sleep(60000); return 0; }
return 2;
