using System.Runtime.InteropServices;
using System.Windows.Automation;
using Ke.Windows.Core;

namespace Ke.Windows.Automation;

public enum TextWriteMethod
{
    ValuePattern,
    UnicodeSendInput
}

public sealed record TextWriteResult(bool IsSuccess, TextWriteMethod? Method);

public interface IWindowsInputWriter
{
    bool AreModifierKeysReleased();

    TextWriteResult WriteApproval(
        TargetIdentity expected,
        CancellationToken cancellationToken);

    bool SendEnter(TargetIdentity expected, CancellationToken cancellationToken);
}

internal enum ValueWriteAttempt
{
    Written,
    Unsupported,
    Failed
}

internal sealed record KeyboardInputCommand(
    ushort VirtualKey,
    ushort ScanCode,
    uint Flags);

internal interface IWindowsInputNative
{
    nint GetForegroundWindow();

    uint GetWindowProcessId(nint hwnd);

    short GetAsyncKeyState(int virtualKey);

    uint SendInput(IReadOnlyList<KeyboardInputCommand> inputs);
}

internal interface IWriterAutomationBackend
{
    IFocusedInputElement GetFocusedElement(CancellationToken cancellationToken);
}

internal interface IFocusedInputElement
{
    string RuntimeId { get; }

    ValueWriteAttempt TryWriteValue(string value, CancellationToken cancellationToken);
}

public sealed class WindowsInputWriter : IWindowsInputWriter
{
    private static readonly int[] ModifierKeys =
    [
        NativeMethods.VirtualKeyControl,
        NativeMethods.VirtualKeyMenu,
        NativeMethods.VirtualKeyShift,
        NativeMethods.VirtualKeyLeftWindows,
        NativeMethods.VirtualKeyRightWindows
    ];

    private readonly IWindowsInputNative _native;
    private readonly IWriterAutomationBackend _automation;

    public WindowsInputWriter()
        : this(new WindowsInputNative(), new WriterAutomationBackend())
    {
    }

    internal WindowsInputWriter(
        IWindowsInputNative native,
        IWriterAutomationBackend automation)
    {
        _native = native;
        _automation = automation;
    }

    public bool AreModifierKeysReleased() => ModifierKeys.All(
        key => (_native.GetAsyncKeyState(key) & 0x8000) == 0);

    public TextWriteResult WriteApproval(
        TargetIdentity expected,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!MatchesForeground(expected, cancellationToken))
        {
            return FailedWrite();
        }

        var focused = _automation.GetFocusedElement(cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        if (!string.Equals(focused.RuntimeId, expected.RuntimeId, StringComparison.Ordinal))
        {
            return FailedWrite();
        }

        cancellationToken.ThrowIfCancellationRequested();
        var valueAttempt = focused.TryWriteValue(
            ProductInfo.ApprovalText,
            cancellationToken);
        if (valueAttempt == ValueWriteAttempt.Written)
        {
            return new(true, TextWriteMethod.ValuePattern);
        }

        if (valueAttempt == ValueWriteAttempt.Failed)
        {
            return FailedWrite();
        }

        cancellationToken.ThrowIfCancellationRequested();
        if (!MatchesForeground(expected, cancellationToken))
        {
            return FailedWrite();
        }

        var approval = ProductInfo.ApprovalText[0];
        var inputs = new KeyboardInputCommand[]
        {
            new(0, approval, NativeMethods.KeyEventUnicode),
            new(
                0,
                approval,
                NativeMethods.KeyEventUnicode | NativeMethods.KeyEventKeyUp)
        };
        cancellationToken.ThrowIfCancellationRequested();
        return _native.SendInput(inputs) == inputs.Length
            ? new(true, TextWriteMethod.UnicodeSendInput)
            : FailedWrite();
    }

    public bool SendEnter(TargetIdentity expected, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!MatchesForeground(expected, cancellationToken) ||
            !AreModifierKeysReleased())
        {
            return false;
        }

        var inputs = new KeyboardInputCommand[]
        {
            new(NativeMethods.VirtualKeyReturn, 0, 0),
            new(NativeMethods.VirtualKeyReturn, 0, NativeMethods.KeyEventKeyUp)
        };
        cancellationToken.ThrowIfCancellationRequested();
        return _native.SendInput(inputs) == inputs.Length;
    }

    private bool MatchesForeground(
        TargetIdentity expected,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var hwnd = _native.GetForegroundWindow();
        cancellationToken.ThrowIfCancellationRequested();
        if (hwnd == 0 || hwnd != expected.Hwnd)
        {
            return false;
        }

        var processId = _native.GetWindowProcessId(hwnd);
        cancellationToken.ThrowIfCancellationRequested();
        return processId != 0 && processId == expected.ProcessId;
    }

    private static TextWriteResult FailedWrite() => new(false, null);

    private sealed class WindowsInputNative : IWindowsInputNative
    {
        public nint GetForegroundWindow() => NativeMethods.GetForegroundWindow();

        public uint GetWindowProcessId(nint hwnd)
        {
            var threadId = NativeMethods.GetWindowThreadProcessId(hwnd, out var processId);
            return threadId == 0 ? 0 : processId;
        }

        public short GetAsyncKeyState(int virtualKey) =>
            NativeMethods.GetAsyncKeyState(virtualKey);

        public uint SendInput(IReadOnlyList<KeyboardInputCommand> inputs)
        {
            var nativeInputs = inputs.Select(command => new NativeMethods.NativeInput
            {
                Type = NativeMethods.InputKeyboard,
                Data = new NativeMethods.InputUnion
                {
                    Keyboard = new NativeMethods.KeyboardInput
                    {
                        VirtualKey = command.VirtualKey,
                        ScanCode = command.ScanCode,
                        Flags = command.Flags
                    }
                }
            }).ToArray();
            return NativeMethods.SendInput(
                checked((uint)nativeInputs.Length),
                nativeInputs,
                Marshal.SizeOf<NativeMethods.NativeInput>());
        }
    }

    private sealed class WriterAutomationBackend : IWriterAutomationBackend
    {
        public IFocusedInputElement GetFocusedElement(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var element = AutomationElement.FocusedElement;
            cancellationToken.ThrowIfCancellationRequested();
            return element is null
                ? throw new InvalidOperationException("No focused automation element.")
                : new FocusedInputElement(element);
        }
    }

    private sealed class FocusedInputElement : IFocusedInputElement
    {
        private readonly AutomationElement _element;

        public FocusedInputElement(AutomationElement element)
        {
            _element = element;
            var runtimeId = element.GetRuntimeId();
            RuntimeId = runtimeId is { Length: > 0 }
                ? string.Join('.', runtimeId)
                : throw new InvalidOperationException("Focused element has no runtime ID.");
        }

        public string RuntimeId { get; }

        public ValueWriteAttempt TryWriteValue(
            string value,
            CancellationToken cancellationToken)
        {
            try
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (!_element.TryGetCurrentPattern(ValuePattern.Pattern, out var pattern) ||
                    pattern is not ValuePattern valuePattern ||
                    valuePattern.Current.IsReadOnly)
                {
                    return ValueWriteAttempt.Unsupported;
                }

                cancellationToken.ThrowIfCancellationRequested();
                valuePattern.SetValue(value);
                cancellationToken.ThrowIfCancellationRequested();
                return ValueWriteAttempt.Written;
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception exception) when (
                exception is ElementNotAvailableException or
                COMException or
                InvalidOperationException or
                NotSupportedException)
            {
                return ValueWriteAttempt.Failed;
            }
        }
    }
}
