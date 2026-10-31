// SPDX-License-Identifier: GPL-3.0-only
namespace Ready.Windows.Core;

public enum Destination { Library, Game, Friends, Downloads, Settings, Profiles, Import, Search, Install }
public readonly record struct Rect(float X, float Y, float Width, float Height)
{
    public float Right => X + Width;
    public float Bottom => Y + Height;
    public bool Contains(float x, float y) => x >= X && x < Right && y >= Y && y < Bottom;
    public Rect Intersect(Rect r) => new(Math.Max(X, r.X), Math.Max(Y, r.Y),
        Math.Max(0, Math.Min(Right, r.Right) - Math.Max(X, r.X)),
        Math.Max(0, Math.Min(Bottom, r.Bottom) - Math.Max(Y, r.Y)));
}
public sealed record Hit(string Id, Rect Bounds, string Label);

// Port of ReadyShellStyle, LibraryCardMetrics and MetalCanvas.updateGridGeometry.
// Coordinates are logical, top-down units; the renderer applies the window DPI once.
public sealed class Shell
{
    public const float DockWidth = 72, ContentLeft = 112, HeaderHeight = 84, Gap = 18;
    public const float CoverRatio = 1.5f, TitleHeight = 42, EdgePadding = 7;
    public Destination Page { get; private set; } = Destination.Library;
    public string Query { get; private set; } = "";
    public string? Hover { get; private set; }
    public string? Pressed { get; private set; }
    public string? Focus { get; set; }
    public string? Error { get; set; }
    public float Scroll { get; private set; }
    public List<Hit> Hits { get; } = [];
    public IReadOnlyList<Game> Games { get; private set; } = [];
    public int Columns(float width) => Math.Max(1, (int)((width - 148 + Gap) / 178));
    public float CardWidth(float width) => MathF.Floor((width - 148 - Gap * (Columns(width) - 1)) / Columns(width));
    public float CardHeight(float width) => CardWidth(width) * CoverRatio + TitleHeight;
    public float TopInset => Query.Length == 0 ? 96 : 136;
    public float MaximumScroll(float width, float height) => Math.Max(0,
        TopInset + Math.Max(0, ((Games.Count + Columns(width) - 1) / Columns(width)) * (CardHeight(width) + Gap) - Gap) + 2 * EdgePadding - height);
    public Rect Card(int index, float width) => new(ContentLeft + index % Columns(width) * (CardWidth(width) + Gap),
        TopInset + EdgePadding + index / Columns(width) * (CardHeight(width) + Gap) - Scroll, CardWidth(width), CardHeight(width));
    public Rect InteractionViewport(float width, float height) => new(105, Query.Length == 0 ? HeaderHeight : 130,
        width - 134, Math.Max(0, height - (Query.Length == 0 ? HeaderHeight : 130) - (Error is null ? 0 : 55)));
    public IEnumerable<(Game Game, int Index, Rect Bounds)> Visible(float width, float height)
    {
        var stride = CardHeight(width) + Gap;
        var first = Math.Max(0, (int)MathF.Floor((Scroll - TopInset - EdgePadding) / stride)) * Columns(width);
        var end = Math.Min(Games.Count, Math.Max(first, (int)MathF.Ceiling((Scroll + height - TopInset - EdgePadding) / stride) * Columns(width)));
        for (int i = first; i < end; ++i) yield return (Games[i], i, Card(i, width));
    }
    public void SetCatalog(IEnumerable<Game> games, string query)
    {
        Query = query;
        Games = games.Where(g => query.Length == 0 || g.Title.Contains(query, StringComparison.CurrentCultureIgnoreCase)
            || g.Id.Contains(query, StringComparison.OrdinalIgnoreCase)).OrderBy(g => g.Title, StringComparer.CurrentCultureIgnoreCase).ToArray();
        Scroll = 0; ClearInteraction();
    }
    public void Navigate(Destination page) { Page = page; ClearInteraction(); }
    public void ClearInteraction() { Hits.Clear(); Hover = Pressed = Focus = null; }
    public void ScrollBy(float delta, float width, float height)
    {
        if (Page != Destination.Library || !float.IsFinite(delta)) return;
        Scroll = Math.Clamp(Scroll + delta, 0, MaximumScroll(width, height));
        // Cancel a press when its card moves under the pointer.
        Pressed = Hover = null;
    }
    public Hit? At(float x, float y) => Hits.LastOrDefault(h => h.Bounds.Contains(x, y));
    public void Move(float x, float y) => Hover = At(x, y)?.Id;
    public void Down(float x, float y) { Move(x, y); Pressed = Hover; }
    public string? Up(float x, float y)
    {
        Move(x, y); var action = Pressed is not null && Hover == Pressed ? Pressed : null; Pressed = null; return action;
    }
    public void CycleFocus(bool backwards)
    {
        if (Hits.Count == 0) { Focus = null; return; }
        int current = Hits.FindIndex(h => h.Id == Focus);
        Focus = Hits[(current + (backwards ? Hits.Count - 1 : 1) + Hits.Count) % Hits.Count].Id;
    }
    public void Reveal(string id, float width, float height)
    {
        var i = Games.ToList().FindIndex(g => "game:" + g.Id == id);
        if (i < 0) return;
        var r = Card(i, width); var viewport = InteractionViewport(width, height);
        var delta = i < Columns(width) ? -Scroll : r.Y < viewport.Y ? r.Y - viewport.Y : r.Bottom > viewport.Bottom ? r.Bottom - viewport.Bottom : 0;
        ScrollBy(delta, width, height); Focus = id;
    }
}
