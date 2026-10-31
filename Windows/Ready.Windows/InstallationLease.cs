// SPDX-License-Identifier: GPL-3.0-only
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

namespace Ready.Windows;

// File-sharing handles are the authority, never a saved PID. Under one short
// registry lock, overlapping ancestor/child paths are checked before admission.
internal sealed class InstallationLease : IDisposable
{
    private readonly FileStream lease;
    private readonly SafeFileHandle directory;
    public string PathName { get; }
    public IReadOnlyList<SafeFileHandle> Handles => [lease.SafeFileHandle, directory];
    private InstallationLease(string path, FileStream lease, SafeFileHandle directory) { PathName = path; this.lease = lease; this.directory = directory; }
    public static bool Overlaps(string a, string b) => a.Equals(b, StringComparison.OrdinalIgnoreCase) || a.StartsWith(b.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase) || b.StartsWith(a.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase);
    public static string Canonical(string path)
    {
        if (!System.IO.Path.IsPathFullyQualified(path) || path.StartsWith("\\\\", StringComparison.Ordinal)) throw new InvalidDataException("installation_path_invalid");
        path = System.IO.Path.GetFullPath(path).TrimEnd(System.IO.Path.DirectorySeparatorChar);
        if (System.IO.Path.GetPathRoot(path)!.TrimEnd('\\').Equals(path, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("installation_root_invalid");
        for (string? part = path; part is not null; part = System.IO.Path.GetDirectoryName(part))
            if (Directory.Exists(part) && (File.GetAttributes(part) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("installation_alias_invalid");
        var suffix = new Stack<string>(); string existing = path;
        while (!Directory.Exists(existing)) { suffix.Push(System.IO.Path.GetFileName(existing)); existing = System.IO.Path.GetDirectoryName(existing) ?? throw new InvalidDataException("installation_path_invalid"); }
        using var handle = CreateFileW(existing, 0, 7, 0, 3, 0x02200000, 0);
        if (handle.IsInvalid) throw new Win32Exception();
        var name = new StringBuilder(32768); uint length = GetFinalPathNameByHandleW(handle, name, (uint)name.Capacity, 0);
        if (length is 0 or >= 32768) throw new Win32Exception();
        string canonical = name.ToString();
        if (!canonical.StartsWith("\\\\?\\", StringComparison.Ordinal) || canonical.StartsWith("\\\\?\\UNC\\", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("installation_path_invalid");
        canonical = canonical[4..]; while (suffix.TryPop(out var part)) canonical = System.IO.Path.Combine(canonical, part);
        return canonical.TrimEnd('\\');
    }
    public static FileStream Exclusive(string path)
    {
        var clock = System.Diagnostics.Stopwatch.StartNew();
        while (true)
        {
            try { return new(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
            catch (IOException) when (clock.ElapsedMilliseconds < 3000) { Thread.Sleep(10); }
        }
    }
    public static InstallationLease Acquire(string dataRoot, string target, bool write)
    {
        target = Canonical(target); Directory.CreateDirectory(target);
        string root = System.IO.Path.Combine(dataRoot, "InstallLocks"); Directory.CreateDirectory(root);
        if ((File.GetAttributes(root) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("installation_lock_alias_invalid");
        using var gate = Exclusive(System.IO.Path.Combine(root, "registry.lock"));
        string registry = System.IO.Path.Combine(root, "registry.json");
        var paths = File.Exists(registry) ? JsonSerializer.Deserialize<List<string>>(File.ReadAllBytes(registry)) ?? throw new InvalidDataException("installation_registry_invalid") : [];
        if (paths.Count > 20000) throw new InvalidDataException("installation_registry_limit");
        string Lock(string path) => System.IO.Path.Combine(root, Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(path.ToUpperInvariant()))) + ".lock");
        foreach (string path in paths.Where(p => Overlaps(p, target)))
        {
            try { using var probe = new FileStream(Lock(path), FileMode.Open, write ? FileAccess.ReadWrite : FileAccess.Read, write ? FileShare.None : FileShare.Read); }
            catch (IOException) { throw new IOException("installation_busy"); }
        }
        string lockName = Lock(target);
        if (!File.Exists(lockName)) { using var created = new FileStream(lockName, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None); }
        var held = new FileStream(lockName, FileMode.Open, write ? FileAccess.ReadWrite : FileAccess.Read, write ? FileShare.None : FileShare.Read);
        SafeFileHandle? handle = null;
        try
        {
            handle = CreateFileW(target, 0, 3, 0, 3, 0x02200000, 0); // BACKUP_SEMANTICS | OPEN_REPARSE_POINT; no share-delete.
            if (handle.IsInvalid) { handle.Dispose(); throw new Win32Exception(); }
            if (!paths.Contains(target, StringComparer.OrdinalIgnoreCase))
            {
                paths.Add(target); Atomic(registry, paths);
            }
            return new(target, held, handle);
        }
        catch { handle?.Dispose(); held.Dispose(); throw; }
    }
    public static void Atomic<T>(string path, T value)
    {
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".partial";
        try
        {
            using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            { JsonSerializer.Serialize(file, value); file.Flush(true); }
            File.Move(temporary, path, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    public static void ValidateTree(string root)
    {
        Stack<string> directories = new(); directories.Push(root);
        while (directories.TryPop(out string? path))
        {
            foreach (string item in Directory.EnumerateFileSystemEntries(path))
            {
                var attributes = File.GetAttributes(item);
                if ((attributes & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("installation_alias_invalid");
                if ((attributes & FileAttributes.Directory) != 0) directories.Push(item);
                else
                {
                    using var file = CreateFileW(item, 0, 7, 0, 3, 0x00200000, 0);
                    if (file.IsInvalid || !GetFileInformationByHandle(file, out var info)) throw new Win32Exception();
                    if (info.Links != 1) throw new InvalidDataException("installation_hardlink_invalid");
                }
            }
        }
    }
    public void Dispose() { directory.Dispose(); lease.Dispose(); }
    [StructLayout(LayoutKind.Sequential)] private struct FileInfoNative
    { public uint Attributes, CreatedLow, CreatedHigh, AccessLow, AccessHigh, WriteLow, WriteHigh, Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, nint attributes, uint creation, uint flags, nint template);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInfoNative info);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint size, uint flags);
}
