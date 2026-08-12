using System.IO;
using System.Text;
using Ke.Windows.Core;

namespace Ke.Windows.Automation;

public sealed record CaptureResult(FocusSnapshot? Snapshot, SendErrorCode? Error)
{
    public static CaptureResult Success(FocusSnapshot snapshot) => new(snapshot, null);

    public static CaptureResult Failure(SendErrorCode error) => new(null, error);
}

public interface IFocusSnapshotProvider
{
    CaptureResult Capture(CancellationToken cancellationToken);
}

internal sealed class AutomationCaptureException : Exception
{
    public AutomationCaptureException(SendErrorCode error)
    {
        Error = error;
    }

    public AutomationCaptureException(SendErrorCode error, Exception innerException)
        : base("Windows automation capture failed.", innerException)
    {
        Error = error;
    }

    public SendErrorCode Error { get; }
}

internal interface IForegroundWindowReader
{
    nint GetForegroundWindow(CancellationToken cancellationToken);

    uint GetProcessId(nint window, CancellationToken cancellationToken);

    string GetProcessImagePath(uint targetProcessId, CancellationToken cancellationToken);
}

public sealed class FocusSnapshotProvider : IFocusSnapshotProvider
{
    private readonly IForegroundWindowReader _foreground;
    private readonly IIntegrityLevelReader _integrity;
    private readonly IUiAutomationTreeReader _automation;

    public FocusSnapshotProvider()
        : this(
            new ForegroundWindowReader(),
            new IntegrityLevelReader(),
            new UiAutomationTreeReader())
    {
    }

    internal FocusSnapshotProvider(
        IForegroundWindowReader foreground,
        IIntegrityLevelReader integrity,
        IUiAutomationTreeReader automation)
    {
        _foreground = foreground;
        _integrity = integrity;
        _automation = automation;
    }

    public CaptureResult Capture(CancellationToken cancellationToken)
    {
        try
        {
            var hwnd = Call(cancellationToken, () => _foreground.GetForegroundWindow(cancellationToken));
            var processId = Call(
                cancellationToken,
                () => _foreground.GetProcessId(hwnd, cancellationToken));
            var imagePath = Call(
                cancellationToken,
                () => _foreground.GetProcessImagePath(processId, cancellationToken));
            var imageName = Path.GetFileName(imagePath);
            if (string.IsNullOrWhiteSpace(imageName))
            {
                throw new AutomationCaptureException(SendErrorCode.AutomationUnavailable);
            }

            var levels = Call(
                cancellationToken,
                () => _integrity.Read(processId, cancellationToken));
            if (levels.TargetRid > levels.SourceRid)
            {
                return CaptureResult.Failure(SendErrorCode.ElevatedTarget);
            }

            var automation = Call(
                cancellationToken,
                () => _automation.Read(cancellationToken));
            return CaptureResult.Success(new FocusSnapshot(
                hwnd,
                processId,
                imageName,
                levels.SourceRid,
                levels.TargetRid,
                automation.Focused,
                automation.Ancestors,
                automation.Nearby));
        }
        catch (OperationCanceledException)
        {
            return CaptureResult.Failure(SendErrorCode.AutomationTimeout);
        }
        catch (AutomationCaptureException exception)
        {
            return CaptureResult.Failure(exception.Error);
        }
    }

    private static T Call<T>(CancellationToken cancellationToken, Func<T> call)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var result = call();
        cancellationToken.ThrowIfCancellationRequested();
        return result;
    }

    private sealed class ForegroundWindowReader : IForegroundWindowReader
    {
        public nint GetForegroundWindow(CancellationToken cancellationToken)
        {
            var hwnd = NativeCall(cancellationToken, NativeMethods.GetForegroundWindow);
            return hwnd == 0 ? throw Unavailable() : hwnd;
        }

        public uint GetProcessId(nint window, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var threadId = NativeMethods.GetWindowThreadProcessId(window, out var processId);
            cancellationToken.ThrowIfCancellationRequested();
            return threadId == 0 || processId == 0
                ? throw Unavailable()
                : processId;
        }

        public string GetProcessImagePath(
            uint targetProcessId,
            CancellationToken cancellationToken)
        {
            nint process = 0;
            try
            {
                cancellationToken.ThrowIfCancellationRequested();
                process = NativeMethods.OpenProcess(
                    NativeMethods.ProcessQueryLimitedInformation,
                    inheritHandle: false,
                    targetProcessId);
                cancellationToken.ThrowIfCancellationRequested();
                if (process == 0 || process == new nint(-1))
                {
                    throw Unavailable();
                }

                const int capacity = 32768;
                var path = new StringBuilder(capacity);
                uint length = capacity;
                cancellationToken.ThrowIfCancellationRequested();
                var read = NativeMethods.QueryFullProcessImageName(
                    process,
                    flags: 0,
                    path,
                    ref length);
                cancellationToken.ThrowIfCancellationRequested();
                if (!read || length == 0 || length > capacity)
                {
                    throw Unavailable();
                }

                return path.ToString(0, checked((int)length));
            }
            finally
            {
                if (process != 0 && !NativeMethods.CloseHandle(process))
                {
                    throw Unavailable();
                }
            }
        }

        private static T NativeCall<T>(CancellationToken cancellationToken, Func<T> call)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var result = call();
            cancellationToken.ThrowIfCancellationRequested();
            return result;
        }

        private static AutomationCaptureException Unavailable() =>
            new(SendErrorCode.AutomationUnavailable);
    }
}
