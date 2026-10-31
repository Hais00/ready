// SPDX-License-Identifier: GPL-3.0-only
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;

namespace Ready.Windows;

internal sealed class SteamServiceException(string code) : Exception(code)
{
    public string Code { get; } = code;
}
internal sealed record SteamServiceEvent(string Type, string? RequestId, JsonElement Data)
{
    public override string ToString() => "[private Steam service event]";
}

// Owns exactly one helper and one immutable profile/generation. All credentials
// travel through anonymous stdin/stdout. Child stderr is drained and discarded.
internal sealed class SteamServiceProcess : IAsyncDisposable
{
    private sealed record Pending(string Operation, TaskCompletionSource<JsonElement> Completion, Action<JsonElement>? Page);
    private readonly Process process;
    private readonly string profile, generation = Guid.NewGuid().ToString("D");
    private readonly ConcurrentDictionary<string, Pending> pending = new();
    private readonly SemaphoreSlim writer = new(1, 1);
    private readonly CancellationTokenSource lifetime = new();
    private readonly Task reader, errors;
    private long sequence;
    private bool disposed;
    public event Action<SteamServiceEvent>? Received;
    public event Action<SteamCredential>? CredentialReceived;
    public int ProcessId => process.Id;
    public bool IsAlive => !disposed && !lifetime.IsCancellationRequested && !process.HasExited && !reader.IsCompleted;
    public SteamServiceProcess(string executable, string profile)
    {
        this.profile = Guid.ParseExact(profile, "D").ToString("D");
        if (!Path.IsPathFullyQualified(executable) || !File.Exists(executable)) throw new SteamServiceException("service_missing");
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = Path.GetDirectoryName(executable)! };
        start.ArgumentList.Add("--service");
        process = new Process { StartInfo = start };
        if (!process.Start()) throw new SteamServiceException("service_start_failed");
        reader = Task.Run(Read); errors = Task.Run(DiscardErrors);
    }
    public async Task<JsonElement> RequestAsync(string operation, object? options = null, SteamCredential? credential = null,
        CancellationToken cancellation = default, object? authentication = null, Action<JsonElement>? page = null)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!IsAlive) throw new SteamServiceException("service_closed");
        if (pending.Count >= 16) throw new SteamServiceException("busy");
        string id = Guid.NewGuid().ToString("D"); var completion = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        var entry = new Pending(operation, completion, page); if (!pending.TryAdd(id, entry)) throw new SteamServiceException("request_collision");
        // Closure is delivered through the request TCS, preserving the safe
        // protocol error instead of racing it with lifetime cancellation.
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(operation is "authenticate" or "library" ? TimeSpan.FromMinutes(4) : TimeSpan.FromSeconds(45));
        try
        {
            await Send(id, operation, options, credential is null ? authentication : new { username = credential.Username, refresh_token = credential.RefreshToken }, timeout.Token);
            authentication = null; credential = null;
            return await completion.Task.WaitAsync(timeout.Token);
        }
        catch (OperationCanceledException)
        {
            pending.TryRemove(id, out _); // Revoke authority before the cancel frame can race a credential event.
            if (!disposed && !lifetime.IsCancellationRequested)
                try
                {
                    using var cancelBudget = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); cancelBudget.CancelAfter(TimeSpan.FromSeconds(2));
                    await Send(Guid.NewGuid().ToString("D"), "cancel", new { requestID = id }, null, cancelBudget.Token).WaitAsync(cancelBudget.Token);
                }
                catch { }
            throw;
        }
        finally { pending.TryRemove(id, out _); }
    }
    private async Task Send(string id, string operation, object? options, object? credentials, CancellationToken cancellation)
    {
        byte[] frame = JsonSerializer.SerializeToUtf8Bytes(new { id, profileID = profile, profileGeneration = generation, operation, options = options ?? new { }, credentials = credentials ?? new { } });
        try
        {
            if (frame.Length >= 65536) throw new SteamServiceException("request_too_large");
            await writer.WaitAsync(cancellation);
            try
            {
                await process.StandardInput.BaseStream.WriteAsync(frame, cancellation);
                await process.StandardInput.BaseStream.WriteAsync(new byte[] { 10 }, cancellation);
                await process.StandardInput.BaseStream.FlushAsync(cancellation);
            }
            finally { writer.Release(); }
        }
        finally { CryptographicOperations.ZeroMemory(frame); }
    }
    private async Task<string?> ReadLine()
    {
        var text = new System.Text.StringBuilder(); char[] value = new char[1];
        while (await process.StandardOutput.ReadAsync(value.AsMemory(), lifetime.Token) > 0)
        {
            if (value[0] == '\n') return text.ToString().TrimEnd('\r');
            if (text.Length >= 4 * 1024 * 1024) throw new SteamServiceException("response_too_large");
            text.Append(value[0]);
        }
        if (text.Length > 0) throw new SteamServiceException("response_truncated");
        return null;
    }
    private async Task Read()
    {
        try
        {
            while (await ReadLine() is { } line)
            {
                using var document = JsonDocument.Parse(line, new JsonDocumentOptions { MaxDepth = 32 }); var root = document.RootElement;
                if (root.GetProperty("profileID").GetString() != profile || root.GetProperty("profileGeneration").GetString() != generation
                    || !root.GetProperty("sequence").TryGetInt64(out long next) || next <= sequence) throw new SteamServiceException("response_binding_invalid");
                sequence = next; string type = root.GetProperty("type").GetString()!;
                string? id = root.TryGetProperty("id", out var rid) && rid.ValueKind == JsonValueKind.String ? rid.GetString() : null;
                bool known = id is not null && pending.TryGetValue(id, out _);
                if (type == "credentials")
                {
                    if (!known || !pending.TryGetValue(id!, out var owner) || owner.Operation != "authenticate") continue;
                    var value = root.GetProperty("credentials");
                    var credential = new SteamCredential(value.GetProperty("username").GetString()!, value.GetProperty("refresh_token").GetString()!);
                    if (!credential.Valid) throw new SteamServiceException("credential_invalid");
                    CredentialReceived?.Invoke(credential); continue; // Never publish this frame as an ordinary UI event.
                }
                if (type is "qr" or "guard" or "library_page" && !known) continue;
                if (type is not ("state" or "heartbeat" or "persona" or "friends" or "qr" or "guard" or "library_page" or "result" or "error")) throw new SteamServiceException("response_type_invalid");
                var data = root.Clone();
                if (type == "library_page")
                { if (id is not null && pending.TryGetValue(id, out var owner) && owner.Operation == "library") owner.Page?.Invoke(data); continue; }
                if (type is "result" or "error")
                {
                    if (id is null || !pending.TryRemove(id, out var request)) continue;
                    try { Received?.Invoke(new(type, id, data)); }
                    catch { request.Completion.TrySetException(new SteamServiceException("service_event_failed")); throw; }
                    if (type == "error") request.Completion.TrySetException(new SteamServiceException(SafeCode(root)));
                    else request.Completion.TrySetResult(data);
                    continue;
                }
                Received?.Invoke(new(type, id, data));
            }
        }
        catch (SteamServiceException error) when (!disposed) { Fail(error.Code); }
        catch (Exception) when (!disposed) { Fail("service_protocol_closed"); }
        finally { lifetime.Cancel(); Fail("service_closed"); }
    }
    private static string SafeCode(JsonElement root)
    {
        string? code = root.TryGetProperty("code", out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
        return code is "authentication_required" or "authentication_failed" or "invalid_guard_response" or "not_online" or "network_error" or "timeout" or "cancelled" or "disconnected" or "busy" or "not_authorized" or "invalid_request" or "ownership_invalid_response" ? code : "steam_request_failed";
    }
    private async Task DiscardErrors()
    { try { char[] buffer = new char[4096]; while (await process.StandardError.ReadAsync(buffer.AsMemory(), lifetime.Token) != 0) Array.Clear(buffer); } catch (Exception) when (disposed || lifetime.IsCancellationRequested) { } }
    private void Fail(string code)
    { foreach (var pair in pending) if (pending.TryRemove(pair.Key, out var entry)) entry.Completion.TrySetException(new SteamServiceException(code)); }
    public async ValueTask DisposeAsync()
    {
        if (disposed) return;
        try { using var budget = new CancellationTokenSource(TimeSpan.FromSeconds(3)); await RequestAsync("shutdown", cancellation: budget.Token); } catch { }
        disposed = true;
        try { process.StandardInput.Close(); using var budget = new CancellationTokenSource(TimeSpan.FromSeconds(3)); await process.WaitForExitAsync(budget.Token); }
        catch { try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { } }
        lifetime.Cancel(); Fail("service_disposed");
        try { await Task.WhenAll(reader, errors).WaitAsync(TimeSpan.FromSeconds(2)); } catch { }
        process.Dispose(); lifetime.Dispose(); writer.Dispose();
    }
}
