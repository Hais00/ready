// SPDX-License-Identifier: GPL-3.0-only
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;

namespace Ready.Windows;

internal sealed class SteamCredential(string username, string refreshToken)
{
    public string Username { get; } = username;
    public string RefreshToken { get; } = refreshToken;
    public bool Valid => Username.Length is > 0 and <= 64 && Username.All(c => char.IsAsciiLetterOrDigit(c) || c == '_')
        && RefreshToken.Length is > 0 and <= 8192 && RefreshToken.All(c => c is >= '!' and <= '~');
    public override string ToString() => "[private Steam credential]";
}

// DPAPI defaults to the current Windows user, never LOCAL_MACHINE. Each profile
// has separate purpose entropy. Only encrypted bytes are written to disk.
internal sealed class SteamCredentialStore
{
    private readonly string folder;
    public SteamCredentialStore(string dataRoot)
    {
        folder = Path.Combine(dataRoot, "Credentials");
        var owner = WindowsIdentity.GetCurrent().User ?? throw new CryptographicException("credential_owner_unavailable");
        var security = new DirectorySecurity(); security.SetOwner(owner); security.SetAccessRuleProtection(true, false);
        foreach (var sid in new[] { owner, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null) })
            security.AddAccessRule(new(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        var directory = new DirectoryInfo(folder);
        if (directory.Exists && (directory.Attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("credential_directory_reparse_point");
        if (!directory.Exists) directory.Create(security); else directory.SetAccessControl(security);
    }
    private string FileName(string profile) => Path.Combine(folder, Guid.ParseExact(profile, "D").ToString("D") + ".steam.dpapi");
    private static byte[] Purpose(string profile) => Encoding.UTF8.GetBytes("Ready.Windows.Steam.v1:" + Guid.ParseExact(profile, "D").ToString("D"));
    public SteamCredential? Read(string profile)
    {
        string path = FileName(profile); if (!File.Exists(path)) return null;
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0 || new FileInfo(path).Length > 65536) throw new IOException("credential_file_invalid");
        byte[] cipher = File.ReadAllBytes(path), plain = Transform(cipher, Purpose(profile), false);
        try
        {
            using var json = JsonDocument.Parse(plain);
            var root = json.RootElement;
            if (root.GetProperty("schema").GetInt32() != 1 || root.GetProperty("profile").GetString() != profile) throw new CryptographicException("credential_profile_mismatch");
            var credential = new SteamCredential(root.GetProperty("username").GetString()!, root.GetProperty("refresh_token").GetString()!);
            if (!credential.Valid) throw new CryptographicException("credential_invalid");
            return credential;
        }
        catch (Exception error) when (error is JsonException or KeyNotFoundException or InvalidOperationException)
        { throw new CryptographicException("credential_record_invalid"); }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }
    public void Write(string profile, SteamCredential credential)
    {
        if (!credential.Valid) throw new ArgumentException("credential_invalid");
        byte[] plain = JsonSerializer.SerializeToUtf8Bytes(new { schema = 1, profile, username = credential.Username, refresh_token = credential.RefreshToken });
        byte[] cipher;
        try { cipher = Transform(plain, Purpose(profile), true); }
        finally { CryptographicOperations.ZeroMemory(plain); }
        string path = FileName(profile), temporary = path + "." + Guid.NewGuid().ToString("N") + ".partial";
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            { stream.Write(cipher); stream.Flush(true); }
            File.Move(temporary, path, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    public void Forget(string profile) { string path = FileName(profile); if (File.Exists(path)) File.Delete(path); }
    internal static unsafe byte[] Transform(byte[] input, byte[] purpose, bool protect)
    {
        fixed (byte* source = input, entropy = purpose)
        {
            var data = new Blob { Length = input.Length, Data = (nint)source };
            var extra = new Blob { Length = purpose.Length, Data = (nint)entropy };
            Blob output;
            bool ok = protect ? CryptProtectData(ref data, null, ref extra, 0, 0, 1, out output) : CryptUnprotectData(ref data, 0, ref extra, 0, 0, 1, out output);
            if (!ok) throw new CryptographicException("credential_protection_failed");
            try
            {
                if (output.Length is < 1 or > 65536) throw new CryptographicException("credential_protection_length");
                byte[] bytes = new byte[output.Length]; Marshal.Copy(output.Data, bytes, 0, bytes.Length); return bytes;
            }
            finally { if (output.Data != 0) { new Span<byte>((void*)output.Data, output.Length).Clear(); LocalFree(output.Data); } }
        }
    }
    [StructLayout(LayoutKind.Sequential)] private struct Blob { public int Length; public nint Data; }
    [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CryptProtectData(ref Blob data, string? description, ref Blob entropy, nint reserved, nint prompt, uint flags, out Blob output);
    [DllImport("crypt32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CryptUnprotectData(ref Blob data, nint description, ref Blob entropy, nint reserved, nint prompt, uint flags, out Blob output);
    [DllImport("kernel32.dll")] private static extern nint LocalFree(nint memory);
}
