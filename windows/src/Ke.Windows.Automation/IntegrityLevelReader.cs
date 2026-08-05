using System.Runtime.InteropServices;

namespace Ke.Windows.Automation;

internal sealed record IntegrityLevels(int SourceRid, int TargetRid);

internal interface IIntegrityLevelReader
{
    IntegrityLevels Read(uint targetProcessId, CancellationToken cancellationToken);
}

internal sealed class IntegrityLevelReader : IIntegrityLevelReader
{
    private const int ErrorInsufficientBuffer = 122;

    public IntegrityLevels Read(uint targetProcessId, CancellationToken cancellationToken)
    {
        var sourceRid = ReadProcessIntegrityRid(
            checked((uint)Environment.ProcessId),
            cancellationToken);
        var targetRid = ReadProcessIntegrityRid(targetProcessId, cancellationToken);
        return new(sourceRid, targetRid);
    }

    private static int ReadProcessIntegrityRid(
        uint processId,
        CancellationToken cancellationToken)
    {
        nint process = 0;
        nint token = 0;
        nint information = 0;
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            process = NativeMethods.OpenProcess(
                NativeMethods.ProcessQueryLimitedInformation,
                inheritHandle: false,
                processId);
            cancellationToken.ThrowIfCancellationRequested();
            EnsureHandle(process);

            cancellationToken.ThrowIfCancellationRequested();
            var opened = NativeMethods.OpenProcessToken(
                process,
                NativeMethods.TokenQuery,
                out token);
            cancellationToken.ThrowIfCancellationRequested();
            if (!opened)
            {
                throw Unavailable();
            }

            cancellationToken.ThrowIfCancellationRequested();
            var probed = NativeMethods.GetTokenInformation(
                token,
                NativeMethods.TokenIntegrityLevel,
                0,
                0,
                out var length);
            cancellationToken.ThrowIfCancellationRequested();
            if (probed ||
                length == 0 ||
                Marshal.GetLastWin32Error() != ErrorInsufficientBuffer)
            {
                throw Unavailable();
            }

            information = Marshal.AllocHGlobal(checked((int)length));
            cancellationToken.ThrowIfCancellationRequested();
            var read = NativeMethods.GetTokenInformation(
                token,
                NativeMethods.TokenIntegrityLevel,
                information,
                length,
                out _);
            cancellationToken.ThrowIfCancellationRequested();
            if (!read)
            {
                throw Unavailable();
            }

            var sid = Marshal.ReadIntPtr(information);
            if (sid == 0)
            {
                throw Unavailable();
            }

            cancellationToken.ThrowIfCancellationRequested();
            var countPointer = NativeMethods.GetSidSubAuthorityCount(sid);
            cancellationToken.ThrowIfCancellationRequested();
            if (countPointer == 0)
            {
                throw Unavailable();
            }

            var count = Marshal.ReadByte(countPointer);
            if (count == 0)
            {
                throw Unavailable();
            }

            cancellationToken.ThrowIfCancellationRequested();
            var ridPointer = NativeMethods.GetSidSubAuthority(sid, (uint)(count - 1));
            cancellationToken.ThrowIfCancellationRequested();
            if (ridPointer == 0)
            {
                throw Unavailable();
            }

            return Marshal.ReadInt32(ridPointer);
        }
        finally
        {
            if (information != 0)
            {
                Marshal.FreeHGlobal(information);
            }

            var closeFailed = false;
            if (token != 0)
            {
                closeFailed |= !NativeMethods.CloseHandle(token);
            }

            if (process != 0)
            {
                closeFailed |= !NativeMethods.CloseHandle(process);
            }

            if (closeFailed)
            {
                throw Unavailable();
            }
        }
    }

    private static void EnsureHandle(nint handle)
    {
        if (handle == 0 || handle == new nint(-1))
        {
            throw Unavailable();
        }
    }

    private static AutomationCaptureException Unavailable() =>
        new(Core.SendErrorCode.AutomationUnavailable);
}
