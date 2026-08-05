using System.Runtime.InteropServices;
using System.Text;

namespace Ke.Windows.Automation;

internal static class NativeMethods
{
    internal const uint ProcessQueryLimitedInformation = 0x1000;
    internal const uint TokenQuery = 0x0008;
    internal const int TokenIntegrityLevel = 25;

    [DllImport("user32.dll")]
    internal static extern nint GetForegroundWindow();

    [DllImport("user32.dll")]
    internal static extern uint GetWindowThreadProcessId(nint hwnd, out uint processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern nint OpenProcess(uint access, bool inheritHandle, uint processId);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    internal static extern bool QueryFullProcessImageName(nint process, uint flags, StringBuilder path, ref uint size);

    [DllImport("advapi32.dll", SetLastError = true)]
    internal static extern bool OpenProcessToken(nint process, uint access, out nint token);

    [DllImport("advapi32.dll", SetLastError = true)]
    internal static extern bool GetTokenInformation(
        nint token,
        int tokenInformationClass,
        nint information,
        uint length,
        out uint returnLength);

    [DllImport("advapi32.dll")]
    internal static extern nint GetSidSubAuthority(nint sid, uint index);

    [DllImport("advapi32.dll")]
    internal static extern nint GetSidSubAuthorityCount(nint sid);

    [DllImport("kernel32.dll")]
    internal static extern bool CloseHandle(nint handle);
}
