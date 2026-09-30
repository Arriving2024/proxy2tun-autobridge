using System;
using System.Text;
using System.Diagnostics;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Proxy2Tun {
    // A suspended child is assigned to the kill-on-close job before executing.
    // The job handle is deliberately not inherited by the child.
    public sealed class OwnedProcess : IDisposable {
        IntPtr job, process;
        public int Id { get; private set; }
        public long StartFileTime { get; private set; }
        public bool HasExited { get { return process == IntPtr.Zero || WaitForSingleObject(process, 0) == 0; } }
        public OwnedProcess(string executable, string arguments, string directory) {
            try {
                job = CreateJobObject(IntPtr.Zero, null);
                if(job == IntPtr.Zero) Fail();
                var limits = new EXTENDED_LIMIT();
                limits.BasicLimitInformation.LimitFlags = 0x2000;
                int size = Marshal.SizeOf(limits);
                IntPtr buffer = Marshal.AllocHGlobal(size);
                try { Marshal.StructureToPtr(limits, buffer, false); if(!SetInformationJobObject(job, 9, buffer, (uint)size)) Fail(); }
                finally { Marshal.FreeHGlobal(buffer); }
                STARTUPINFO startup = new STARTUPINFO(); startup.cb = Marshal.SizeOf(startup);
                PROCESS_INFORMATION info;
                if(!CreateProcess(executable, new StringBuilder("\"" + executable + "\" " + arguments), IntPtr.Zero, IntPtr.Zero, false,
                    0x4 | 0x200, IntPtr.Zero, directory, ref startup, out info)) Fail();
                process = info.hProcess; Id = info.dwProcessId;
                try {
                    if(!AssignProcessToJobObject(job, process)) Fail();
                    long created, exited, kernel, user;
                    if(!GetProcessTimes(process, out created, out exited, out kernel, out user)) Fail();
                    StartFileTime = created;
                    if(ResumeThread(info.hThread) == 0xffffffff) Fail();
                } finally { CloseHandle(info.hThread); }
            } catch { Dispose(); throw; }
        }
        public bool StopGracefully(int timeoutMilliseconds) {
            if(HasExited) return true;
            // CTRL_BREAK targets only our CREATE_NEW_PROCESS_GROUP group.
            if(GenerateConsoleCtrlEvent(1, (uint)Id) && WaitForSingleObject(process, (uint)timeoutMilliseconds) == 0) return true;
            return false;
        }
        public void Dispose() {
            if(job != IntPtr.Zero) { CloseHandle(job); job = IntPtr.Zero; }
            if(process != IntPtr.Zero) {
                // Also handles assignment failure before the child has resumed.
                if(WaitForSingleObject(process, 0) != 0) TerminateProcess(process, 1);
                WaitForSingleObject(process, 5000); CloseHandle(process); process = IntPtr.Zero;
            }
            GC.SuppressFinalize(this);
        }
        ~OwnedProcess() { Dispose(); }
        // Verify creation time and full executable path on the same handle used to kill.
        public static bool StopVerified(int id, long expectedStart, string expectedPath) {
            IntPtr handle = OpenProcess(0x1000 | 0x1 | 0x100000, false, id);
            if(handle == IntPtr.Zero) return false;
            try {
                long created, exited, kernel, user;
                if(!GetProcessTimes(handle, out created, out exited, out kernel, out user) || created != expectedStart) return false;
                var path = new StringBuilder(32768); uint length = (uint)path.Capacity;
                if(!QueryFullProcessImageName(handle, 0, path, ref length) || !String.Equals(path.ToString(), expectedPath, StringComparison.OrdinalIgnoreCase)) return false;
                if(!TerminateProcess(handle, 1)) return false;
                return WaitForSingleObject(handle, 5000) == 0;
            } finally { CloseHandle(handle); }
        }
        static void Fail() { throw new Win32Exception(Marshal.GetLastWin32Error()); }
        [StructLayout(LayoutKind.Sequential)] struct BASIC_LIMIT { public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass, SchedulingClass; }
        [StructLayout(LayoutKind.Sequential)] struct IO_COUNTERS { public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount; }
        [StructLayout(LayoutKind.Sequential)] struct EXTENDED_LIMIT { public BASIC_LIMIT BasicLimitInformation; public IO_COUNTERS IoInfo; public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed; }
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct STARTUPINFO { public int cb; public string lpReserved, lpDesktop, lpTitle; public uint dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags; public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError; }
        [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcess(string app, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string directory, ref STARTUPINFO startup, out PROCESS_INFORMATION info);
        [DllImport("kernel32.dll", SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateProcess(IntPtr process, uint code);
        [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool GenerateConsoleCtrlEvent(uint type, uint group);
        [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int id);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessTimes(IntPtr process, out long created, out long exited, out long kernel, out long user);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder path, ref uint size);
    }
}
