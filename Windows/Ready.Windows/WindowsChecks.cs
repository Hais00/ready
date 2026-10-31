// SPDX-License-Identifier: GPL-3.0-only
using System.Diagnostics;
using System.Drawing.Imaging;
using System.Numerics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Ready.Windows.Core;

namespace Ready.Windows;

internal static class WindowsChecks
{
    private static void Require(bool condition, string description)
    { if (!condition) throw new InvalidOperationException(description); }
    public static int Run(string report)
    {
        report = Path.GetFullPath(report); Directory.CreateDirectory(Path.GetDirectoryName(report)!);
        List<string> checks = [];
        using var canvas = new VulkanCanvas();
        using var raster = new Bitmap(64, 64, PixelFormat.Format32bppPArgb);
        for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) raster.SetPixel(x, y, Color.FromArgb(255, x * 4, y * 4, 21));
        using (var readback = canvas.Readback(raster))
        {
            for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++)
            { var p = readback.GetPixel(x, y); Require(Math.Abs(p.R - x * 4) <= 1 && Math.Abs(p.G - y * 4) <= 1 && p.B == 21 && p.A == 255, $"BGRA/orientation mismatch at {x},{y}: {p}"); }
            checks.Add("Vulkan shader: 4096 BGRA pixels, channel order and upright orientation");
        }
        using (var hidden = canvas.Readback(raster, new Vector4(.2f, .2f, 0, 1)))
        { Require(hidden.GetPixel(32, 32).A == 0 && hidden.GetPixel(1, 1).A == 0, "Closed overlay remains visible"); checks.Add("Vulkan overlay closed motion clears canvas"); }
        using (var half = canvas.Readback(raster, new Vector4(.2f, .2f, .5f, 1)))
        { Require(half.GetPixel(10, 32).A == 0 && Math.Abs(half.GetPixel(32, 32).A - 128) <= 1, "Overlay edge/alpha mismatch"); checks.Add("Vulkan overlay partial dock clipping and premultiplied alpha"); }
        canvas.ReleaseCanvas(); Require(canvas.CanvasBytes == 0, "Canvas retained during play"); checks.Add("Canvas texture teardown");
        var model = new Shell(); using var painter = new CanvasPainter { Clock = "12:34" };
        model.SetCatalog([], "");
        using (var source = painter.Draw(model, null, 1100, 720, 1))
        using (var image = canvas.Readback(source)) image.Save(Path.Combine(Path.GetDirectoryName(report)!, "ready-windows-empty.png"), ImageFormat.Png);
        Require(model.Hits.Select(h => h.Id).Distinct().Count() == model.Hits.Count, "Duplicate hit identifiers");
        model.SetCatalog(Enumerable.Range(0, 100).Select(i => new Game(i.ToString(), "Fixture " + i.ToString("D3"), GameSource.Local, "C:\\fixture")), "");
        using (var source = painter.Draw(model, null, 1100, 720, 1))
        using (var image = canvas.Readback(source)) image.Save(Path.Combine(Path.GetDirectoryName(report)!, "ready-windows-library.png"), ImageFormat.Png);
        model.ScrollBy(300, 1100, 720);
        using (painter.Draw(model, null, 1100, 720, 1))
        {
            Require(model.Hits.Where(h => h.Id.StartsWith("game:")).All(h => h.Bounds.Y >= 84), "Cards accept clicks under header");
            Require(model.Hits.Where(h => h.Id.StartsWith("game:")).All(h => h.Bounds.Bottom <= 720), "Offscreen cards accept clicks");
        }
        checks.Add("Library scroll hit clipping below header and within window");
        model.Navigate(Destination.Settings);
        var page = new CanvasPage("Impostazioni", "Generali", "Ready per Windows", Actions: [new("test:action", "Verifica")]);
        using (painter.Draw(model, page, 1100, 720, 1)) Require(model.Hits.All(h => !h.Id.StartsWith("game:")), "Hidden game remains interactive");
        checks.Add("Navigation removes library targets");
        foreach (var (w, h, dpi) in new[] { (820, 580, 1f), (1640, 1160, 2f), (1650, 1080, 1.5f) })
        {
            using var source = painter.Draw(model, page, w, h, dpi); using var image = canvas.Readback(source);
            Require(image.Width == w && image.Height == h, "DPI render size mismatch");
        }
        checks.Add("Actual Vulkan render at 100%, 150%, 200% DPI");
        using (var window = new Form { ClientSize = new(820, 580), ShowInTaskbar = false })
        using (var presenter = new VulkanCanvas(window.Handle, 820, 580))
        using (var source = painter.Draw(model, page, 820, 580, 1))
        {
            presenter.Present(source); presenter.Resize(1000, 700);
            using var resized = painter.Draw(model, page, 1000, 700, 1); presenter.Present(resized);
        }
        checks.Add("Win32 Vulkan swapchain present and resize");
        canvas.ReleaseCanvas();
        File.WriteAllText(report, JsonSerializer.Serialize(new { schema = 1, passed = true, backend = canvas.Backend,
            gpu = canvas.DeviceName, architecture = RuntimeInformation.ProcessArchitecture.ToString(), checks,
            submittedFrames = canvas.Submitted, canvasBytesAfterRelease = canvas.CanvasBytes,
            scope = "Owned synthetic canvas and HWND only; no Steam authentication, game, injection or ARM hardware result." }, new JsonSerializerOptions { WriteIndented = true }));
        return 0;
    }
    public static int Sessions(string fixture, string report)
    {
        fixture = Path.GetFullPath(fixture); report = Path.GetFullPath(report); var directory = Path.GetDirectoryName(report)!; Directory.CreateDirectory(directory);
        var game = new Game("fixture", "Ready session fixture", GameSource.Local, Path.GetDirectoryName(fixture)!, fixture);
        string markerA = Path.Combine(directory, "child-a-" + Guid.NewGuid().ToString("N") + ".txt");
        string markerB = Path.Combine(directory, "child-b-" + Guid.NewGuid().ToString("N") + ".txt");
        using var a = NativeGameSession.Start(game, ["parent", markerA]); using var b = NativeGameSession.Start(game, ["parent", markerB]);
        var watch = Stopwatch.StartNew();
        while ((!File.Exists(markerA) || !File.Exists(markerB)) && watch.Elapsed < TimeSpan.FromSeconds(15)) Thread.Sleep(50);
        Require(File.Exists(markerA) && File.Exists(markerB), "Session children did not start");
        int childA = int.Parse(File.ReadAllLines(markerA)[0]), childB = int.Parse(File.ReadAllLines(markerB)[0]);
        using var childAProcess = Process.GetProcessById(childA); using var childBProcess = Process.GetProcessById(childB);
        void WaitForParent(uint id)
        {
            try { using var parent = Process.GetProcessById((int)id); Require(parent.WaitForExit(10000), "Fixture parent did not exit"); }
            catch (ArgumentException) { } // It exited before the handle was opened.
        }
        WaitForParent(a.ProcessId); WaitForParent(b.ProcessId);
        // A GUI launcher may cause Windows to add a console host to each job.
        // The required invariant is surviving owned children, not exactly one PID.
        Require(a.ActiveProcesses >= 1 && b.ActiveProcesses >= 1 && !childAProcess.HasExited && !childBProcess.HasExited, "Job lost surviving child after parent exit");
        a.Stop(); Require(childAProcess.WaitForExit(5000), "Owned job did not terminate A");
        Require(!childBProcess.HasExited && b.ActiveProcesses >= 1, "Stopping A affected B");
        b.Dispose(); Require(childBProcess.WaitForExit(5000), "Closing owned job did not terminate B");
        string[] quoted = ["", "a b", "quote\"value", @"C:\trailing path\", "dollar$(literal)"];
        string quoteMarker = Path.Combine(directory, "arguments-" + Guid.NewGuid().ToString("N") + ".json");
        using (var roundtrip = NativeGameSession.Start(game, ["arguments", quoteMarker, .. quoted]))
        { using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10)); roundtrip.WaitAsync(timeout.Token).GetAwaiter().GetResult(); }
        Require(JsonSerializer.Deserialize<string[]>(File.ReadAllText(quoteMarker))!.SequenceEqual(quoted), "Windows argument quoting corrupted arguments");
        File.WriteAllText(report, JsonSerializer.Serialize(new { schema = 1, passed = true, architecture = RuntimeInformation.ProcessArchitecture.ToString(),
            checks = new[] { "CreateProcess with atomic JOB_LIST attribute and suspended startup", "Parent exit preserves owned child lifetime", "Stop A leaves B running", "KILL_ON_JOB_CLOSE terminates B", "CreateProcess argument roundtrip including quotes, spaces, trailing slash" },
            scope = "Owned synthetic processes; no commercial game, Steam or injected overlay." }, new JsonSerializerOptions { WriteIndented = true }));
        File.Delete(markerA); File.Delete(markerB); File.Delete(quoteMarker); return 0;
    }
}
