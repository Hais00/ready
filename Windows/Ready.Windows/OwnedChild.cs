// SPDX-License-Identifier: GPL-3.0-only
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Ready.Windows;

// Starts only an owned executable, atomically in its job. An explicit handle
// list carries private pipes and duplicated leases; unrelated handles never leak.
internal sealed class OwnedChild : IDisposable
{
    private readonly SafeFileHandle job, process;
    public FileStream Input { get; }
    public StreamReader Output { get; }
    public StreamReader Error { get; }
    public uint Id { get; }
    private bool disposed;
    private OwnedChild(SafeFileHandle job, SafeFileHandle process, uint id, SafeFileHandle input, SafeFileHandle output, SafeFileHandle error)
    {
        this.job = job; this.process = process; Id = id;
        Input = new(input, FileAccess.Write, 4096, false);
        Output = new(new FileStream(output, FileAccess.Read, 4096, false), Encoding.UTF8, false);
        Error = new(new FileStream(error, FileAccess.Read, 4096, false), Encoding.UTF8, false);
    }
    public static OwnedChild Start(string executable, IReadOnlyList<string> arguments, string directory,
        IReadOnlyDictionary<string, string> environment, IReadOnlyList<SafeFileHandle> inherited)
    {
        if (!Path.IsPathFullyQualified(executable) || !File.Exists(executable)) throw new FileNotFoundException("download_engine_missing");
        var job = Native.CreateJobObjectW(0, null); if (job.IsInvalid) { job.Dispose(); throw new Win32Exception(); }
        var parent = new List<SafeFileHandle>(); var child = new List<SafeFileHandle>();
        SafeFileHandle? process = null;
        try
        {
            var limits = new Native.JobLimits(); limits.Basic.LimitFlags = 0x2000;
            if (!Native.SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf<Native.JobLimits>())) throw new Win32Exception();
            var security = new Native.Security { Size = Marshal.SizeOf<Native.Security>(), Inherit = true };
            void Pipe(bool input)
            {
                if (!Native.CreatePipe(out var read, out var write, ref security, 0)) throw new Win32Exception();
                var mine = input ? write : read; var theirs = input ? read : write; parent.Add(mine); child.Add(theirs);
                if (!Native.SetHandleInformation(mine, 1, 0)) throw new Win32Exception();
            }
            Pipe(true); Pipe(false); Pipe(false);
            foreach (var handle in inherited)
            {
                if (!Native.DuplicateHandle(Native.GetCurrentProcess(), handle, Native.GetCurrentProcess(), out var copy, 0, true, 2)) throw new Win32Exception();
                child.Add(copy);
            }
            using var attributes = new Attributes(job, child);
            var startup = new Native.StartupEx { Info = new() { Size = (uint)Marshal.SizeOf<Native.StartupEx>(), Flags = 0x100,
                StdInput = child[0].DangerousGetHandle(), StdOutput = child[1].DangerousGetHandle(), StdError = child[2].DangerousGetHandle() }, Attributes = attributes.Pointer };
            var command = new StringBuilder(NativeGameSession.Quote(executable)); foreach (var arg in arguments) command.Append(' ').Append(NativeGameSession.Quote(arg));
            var vars = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (System.Collections.DictionaryEntry pair in Environment.GetEnvironmentVariables()) vars[(string)pair.Key] = (string)pair.Value!;
            foreach (var pair in environment) vars[pair.Key] = pair.Value;
            string block = string.Join('\0', vars.Select(v => v.Key + "=" + v.Value)) + "\0\0";
            nint env = Marshal.StringToHGlobalUni(block);
            Native.ProcessInfo info;
            try
            {
                if (!Native.CreateProcessW(executable, command, 0, 0, true, 0x08080404, env, directory, ref startup, out info)) throw new Win32Exception();
            }
            finally { Marshal.FreeHGlobal(env); }
            process = new(info.Process, true); using var thread = new SafeFileHandle(info.Thread, true);
            if (Native.ResumeThread(thread) == uint.MaxValue) throw new Win32Exception();
            var result = new OwnedChild(job, process, info.ProcessId, parent[0], parent[1], parent[2]);
            parent.Clear(); process = null; return result;
        }
        catch { Native.TerminateJobObject(job, 1); process?.Dispose(); job.Dispose(); throw; }
        finally { foreach (var handle in parent) handle.Dispose(); foreach (var handle in child) handle.Dispose(); }
    }
    public bool Exited => Native.WaitForSingleObject(process, 0) == 0;
    public int ExitCode { get { if (!Exited || !Native.GetExitCodeProcess(process, out uint code)) throw new InvalidOperationException("child_not_exited"); return unchecked((int)code); } }
    public async Task WaitAsync(CancellationToken cancellation = default)
    {
        while (true)
        {
            if (!Native.QueryInformationJobObject(job, 1, out var info, (uint)Marshal.SizeOf<Native.Accounting>(), 0)) throw new Win32Exception();
            if (info.ActiveProcesses == 0) return;
            await Task.Delay(25, cancellation).ConfigureAwait(false);
        }
    }
    public void Stop() { if (!disposed && !Native.TerminateJobObject(job, 1)) throw new Win32Exception(); }
    public void Dispose()
    { if (disposed) return; disposed = true; job.Dispose(); Input.Dispose(); Output.Dispose(); Error.Dispose(); process.Dispose(); }
    private sealed class Attributes : IDisposable
    {
        public nint Pointer { get; private set; }
        private nint jobs, handles; private bool initialized;
        public Attributes(SafeFileHandle job, IReadOnlyList<SafeFileHandle> inherited)
        {
            nuint bytes = 0; Native.InitializeProcThreadAttributeList(0, 2, 0, ref bytes); Pointer = Marshal.AllocHGlobal(checked((int)bytes));
            try
            {
                if (!Native.InitializeProcThreadAttributeList(Pointer, 2, 0, ref bytes)) throw new Win32Exception(); initialized = true;
                jobs = Marshal.AllocHGlobal(nint.Size); Marshal.WriteIntPtr(jobs, job.DangerousGetHandle());
                handles = Marshal.AllocHGlobal(nint.Size * inherited.Count); Marshal.Copy(inherited.Select(h => h.DangerousGetHandle()).ToArray(), 0, handles, inherited.Count);
                if (!Native.UpdateProcThreadAttribute(Pointer, 0, 0x0002000D, jobs, (nuint)nint.Size, 0, 0)
                    || !Native.UpdateProcThreadAttribute(Pointer, 0, 0x00020002, handles, (nuint)(nint.Size * inherited.Count), 0, 0)) throw new Win32Exception();
            }
            catch { Dispose(); throw; }
        }
        public void Dispose()
        { if (initialized) { Native.DeleteProcThreadAttributeList(Pointer); initialized = false; } if (Pointer != 0) Marshal.FreeHGlobal(Pointer); if (jobs != 0) Marshal.FreeHGlobal(jobs); if (handles != 0) Marshal.FreeHGlobal(handles); Pointer = jobs = handles = 0; }
    }
    private static class Native
    {
        [StructLayout(LayoutKind.Sequential)] internal struct Security { public int Size; public nint Descriptor; [MarshalAs(UnmanagedType.Bool)] public bool Inherit; }
        [StructLayout(LayoutKind.Sequential)] internal struct BasicLimits { public long ProcessTime, JobTime; public uint LimitFlags; public nuint MinWorkingSet, MaxWorkingSet; public uint ActiveLimit; public nuint Affinity; public uint Priority, Scheduling; }
        [StructLayout(LayoutKind.Sequential)] internal struct IoCounters { public ulong Read, Write, Other, ReadBytes, WriteBytes, OtherBytes; }
        [StructLayout(LayoutKind.Sequential)] internal struct JobLimits { public BasicLimits Basic; public IoCounters Io; public nuint ProcessMemory, JobMemory, PeakProcess, PeakJob; }
        [StructLayout(LayoutKind.Sequential)] internal struct Accounting { public long User, Kernel, PeriodUser, PeriodKernel; public uint Faults, Total, ActiveProcesses, Terminated; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] internal struct Startup { public uint Size; public string? Reserved, Desktop, Title; public uint X, Y, Width, Height, XChars, YChars, Fill, Flags; public ushort Show, ReservedSize; public nint Reserved2, StdInput, StdOutput, StdError; }
        [StructLayout(LayoutKind.Sequential)] internal struct StartupEx { public Startup Info; public nint Attributes; }
        [StructLayout(LayoutKind.Sequential)] internal struct ProcessInfo { public nint Process, Thread; public uint ProcessId, ThreadId; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern SafeFileHandle CreateJobObjectW(nint attributes, string? name);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetInformationJobObject(SafeFileHandle job, int type, ref JobLimits info, uint bytes);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool QueryInformationJobObject(SafeFileHandle job, int type, out Accounting info, uint bytes, nint length);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool TerminateJobObject(SafeFileHandle job, uint code);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool CreatePipe(out SafeFileHandle read, out SafeFileHandle write, ref Security security, uint size);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetHandleInformation(SafeFileHandle handle, uint mask, uint flags);
        [DllImport("kernel32.dll")] internal static extern nint GetCurrentProcess();
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool DuplicateHandle(nint sourceProcess, SafeFileHandle source, nint targetProcess, out SafeFileHandle target, uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint options);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool InitializeProcThreadAttributeList(nint list, uint count, uint flags, ref nuint bytes);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool UpdateProcThreadAttribute(nint list, uint flags, nuint attribute, nint value, nuint bytes, nint previous, nint length);
        [DllImport("kernel32.dll")] internal static extern void DeleteProcThreadAttributeList(nint list);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool CreateProcessW(string file, StringBuilder command, nint pa, nint ta, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint flags, nint env, string directory, ref StartupEx startup, out ProcessInfo info);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern uint ResumeThread(SafeFileHandle thread);
        [DllImport("kernel32.dll")] internal static extern uint WaitForSingleObject(SafeFileHandle handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GetExitCodeProcess(SafeFileHandle handle, out uint code);
    }
}
