// SPDX-License-Identifier: GPL-3.0-only
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
using Ready.Windows.Core;

namespace Ready.Windows;

// Assign the job atomically at process creation, before its first instruction.
// Closing/terminating the job affects only this session, including descendants.
internal sealed class NativeGameSession : IDisposable
{
    private readonly SafeFileHandle job;
    private readonly InstallationLease? installation;
    private bool disposed;
    public uint ProcessId { get; }
    private NativeGameSession(SafeFileHandle job, uint processId, InstallationLease? installation) { this.job = job; ProcessId = processId; this.installation = installation; }
    public static NativeGameSession Start(Game game, IReadOnlyList<string>? arguments = null, string? dataRoot = null)
    {
        if (game.Source != GameSource.Local || game.Executable is null) throw new InvalidOperationException("Un titolo Steam richiede il backend Steam autenticato.");
        var architecture = PeImage.ReadArchitecture(game.Executable);
        if (architecture == PeArchitecture.Unknown) throw new InvalidDataException("Eseguibile Windows non valido.");
        if (architecture == PeArchitecture.Arm64 && RuntimeInformation.OSArchitecture != Architecture.Arm64)
            throw new InvalidOperationException("Questo gioco ARM64 richiede Windows su ARM64.");
        var installation = dataRoot is null ? null : InstallationLease.Acquire(dataRoot, game.InstallDirectory, false);
        var job = Native.CreateJobObjectW(0, null);
        if (job.IsInvalid) { job.Dispose(); installation?.Dispose(); throw new Win32Exception(); }
        try
        {
            var limits = new Native.JobLimits(); limits.Basic.LimitFlags = 0x2000;
            if (!Native.SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf<Native.JobLimits>())) throw new Win32Exception();
            using var attributes = new JobAttributes(job, installation?.Handles ?? []);
            var startup = new Native.StartupInfoEx { Info = new() { Size = (uint)Marshal.SizeOf<Native.StartupInfoEx>() }, Attributes = attributes.List };
            var command = new StringBuilder(Quote(game.Executable));
            foreach (var argument in arguments ?? []) command.Append(' ').Append(Quote(argument));
            if (!Native.CreateProcessW(game.Executable, command, 0, 0, installation is not null, 0x00080004, 0,
                game.InstallDirectory, ref startup, out var process)) throw new Win32Exception();
            using var processHandle = new SafeFileHandle(process.Process, true);
            using var threadHandle = new SafeFileHandle(process.Thread, true);
            try
            {
                if (Native.ResumeThread(threadHandle) == uint.MaxValue) throw new Win32Exception();
                return new(job, process.ProcessId, installation);
            }
            catch
            {
                Native.TerminateJobObject(job, 1);
                throw;
            }
        }
        catch { job.Dispose(); installation?.Dispose(); throw; }
    }
    public static string Quote(string argument)
    {
        if (argument.Contains('\0')) throw new ArgumentException("Argomento con NUL.");
        var result = new StringBuilder("\""); int slashes = 0;
        foreach (char c in argument)
        {
            if (c == '\\') { slashes++; continue; }
            result.Append('\\', c == '"' ? slashes * 2 + 1 : slashes).Append(c); slashes = 0;
        }
        return result.Append('\\', slashes * 2).Append('"').ToString();
    }
    public uint ActiveProcesses
    {
        get
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (!Native.QueryInformationJobObject(job, 1, out var accounting, (uint)Marshal.SizeOf<Native.Accounting>(), 0)) throw new Win32Exception();
            return accounting.ActiveProcesses;
        }
    }
    public async Task WaitAsync(CancellationToken cancellation = default)
    { while (ActiveProcesses > 0) await Task.Delay(100, cancellation).ConfigureAwait(false); }
    public void Stop() { if (!disposed && !Native.TerminateJobObject(job, 0)) throw new Win32Exception(); }
    public void Dispose() { if (disposed) return; disposed = true; job.Dispose(); installation?.Dispose(); }
    private sealed class JobAttributes : IDisposable
    {
        public nint List { get; private set; }
        private nint handles;
        private nint inheritedHandles;
        private readonly List<SafeFileHandle> copies = [];
        private bool initialized;
        public JobAttributes(SafeFileHandle job, IReadOnlyList<SafeFileHandle> inherit)
        {
            uint count = inherit.Count == 0 ? 1u : 2u;
            nuint size = 0; Native.InitializeProcThreadAttributeList(0, count, 0, ref size);
            if (size == 0) throw new Win32Exception();
            List = Marshal.AllocHGlobal(checked((int)size));
            try
            {
                if (!Native.InitializeProcThreadAttributeList(List, count, 0, ref size)) throw new Win32Exception();
                initialized = true; handles = Marshal.AllocHGlobal(nint.Size); Marshal.WriteIntPtr(handles, job.DangerousGetHandle());
                // PROC_THREAD_ATTRIBUTE_JOB_LIST: kernel admission is atomic, so a
                // launcher crash cannot strand an unassigned suspended child.
                if (!Native.UpdateProcThreadAttribute(List, 0, 0x0002000D, handles, (nuint)nint.Size, 0, 0)) throw new Win32Exception();
                if (inherit.Count > 0)
                {
                    foreach (var source in inherit)
                    {
                        if (!Native.DuplicateHandle(Native.GetCurrentProcess(), source, Native.GetCurrentProcess(), out var copy, 0, true, 2)) throw new Win32Exception();
                        copies.Add(copy);
                    }
                    inheritedHandles = Marshal.AllocHGlobal(nint.Size * copies.Count); Marshal.Copy(copies.Select(h => h.DangerousGetHandle()).ToArray(), 0, inheritedHandles, copies.Count);
                    if (!Native.UpdateProcThreadAttribute(List, 0, 0x00020002, inheritedHandles, (nuint)(nint.Size * copies.Count), 0, 0)) throw new Win32Exception();
                }
            }
            catch { Dispose(); throw; }
        }
        public void Dispose()
        {
            if (initialized) { Native.DeleteProcThreadAttributeList(List); initialized = false; }
            if (handles != 0) { Marshal.FreeHGlobal(handles); handles = 0; }
            if (List != 0) { Marshal.FreeHGlobal(List); List = 0; }
            if (inheritedHandles != 0) { Marshal.FreeHGlobal(inheritedHandles); inheritedHandles = 0; }
            foreach (var copy in copies) copy.Dispose(); copies.Clear();
        }
    }
    private static class Native
    {
        [StructLayout(LayoutKind.Sequential)] internal struct BasicLimits
        { public long ProcessTime, JobTime; public uint LimitFlags; public nuint MinWorkingSet, MaxWorkingSet; public uint ActiveLimit; public nuint Affinity; public uint PriorityClass, SchedulingClass; }
        [StructLayout(LayoutKind.Sequential)] internal struct IoCounters
        { public ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes; }
        [StructLayout(LayoutKind.Sequential)] internal struct JobLimits
        { public BasicLimits Basic; public IoCounters Io; public nuint ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory; }
        [StructLayout(LayoutKind.Sequential)] internal struct Accounting
        { public long UserTime, KernelTime, PeriodUserTime, PeriodKernelTime; public uint PageFaults, TotalProcesses, ActiveProcesses, TerminatedProcesses; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] internal struct StartupInfo
        {
            public uint Size; public string? Reserved, Desktop, Title;
            public uint X, Y, XSize, YSize, XCountChars, YCountChars, FillAttribute, Flags;
            public ushort ShowWindow, Reserved2Size; public nint Reserved2, StdInput, StdOutput, StdError;
        }
        [StructLayout(LayoutKind.Sequential)] internal struct ProcessInfo
        { public nint Process, Thread; public uint ProcessId, ThreadId; }
        [StructLayout(LayoutKind.Sequential)] internal struct StartupInfoEx { public StartupInfo Info; public nint Attributes; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern SafeFileHandle CreateJobObjectW(nint attributes, string? name);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetInformationJobObject(SafeFileHandle job, int type, ref JobLimits info, uint length);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool QueryInformationJobObject(SafeFileHandle job, int type, out Accounting info, uint length, nint returnedLength);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool CreateProcessW(string app, StringBuilder command, nint processAttributes, nint threadAttributes, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint flags, nint environment, string directory, ref StartupInfoEx startup, out ProcessInfo info);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool InitializeProcThreadAttributeList(nint list, uint count, uint flags, ref nuint bytes);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool UpdateProcThreadAttribute(nint list, uint flags, nuint attribute, nint value, nuint bytes, nint previous, nint returned);
        [DllImport("kernel32.dll")] internal static extern void DeleteProcThreadAttributeList(nint list);
        [DllImport("kernel32.dll")] internal static extern nint GetCurrentProcess();
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool DuplicateHandle(nint sourceProcess, SafeFileHandle source, nint targetProcess, out SafeFileHandle target, uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint options);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern uint ResumeThread(SafeFileHandle thread);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool TerminateJobObject(SafeFileHandle job, uint exitCode);
    }
}
