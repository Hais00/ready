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
    private bool disposed;
    public uint ProcessId { get; }
    private NativeGameSession(SafeFileHandle job, uint processId) { this.job = job; ProcessId = processId; }
    public static NativeGameSession Start(Game game, IReadOnlyList<string>? arguments = null)
    {
        if (game.Source != GameSource.Local || game.Executable is null) throw new InvalidOperationException("Un titolo Steam richiede il backend Steam autenticato.");
        var architecture = PeImage.ReadArchitecture(game.Executable);
        if (architecture == PeArchitecture.Unknown) throw new InvalidDataException("Eseguibile Windows non valido.");
        if (architecture == PeArchitecture.Arm64 && RuntimeInformation.OSArchitecture != Architecture.Arm64)
            throw new InvalidOperationException("Questo gioco ARM64 richiede Windows su ARM64.");
        var job = Native.CreateJobObjectW(0, null);
        if (job.IsInvalid) throw new Win32Exception();
        try
        {
            var limits = new Native.JobLimits(); limits.Basic.LimitFlags = 0x2000;
            if (!Native.SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf<Native.JobLimits>())) throw new Win32Exception();
            using var attributes = new JobAttributes(job);
            var startup = new Native.StartupInfoEx { Info = new() { Size = (uint)Marshal.SizeOf<Native.StartupInfoEx>() }, Attributes = attributes.List };
            var command = new StringBuilder(Quote(game.Executable));
            foreach (var argument in arguments ?? []) command.Append(' ').Append(Quote(argument));
            if (!Native.CreateProcessW(game.Executable, command, 0, 0, false, 0x00080004, 0,
                game.InstallDirectory, ref startup, out var process)) throw new Win32Exception();
            using var processHandle = new SafeFileHandle(process.Process, true);
            using var threadHandle = new SafeFileHandle(process.Thread, true);
            try
            {
                if (Native.ResumeThread(threadHandle) == uint.MaxValue) throw new Win32Exception();
                return new(job, process.ProcessId);
            }
            catch
            {
                Native.TerminateJobObject(job, 1);
                throw;
            }
        }
        catch { job.Dispose(); throw; }
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
    public void Dispose() { if (disposed) return; disposed = true; job.Dispose(); }
    private sealed class JobAttributes : IDisposable
    {
        public nint List { get; private set; }
        private nint handles;
        private bool initialized;
        public JobAttributes(SafeFileHandle job)
        {
            nuint size = 0; Native.InitializeProcThreadAttributeList(0, 1, 0, ref size);
            if (size == 0) throw new Win32Exception();
            List = Marshal.AllocHGlobal(checked((int)size));
            try
            {
                if (!Native.InitializeProcThreadAttributeList(List, 1, 0, ref size)) throw new Win32Exception();
                initialized = true; handles = Marshal.AllocHGlobal(nint.Size); Marshal.WriteIntPtr(handles, job.DangerousGetHandle());
                // PROC_THREAD_ATTRIBUTE_JOB_LIST: kernel admission is atomic, so a
                // launcher crash cannot strand an unassigned suspended child.
                if (!Native.UpdateProcThreadAttribute(List, 0, 0x0002000D, handles, (nuint)nint.Size, 0, 0)) throw new Win32Exception();
            }
            catch { Dispose(); throw; }
        }
        public void Dispose()
        {
            if (initialized) { Native.DeleteProcThreadAttributeList(List); initialized = false; }
            if (handles != 0) { Marshal.FreeHGlobal(handles); handles = 0; }
            if (List != 0) { Marshal.FreeHGlobal(List); List = 0; }
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
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern uint ResumeThread(SafeFileHandle thread);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool TerminateJobObject(SafeFileHandle job, uint exitCode);
    }
}
