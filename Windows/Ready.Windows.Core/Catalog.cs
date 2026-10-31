// SPDX-License-Identifier: GPL-3.0-only
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Ready.Windows.Core;

public enum GameSource { Local, Steam }
public enum PeArchitecture { X86, X64, Arm64, Unknown }
public sealed record Game(string Id, string Title, GameSource Source, string InstallDirectory,
    string? Executable = null, uint? AppId = null, string? Artwork = null, PeArchitecture Architecture = PeArchitecture.Unknown, bool Installed = true);
public sealed record Profile(string Id, string Name);
public sealed record Library(int Schema, string ActiveProfile, List<Profile> Profiles, Dictionary<string, List<Game>> Games)
{
    public static Library Empty()
    {
        const string id = "00000000-0000-4000-8000-000000000001";
        return new(1, id, [new(id, "Giocatore")], new() { [id] = [] });
    }
    [JsonIgnore] public IEnumerable<Game> ActiveGames => Games.GetValueOrDefault(ActiveProfile) ?? [];
    public Library AddProfile(string name)
    {
        name = name.Trim();
        if (name.Length is < 1 or > 64) throw new ArgumentException("Il nome deve contenere da 1 a 64 caratteri.");
        if (Profiles.Any(p => p.Name.Equals(name, StringComparison.CurrentCultureIgnoreCase))) throw new ArgumentException("Questo profilo esiste già.");
        var id = Guid.NewGuid().ToString("D");
        return this with { ActiveProfile = id, Profiles = [.. Profiles, new(id, name)], Games = new(Games) { [id] = [] } };
    }
    public Library Import(string path)
    {
        path = Path.GetFullPath(path);
        if (!path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) || !File.Exists(path)) throw new ArgumentException("Seleziona un eseguibile Windows esistente (.exe).");
        var architecture = PeImage.ReadArchitecture(path);
        if (architecture == PeArchitecture.Unknown) throw new ArgumentException("Il file non è un eseguibile PE x86, x64 o ARM64 supportato.");
        var existing = ActiveGames.FirstOrDefault(g => string.Equals(g.Executable, path, StringComparison.OrdinalIgnoreCase));
        var game = existing ?? new(Guid.NewGuid().ToString("N"), Path.GetFileNameWithoutExtension(path), GameSource.Local,
            Path.GetDirectoryName(path)!, path, Architecture: architecture);
        return this with { Games = new(Games) { [ActiveProfile] = [.. ActiveGames.Where(g => g.Id != game.Id), game] } };
    }
}

public sealed class LibraryStore
{
    public string Root { get; }
    private string PathName => Path.Combine(Root, "library-windows.json");
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };
    public LibraryStore(string root)
    {
        if (!Path.IsPathFullyQualified(root)) throw new ArgumentException("La cartella dati deve essere un percorso assoluto.");
        Root = Path.GetFullPath(root); Directory.CreateDirectory(Root);
    }
    public Library Load()
    {
        if (!File.Exists(PathName)) return Library.Empty();
        var library = JsonSerializer.Deserialize<Library>(File.ReadAllBytes(PathName), Json) ?? throw new InvalidDataException("Libreria vuota.");
        if (library.Schema != 1 || library.Profiles.Count == 0 || !library.Profiles.Any(p => p.Id == library.ActiveProfile)
            || library.Profiles.Select(p => p.Id).Distinct().Count() != library.Profiles.Count || !library.Games.ContainsKey(library.ActiveProfile))
            throw new InvalidDataException("Il formato della libreria non è supportato. Il file originale è stato conservato.");
        return library;
    }
    public void Save(Library library)
    {
        var temp = PathName + "." + Guid.NewGuid().ToString("N") + ".partial";
        try
        {
            using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            { JsonSerializer.Serialize(stream, library, Json); stream.Flush(true); }
            File.Move(temp, PathName, true);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
}

public static class PeImage
{
    public static PeArchitecture ReadArchitecture(string path)
    {
        using var stream = File.OpenRead(path); using var reader = new BinaryReader(stream);
        if (stream.Length < 64 || reader.ReadUInt16() != 0x5A4D) return PeArchitecture.Unknown;
        stream.Position = 0x3C; uint offset = reader.ReadUInt32();
        if (offset < 64 || (long)offset + 24 > stream.Length) return PeArchitecture.Unknown;
        stream.Position = offset;
        if (reader.ReadUInt32() != 0x00004550) return PeArchitecture.Unknown;
        var machine = reader.ReadUInt16();
        stream.Position = offset + 22;
        var flags = reader.ReadUInt16();
        if ((flags & 0x0002) == 0 || (flags & 0x2000) != 0) return PeArchitecture.Unknown; // executable, not DLL
        return machine switch { 0x014c => PeArchitecture.X86, 0x8664 => PeArchitecture.X64, 0xaa64 => PeArchitecture.Arm64, _ => PeArchitecture.Unknown };
    }
}
