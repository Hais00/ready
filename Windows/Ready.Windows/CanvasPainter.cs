// SPDX-License-Identifier: GPL-3.0-only
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using Ready.Windows.Core;
using QRCoder;

namespace Ready.Windows;

internal sealed record PageAction(string Id, string Title, bool Enabled = true);
internal sealed record PageRow(string Id, string Title, string Subtitle = "");
internal sealed record CanvasField(string Id, string Label, string Value, bool Secret = false)
{ public override string ToString() => "[private canvas field]"; }
internal sealed record CanvasPage(string Title, string Heading, string Body,
    string? Field = null, string FieldLabel = "", IReadOnlyList<PageAction>? Actions = null,
    IReadOnlyList<PageRow>? Rows = null, IReadOnlyList<PageAction>? Tabs = null, string? SelectedTab = null,
    IReadOnlyList<CanvasField>? Fields = null, string? QR = null, float Offset = 0)
{ public override string ToString() => "[private canvas page]"; }

// Mirrors the top-down CoreGraphics composition in MetalCanvas and LibraryCardContent.
internal sealed class CanvasPainter : IDisposable
{
    private readonly Dictionary<string, Bitmap> artwork = [];
    private readonly Dictionary<(float, bool), Font> fonts = [];
    public string ProfileName { get; set; } = "Giocatore";
    public string Clock { get; set; } = DateTime.Now.ToString("HH:mm");
    public string? RunningGame { get; set; }
    public float MaximumPageOffset { get; private set; }
    private QRCodeData? qr;
    private string? qrUrl;
    private float drawingScale;
    private Graphics graphics = null!;
    private Shell shell = null!;
    private Font Font(float size, bool bold) => fonts.TryGetValue((size, bold), out var font) ? font : fonts[(size, bold)] = new Font("Segoe UI", size, bold ? FontStyle.Bold : FontStyle.Regular, GraphicsUnit.Pixel);
    private static Color Gray(int hex, int alpha = 255)
    {
        int value = (int)Math.Round(.2126 * ((hex >> 16) & 255) + .7152 * ((hex >> 8) & 255) + .0722 * (hex & 255));
        return Color.FromArgb(alpha, value, value, value);
    }
    private static RectangleF R(Rect r) => new(r.X, r.Y, r.Width, r.Height);
    private static GraphicsPath Rounded(Rect r, float radius)
    {
        var path = new GraphicsPath(); float d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
        if (d <= 0) return path;
        path.AddArc(r.X, r.Y, d, d, 180, 90); path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); path.AddArc(r.X, r.Bottom - d, d, d, 90, 90); path.CloseFigure(); return path;
    }
    private void Round(Rect rect, Color color, float radius = 12)
    { using var path = Rounded(rect, radius); using var brush = new SolidBrush(color); graphics.FillPath(brush, path); }
    private void Text(string text, Rect rect, float size = 16, bool bold = false, Color? color = null)
    {
        using var brush = new SolidBrush(color ?? Color.White);
        using var format = new StringFormat { Trimming = StringTrimming.EllipsisCharacter, FormatFlags = StringFormatFlags.LineLimit };
        graphics.DrawString(text, Font(size, bold), brush, R(rect), format);
    }
    private void Feedback(Rect rect, string id)
    {
        bool hover = shell.Hover == id, pressed = shell.Pressed == id, focus = shell.Focus == id;
        if (!hover && !pressed && !focus) return;
        Round(rect, Color.FromArgb(pressed ? 38 : 17, Color.White), 10);
        if (hover || focus)
        { using var path = Rounded(new(rect.X + 1, rect.Y + 1, rect.Width - 2, rect.Height - 2), 10); using var pen = new Pen(Color.FromArgb(focus ? 200 : 90, Color.White), 1.5f); graphics.DrawPath(pen, path); }
    }
    private void Button(Rect rect, string id, string label, bool active = false, string? symbol = null, bool enabled = true)
    {
        Round(rect, Gray(active ? 0x2a443b : 0x24292b));
        if (symbol is not null) Icon(symbol, new(rect.X + 10, rect.Y + 10, rect.Width - 20, rect.Height - 20), active ? Gray(0x98f5b9) : Color.White);
        else Text(label, new(rect.X + 12, rect.Y + 9, rect.Width - 24, rect.Height - 12), 14, true);
        if (enabled) { shell.Hits.Add(new(id, rect, label)); Feedback(rect, id); }
        else Round(rect, Color.FromArgb(100, 0, 0, 0));
    }
    // Independent line icons. Apple SF Symbols are proprietary and are not redistributed.
    private void Icon(string symbol, Rect r, Color color)
    {
        var state = graphics.Save(); graphics.TranslateTransform(r.X, r.Y); graphics.ScaleTransform(r.Width / 24, r.Height / 24);
        using var pen = new Pen(color, 1.8f) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
        switch (symbol)
        {
            case "library":
                graphics.DrawRectangle(pen, 2, 3, 4, 18); graphics.DrawRectangle(pen, 9, 3, 4, 18); graphics.DrawLine(pen, 17, 3, 21, 20); graphics.DrawLine(pen, 20, 3, 24, 20); break;
            case "friends":
                graphics.DrawEllipse(pen, 4, 2, 6, 6); graphics.DrawEllipse(pen, 15, 3, 5, 5); graphics.DrawArc(pen, 1, 10, 12, 14, 180, 180); graphics.DrawArc(pen, 12, 11, 11, 12, 180, 180); break;
            case "downloads":
                graphics.DrawEllipse(pen, 1, 1, 22, 22); graphics.DrawLine(pen, 12, 5, 12, 17); graphics.DrawLines(pen, new PointF[] {new(7, 12), new(12, 17), new(17, 12)}); break;
            case "plus": graphics.DrawLine(pen, 12, 3, 12, 21); graphics.DrawLine(pen, 3, 12, 21, 12); break;
            case "settings":
                for (int i = 0; i < 8; i++) { double a = i * Math.PI / 4; graphics.DrawLine(pen, 12 + 8 * (float)Math.Cos(a), 12 + 8 * (float)Math.Sin(a), 12 + 11 * (float)Math.Cos(a), 12 + 11 * (float)Math.Sin(a)); }
                graphics.DrawEllipse(pen, 4, 4, 16, 16); graphics.DrawEllipse(pen, 9, 9, 6, 6); break;
            case "profile": graphics.DrawEllipse(pen, 1, 1, 22, 22); graphics.DrawEllipse(pen, 8, 5, 8, 8); graphics.DrawArc(pen, 5, 15, 14, 10, 180, 180); break;
            default:
                graphics.DrawArc(pen, 1, 5, 22, 15, 180, 180); graphics.DrawLines(pen, new PointF[] {new(1, 12), new(1, 21), new(6, 21), new(9, 17), new(15, 17), new(18, 21), new(23, 21), new(23, 12)});
                graphics.DrawLine(pen, 5, 10, 5, 16); graphics.DrawLine(pen, 2, 13, 8, 13); graphics.DrawEllipse(pen, 16, 10, 1, 1); graphics.DrawEllipse(pen, 19, 13, 1, 1); break;
        }
        graphics.Restore(state);
    }
    public Bitmap Draw(Shell model, CanvasPage? page, int pixelWidth, int pixelHeight, float scale)
    {
        shell = model; shell.Hits.Clear(); drawingScale = scale;
        if (page?.QR is null) { qr?.Dispose(); qr = null; qrUrl = null; }
        var raster = new Bitmap(pixelWidth, pixelHeight, PixelFormat.Format32bppPArgb);
        using var g = Graphics.FromImage(raster); graphics = g;
        graphics.SmoothingMode = SmoothingMode.AntiAlias; graphics.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        graphics.InterpolationMode = InterpolationMode.HighQualityBicubic; graphics.ScaleTransform(scale, scale);
        float width = pixelWidth / scale, height = pixelHeight / scale;
        using (var background = new LinearGradientBrush(new PointF(0, 0), new PointF(width, height), Gray(0x242424), Gray(0x101010)))
        {
            background.InterpolationColors = new ColorBlend { Colors = [Gray(0x242424), Gray(0x141414), Gray(0x101010)], Positions = [0, .5f, 1] };
            graphics.FillRectangle(background, 0, 0, width, height);
        }
        if (shell.Page == Destination.Library) Library(width, height);
        else if (page is not null) Page(page, width, height);
        Chrome(page?.Title ?? "Libreria", width, height);
        return raster;
    }
    private void Library(float width, float height)
    {
        var state = graphics.Save(); graphics.SetClip(new RectangleF(105, 0, width - 134, height));
        foreach (var (game, _, r) in shell.Visible(width, height))
        {
            Round(r, Gray(game.Installed ? 0x24332f : 0x242a2d)); var cover = new Rect(r.X, r.Y, r.Width, r.Width * Shell.CoverRatio);
            var clipped = graphics.Save(); using var path = Rounded(cover, 10); graphics.SetClip(path, CombineMode.Intersect);
            Round(cover, Gray(0x20363a));
            var art = Artwork(game.Artwork);
            if (art is not null)
            {
                float fit = Math.Min(cover.Width / art.Width, cover.Height / art.Height);
                if (Math.Max(art.Width, art.Height) <= 128) fit = Math.Min(1, fit);
                graphics.DrawImage(art, cover.X + (cover.Width - art.Width * fit) / 2, cover.Y + (cover.Height - art.Height * fit) / 2, art.Width * fit, art.Height * fit);
            }
            else Icon("game", new(cover.X + cover.Width / 2 - 28, cover.Y + cover.Height / 2 - 28, 56, 56), Gray(0xc1d2ce, 180));
            if (!game.Installed) { using var shade = new SolidBrush(Color.FromArgb(56, 20, 20, 20)); graphics.FillRectangle(shade, R(cover)); }
            graphics.Restore(clipped);
            Round(new(cover.Right - 35, cover.Y + 9, 25, 25), Gray(0x101819, 210), 7);
            using (var brush = new SolidBrush(Gray(0xf0f6f3)))
                for (int y = 0; y < 2; y++) for (int x = 0; x < 2; x++) graphics.FillRectangle(brush, cover.Right - 29 + x * 8, cover.Y + 14 + y * 8, 6.5f, 6.5f);
            Text(game.Title, new(r.X + 10, cover.Bottom + 10, r.Width - 20, 23), 13, true);
            var hit = r.Intersect(shell.InteractionViewport(width, height));
            if (hit.Width > 0 && hit.Height > 0) shell.Hits.Add(new("game:" + game.Id, hit, game.Title));
            Feedback(r, "game:" + game.Id);
        }
        graphics.Restore(state);
        if (shell.Games.Count == 0)
        {
            var r = new Rect(112, 145, width - 148, 220); Round(r, Gray(0x222b30));
            Icon("game", new(136, 173, 38, 38), Gray(0xa2eec2));
            Text(shell.Query.Length == 0 ? "La tua libreria comincia qui" : "Nessun risultato", new(194, 172, width - 252, 32), 22, true);
            Text(shell.Query.Length == 0 ? "Collega uno store per vedere tutti i giochi posseduti, oppure importa un gioco installato." : "Prova un titolo o un ID differente.", new(136, 237, width - 196, 65), 15, color: Gray(0xb5c2c7));
            if (shell.Query.Length == 0) shell.Hits.Add(new("empty:import", r, "Importa un gioco"));
        }
    }
    private void Chrome(string title, float width, float height)
    {
        using (var dock = new SolidBrush(Gray(0x1b2226, 230))) graphics.FillRectangle(dock, 0, 0, 72, height);
        Button(new(13, 20, 46, 46), "nav:library", "Libreria", shell.Page == Destination.Library, "library");
        if (RunningGame is not null) Button(new(13, 80, 46, 46), "nav:resume", RunningGame, shell.Page == Destination.Game, "game");
        Button(new(13, height - 232, 46, 46), "nav:friends", "Amici", shell.Page == Destination.Friends, "friends");
        Button(new(13, height - 174, 46, 46), "nav:downloads", "Download", shell.Page == Destination.Downloads, "downloads");
        Button(new(13, height - 116, 46, 46), "nav:import", "Importa", false, "plus");
        Button(new(13, height - 58, 46, 46), "nav:settings", "Impostazioni", shell.Page == Destination.Settings, "settings");
        using (var fade = new LinearGradientBrush(new PointF(0, 0), new PointF(0, 84), Gray(0x0c1114, 128), Gray(0x0c1114, 0))) graphics.FillRectangle(fade, 72, 0, width - 72, 84);
        Text(title, new(112, 25, width - 493, 34), 23, true, Gray(0xe9f3ee));
        Text(ProfileName, new(width - 330, 29, 180, 27), 14, true);
        shell.Hits.Add(new("nav:profiles", new(width - 330, 21, 178, 38), "Profili")); Feedback(new(width - 330, 21, 178, 38), "nav:profiles");
        Button(new(width - 148, 21, 38, 38), "toolbar:friends", "Account", shell.Page == Destination.Friends, "profile");
        Text(Clock, new(width - 98, 28, 64, 25), 16, true);
        if (shell.Page == Destination.Library && shell.Query.Length > 0) Text("Risultati per “" + shell.Query + "”", new(112, 99, width - 258, 27), 18, true);
        if (shell.Error is { Length: > 0 } error)
        {
            using var fade = new LinearGradientBrush(new PointF(0, height - 55), new PointF(0, height), Color.Transparent, Gray(0x0c1114, 200));
            graphics.FillRectangle(fade, 72, height - 55, width - 72, 55); Text(error, new(112, height - 36, width - 148, 25), 12, color: Gray(0xf1b5a6));
        }
    }
    private void Page(CanvasPage page, float width, float height)
    {
        var state = graphics.Save(); graphics.SetClip(new RectangleF(105, 90, width - 134, height - 145));
        float y = 104 - page.Offset;
        if (page.Tabs is { Count: > 0 })
        {
            float x = 112;
            foreach (var tab in page.Tabs)
            {
                float w = Math.Max(76, graphics.MeasureString(tab.Title, Font(13, true)).Width + 24);
                Button(new(x, y, w, 38), tab.Id, tab.Title, tab.Id == page.SelectedTab); x += w + 8;
            }
            y += 64;
        }
        Text(page.Heading, new(112, y, width - 148, 42), 26, true); y += 54;
        if (page.Body.Length > 0) { Text(page.Body, new(112, y, width - 164, 92), 15, color: Gray(0xc2d1cf)); y += 106; }
        if (page.QR is { } url)
        {
            if (qrUrl != url) { qr?.Dispose(); qr = QRCodeGenerator.GenerateQrCode(url, QRCodeGenerator.ECCLevel.Q); qrUrl = url; }
            int count = qr!.ModuleMatrix.Count;
            float step = Math.Max(1, MathF.Floor(250 * drawingScale / count)) / drawingScale, size = count * step;
            float x = 112 + Math.Max(0, (width - 164 - size) / 2);
            using var white = new SolidBrush(Color.White); using var black = new SolidBrush(Color.Black);
            var mode = graphics.SmoothingMode; graphics.SmoothingMode = SmoothingMode.None;
            graphics.FillRectangle(white, x, y, size, size);
            for (int row = 0; row < count; row++) for (int col = 0; col < count; col++)
                if (qr.ModuleMatrix[row][col]) graphics.FillRectangle(black, x + col * step, y + row * step, step, step);
            graphics.SmoothingMode = mode; y += size + 20;
        }
        if (page.Field is not null)
        {
            Text(page.FieldLabel, new(112, y, width - 148, 25), 13, true, Gray(0x9db7ad)); y += 27;
            var rect = new Rect(112, y, width - 184, 42); Round(rect, Gray(0x202a2c), 8);
            Text(page.Field, new(124, y + 10, width - 210, 26), 15);
            shell.Hits.Add(new("field", rect, page.FieldLabel)); Feedback(rect, "field"); y += 60;
        }
        foreach (var field in page.Fields ?? [])
        {
            Text(field.Label, new(112, y, width - 148, 25), 13, true, Gray(0x9db7ad)); y += 27;
            var rect = new Rect(112, y, width - 184, 42); Round(rect, Gray(0x202a2c), 8);
            string value = field.Secret ? new string('●', field.Value.Length) : field.Value;
            Text(value, new(124, y + 10, width - 210, 26), 15);
            shell.Hits.Add(new(field.Id, rect, field.Label)); Feedback(rect, field.Id); y += 60;
        }
        float buttonX = 112;
        foreach (var action in page.Actions ?? [])
        {
            float w = Math.Max(120, graphics.MeasureString(action.Title, Font(14, true)).Width + 32);
            if (buttonX > 112 && buttonX + w > width - 36) { buttonX = 112; y += 50; }
            Button(new(buttonX, y, w, 40), action.Id, action.Title, enabled: action.Enabled); buttonX += w + 12;
        }
        if (page.Actions is { Count: > 0 }) y += 60;
        foreach (var row in page.Rows ?? [])
        {
            var rect = new Rect(112, y, width - 164, row.Subtitle.Length == 0 ? 44 : 62);
            if (rect.Bottom > 90 && rect.Y < height - 55)
            {
                Round(rect, Gray(0x20282a), 8); Text(row.Title, new(126, y + 8, width - 196, 24), 15, true);
                if (row.Subtitle.Length > 0) Text(row.Subtitle, new(126, y + 34, width - 196, 23), 12, color: Gray(0x9fb9af));
                shell.Hits.Add(new(row.Id, rect, row.Title)); Feedback(rect, row.Id);
            }
            y += rect.Height + 10;
        }
        MaximumPageOffset = Math.Max(0, y + page.Offset + 24 - (height - 55));
        graphics.Restore(state);
        // Clipped page rows must not remain interactive under the header/footer.
        var viewport = new Rect(105, 90, width - 134, height - 145);
        for (int i = shell.Hits.Count - 1; i >= 0; i--)
        {
            var clipped = shell.Hits[i].Bounds.Intersect(viewport);
            if (clipped.Width <= 0 || clipped.Height <= 0) shell.Hits.RemoveAt(i);
            else shell.Hits[i] = shell.Hits[i] with { Bounds = clipped };
        }
    }
    private Bitmap? Artwork(string? path)
    {
        if (path is null) return null;
        if (artwork.TryGetValue(path, out var cached)) return cached;
        try
        {
            using var source = Image.FromFile(path);
            float scale = Math.Min(1, 512f / Math.Max(source.Width, source.Height));
            var result = new Bitmap(source, Math.Max(1, (int)(source.Width * scale)), Math.Max(1, (int)(source.Height * scale)));
            if (artwork.Count >= 32) { var oldest = artwork.First(); oldest.Value.Dispose(); artwork.Remove(oldest.Key); }
            artwork[path] = result; return result;
        }
        catch (Exception e) when (e is IOException or ArgumentException or OutOfMemoryException) { return null; }
    }
    public void ReleaseArtwork() { foreach (var image in artwork.Values) image.Dispose(); artwork.Clear(); qr?.Dispose(); qr = null; qrUrl = null; }
    public void Dispose() { ReleaseArtwork(); foreach (var font in fonts.Values) font.Dispose(); }
}
