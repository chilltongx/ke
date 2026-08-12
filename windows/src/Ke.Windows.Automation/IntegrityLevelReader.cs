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
        var cancellationObserved = false;
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
            var probeError = Marshal.GetLastWin32Error();
            cancellationToken.ThrowIfCancellationRequested();
            if (probed ||
                probeError != ErrorInsufficientBuffer)
            {
                throw Unavailable();
            }

            var allocatedLength = IntegrityBufferParser.ValidateProbeLength(length);
            information = Marshal.AllocHGlobal(allocatedLength);
            cancellationToken.ThrowIfCancellationRequested();
            var read = NativeMethods.GetTokenInformation(
                token,
                NativeMethods.TokenIntegrityLevel,
                information,
                length,
                out var returnedLength);
            cancellationToken.ThrowIfCancellationRequested();
            if (!read)
            {
                throw Unavailable();
            }

            var parser = IntegrityBufferParser.Create(
                information,
                allocatedLength,
                returnedLength);
            var sid = parser.ReadSidPointer();

            cancellationToken.ThrowIfCancellationRequested();
            var countPointer = NativeMethods.GetSidSubAuthorityCount(sid);
            cancellationToken.ThrowIfCancellationRequested();
            var count = parser.ReadSubAuthorityCount(sid, countPointer);

            cancellationToken.ThrowIfCancellationRequested();
            var ridPointer = NativeMethods.GetSidSubAuthority(sid, (uint)(count - 1));
            cancellationToken.ThrowIfCancellationRequested();
            return parser.ReadRid(sid, count, ridPointer);
        }
        catch (OperationCanceledException)
        {
            cancellationObserved = true;
            throw;
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

            if (closeFailed && !cancellationObserved)
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

internal sealed class IntegrityBufferParser
{
    internal const int MinimumLength = 28;
    internal const int MaximumLength = 65536;

    private const int SidHeaderLength = 8;
    private const int RidLength = sizeof(int);
    private const byte MaximumSubAuthorityCount = 15;

    private readonly nint _information;
    private readonly int _returnedLength;

    private IntegrityBufferParser(nint information, int returnedLength)
    {
        _information = information;
        _returnedLength = returnedLength;
    }

    internal static int ValidateProbeLength(uint length)
    {
        if (length < MinimumLength || length > MaximumLength)
        {
            throw Unavailable();
        }

        try
        {
            return checked((int)length);
        }
        catch (OverflowException exception)
        {
            throw Unavailable(exception);
        }
    }

    internal static IntegrityBufferParser Create(
        nint information,
        int allocatedLength,
        uint returnedLength)
    {
        if (information == 0 ||
            allocatedLength < MinimumLength ||
            allocatedLength > MaximumLength)
        {
            throw Unavailable();
        }

        var validLength = ValidateProbeLength(returnedLength);
        if (validLength > allocatedLength)
        {
            throw Unavailable();
        }

        return new(information, validLength);
    }

    internal nint ReadSidPointer()
    {
        EnsureReadable(_information, IntPtr.Size);
        var sid = Marshal.ReadIntPtr(_information);
        EnsureReadable(sid, SidHeaderLength);
        return sid;
    }

    internal byte ReadSubAuthorityCount(nint sid, nint countPointer)
    {
        EnsureReadable(sid, SidHeaderLength);
        var expectedCountPointer = Add(sid, 1);
        if (countPointer != expectedCountPointer)
        {
            throw Unavailable();
        }

        EnsureReadable(countPointer, sizeof(byte));
        var count = Marshal.ReadByte(countPointer);
        if (count is 0 or > MaximumSubAuthorityCount)
        {
            throw Unavailable();
        }

        var sidLength = checked(SidHeaderLength + (count * RidLength));
        EnsureReadable(sid, sidLength);
        return count;
    }

    internal int ReadRid(nint sid, byte count, nint ridPointer)
    {
        if (count is 0 or > MaximumSubAuthorityCount)
        {
            throw Unavailable();
        }

        var sidLength = checked(SidHeaderLength + (count * RidLength));
        EnsureReadable(sid, sidLength);
        var expectedRidPointer = Add(
            sid,
            checked(SidHeaderLength + ((count - 1) * RidLength)));
        if (ridPointer != expectedRidPointer)
        {
            throw Unavailable();
        }

        EnsureReadable(ridPointer, RidLength);
        return Marshal.ReadInt32(ridPointer);
    }

    private void EnsureReadable(nint pointer, int byteCount)
    {
        if (pointer == 0 || byteCount <= 0)
        {
            throw Unavailable();
        }

        var start = unchecked((ulong)_information.ToInt64());
        var address = unchecked((ulong)pointer.ToInt64());
        if (address < start)
        {
            throw Unavailable();
        }

        var offset = address - start;
        if (offset > (ulong)_returnedLength ||
            (ulong)byteCount > (ulong)_returnedLength - offset)
        {
            throw Unavailable();
        }
    }

    private static nint Add(nint pointer, int offset)
    {
        try
        {
            return new nint(checked(pointer.ToInt64() + offset));
        }
        catch (OverflowException exception)
        {
            throw Unavailable(exception);
        }
    }

    private static AutomationCaptureException Unavailable(Exception? innerException = null) =>
        innerException is null
            ? new(Core.SendErrorCode.AutomationUnavailable)
            : new(Core.SendErrorCode.AutomationUnavailable, innerException);
}
