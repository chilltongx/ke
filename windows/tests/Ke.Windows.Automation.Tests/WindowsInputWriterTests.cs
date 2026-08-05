using System.Runtime.InteropServices;
using Ke.Windows.Automation;
using Ke.Windows.Core;
using Xunit;

namespace Ke.Windows.Automation.Tests;

public sealed class WindowsInputWriterTests
{
    private static readonly TargetIdentity Expected =
        new((nint)42, 99, "42.7", SupportedApplication.Codex);

    [Fact]
    public void Native_input_layout_matches_the_Win32_x64_ABI()
    {
        Assert.Equal(40, Marshal.SizeOf<NativeMethods.NativeInput>());
        Assert.Equal(0, Marshal.OffsetOf<NativeMethods.NativeInput>("Type").ToInt32());
        Assert.Equal(8, Marshal.OffsetOf<NativeMethods.NativeInput>("Data").ToInt32());
        Assert.Equal(32, Marshal.SizeOf<NativeMethods.MouseInput>());
        Assert.Equal(24, Marshal.SizeOf<NativeMethods.KeyboardInput>());
        Assert.Equal(8, Marshal.SizeOf<NativeMethods.HardwareInput>());
    }

    [Fact]
    public void Native_adapter_passes_the_actual_INPUT_size_to_SendInput()
    {
        var api = new RecordingUser32InputApi();
        var native = new WindowsInputNative(api);

        var accepted = native.SendInput(
        [
            new(0, '可', NativeMethods.KeyEventUnicode),
            new(0, '可', NativeMethods.KeyEventUnicode | NativeMethods.KeyEventKeyUp)
        ]);

        Assert.Equal(2u, accepted);
        Assert.Equal(2u, api.InputCount);
        Assert.Equal(40, api.InputSize);
        Assert.Equal(Marshal.SizeOf<NativeMethods.NativeInput>(), api.InputSize);
        Assert.Equal(2, api.Inputs!.Length);
        Assert.All(api.Inputs, input => Assert.Equal(NativeMethods.InputKeyboard, input.Type));
    }

    [Fact]
    public void Writable_value_pattern_is_preferred_without_native_keyboard_input()
    {
        var fixture = WriterFixture.Create(ValueWriteAttempt.Written);

        var result = fixture.Subject.WriteApproval(Expected, CancellationToken.None);

        Assert.True(result.IsSuccess);
        Assert.Equal(TextWriteMethod.ValuePattern, result.Method);
        Assert.Equal(["foreground", "pid", "focused", "value:可"], fixture.Events);
        Assert.Empty(fixture.Native.InputBatches);
    }

    [Fact]
    public void Unsupported_value_pattern_falls_back_to_exact_unicode_key_pair()
    {
        var fixture = WriterFixture.Create(ValueWriteAttempt.Unsupported);

        var result = fixture.Subject.WriteApproval(Expected, CancellationToken.None);

        Assert.True(result.IsSuccess);
        Assert.Equal(TextWriteMethod.UnicodeSendInput, result.Method);
        var batch = Assert.Single(fixture.Native.InputBatches);
        Assert.Collection(
            batch,
            key =>
            {
                Assert.Equal((ushort)0, key.VirtualKey);
                Assert.Equal((ushort)'可', key.ScanCode);
                Assert.Equal(NativeMethods.KeyEventUnicode, key.Flags);
            },
            key =>
            {
                Assert.Equal((ushort)0, key.VirtualKey);
                Assert.Equal((ushort)'可', key.ScanCode);
                Assert.Equal(
                    NativeMethods.KeyEventUnicode | NativeMethods.KeyEventKeyUp,
                    key.Flags);
            });
    }

    [Theory]
    [InlineData("hwnd")]
    [InlineData("pid")]
    [InlineData("runtime")]
    public void Target_mismatch_prevents_every_write_path(string mutation)
    {
        var fixture = WriterFixture.Create(ValueWriteAttempt.Written);
        if (mutation == "hwnd") fixture.Native.ForegroundWindow = (nint)43;
        if (mutation == "pid") fixture.Native.ProcessId = 100;
        if (mutation == "runtime") fixture.Automation.RuntimeId = "42.8";

        var result = fixture.Subject.WriteApproval(Expected, CancellationToken.None);

        Assert.False(result.IsSuccess);
        Assert.Equal(0, fixture.Automation.ValueWriteCount);
        Assert.Empty(fixture.Native.InputBatches);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    public void Unicode_write_requires_SendInput_to_accept_both_records(uint accepted)
    {
        var fixture = WriterFixture.Create(ValueWriteAttempt.Unsupported);
        fixture.Native.AcceptedInputCount = accepted;

        var result = fixture.Subject.WriteApproval(Expected, CancellationToken.None);

        Assert.False(result.IsSuccess);
        Assert.Single(fixture.Native.InputBatches);
    }

    [Fact]
    public void Value_pattern_failure_does_not_retry_through_SendInput()
    {
        var fixture = WriterFixture.Create(ValueWriteAttempt.Failed);

        var result = fixture.Subject.WriteApproval(Expected, CancellationToken.None);

        Assert.False(result.IsSuccess);
        Assert.Equal(1, fixture.Automation.ValueWriteCount);
        Assert.Empty(fixture.Native.InputBatches);
    }

    [Fact]
    public void Focused_UIA_element_is_fetched_once_per_write_attempt()
    {
        var fixture = WriterFixture.Create(ValueWriteAttempt.Unsupported);

        fixture.Subject.WriteApproval(Expected, CancellationToken.None);

        Assert.Equal(1, fixture.Automation.FocusedElementCalls);
    }

    [Theory]
    [InlineData(NativeMethods.VirtualKeyControl)]
    [InlineData(NativeMethods.VirtualKeyMenu)]
    [InlineData(NativeMethods.VirtualKeyShift)]
    [InlineData(NativeMethods.VirtualKeyLeftWindows)]
    [InlineData(NativeMethods.VirtualKeyRightWindows)]
    public void Every_supported_modifier_high_bit_is_treated_as_pressed(int virtualKey)
    {
        var fixture = WriterFixture.Create(ValueWriteAttempt.Written);
        fixture.Native.KeyStates[virtualKey] = unchecked((short)0x8000);

        Assert.False(fixture.Subject.AreModifierKeysReleased());
    }

    [Fact]
    public void Modifier_low_bit_alone_is_not_treated_as_pressed()
    {
        var fixture = WriterFixture.Create(ValueWriteAttempt.Written);
        fixture.Native.KeyStates[NativeMethods.VirtualKeyControl] = 1;

        Assert.True(fixture.Subject.AreModifierKeysReleased());
    }

    [Fact]
    public void Enter_revalidates_foreground_and_modifiers_then_sends_one_key_pair()
    {
        var fixture = WriterFixture.Create(ValueWriteAttempt.Written);

        var result = fixture.Subject.SendEnter(Expected, CancellationToken.None);

        Assert.True(result);
        var batch = Assert.Single(fixture.Native.InputBatches);
        Assert.Collection(
            batch,
            key =>
            {
                Assert.Equal((ushort)NativeMethods.VirtualKeyReturn, key.VirtualKey);
                Assert.Equal((ushort)0, key.ScanCode);
                Assert.Equal(0u, key.Flags);
            },
            key =>
            {
                Assert.Equal((ushort)NativeMethods.VirtualKeyReturn, key.VirtualKey);
                Assert.Equal((ushort)0, key.ScanCode);
                Assert.Equal(NativeMethods.KeyEventKeyUp, key.Flags);
            });
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    public void Enter_partial_or_failed_SendInput_is_failure_without_retry(uint accepted)
    {
        var fixture = WriterFixture.Create(ValueWriteAttempt.Written);
        fixture.Native.AcceptedInputCount = accepted;

        Assert.False(fixture.Subject.SendEnter(Expected, CancellationToken.None));
        Assert.Single(fixture.Native.InputBatches);
    }

    [Fact]
    public void Enter_never_sends_when_foreground_changed_or_modifier_is_down()
    {
        var changed = WriterFixture.Create(ValueWriteAttempt.Written);
        changed.Native.ForegroundWindow = (nint)43;
        var modified = WriterFixture.Create(ValueWriteAttempt.Written);
        modified.Native.KeyStates[NativeMethods.VirtualKeyShift] = unchecked((short)0x8000);

        Assert.False(changed.Subject.SendEnter(Expected, CancellationToken.None));
        Assert.False(modified.Subject.SendEnter(Expected, CancellationToken.None));
        Assert.Empty(changed.Native.InputBatches);
        Assert.Empty(modified.Native.InputBatches);
    }

    [Fact]
    public void Cancellation_before_write_or_enter_causes_no_side_effect()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        var fixture = WriterFixture.Create(ValueWriteAttempt.Written);

        Assert.Throws<OperationCanceledException>(
            () => fixture.Subject.WriteApproval(Expected, cancellation.Token));
        Assert.Throws<OperationCanceledException>(
            () => fixture.Subject.SendEnter(Expected, cancellation.Token));
        Assert.Equal(0, fixture.Automation.ValueWriteCount);
        Assert.Empty(fixture.Native.InputBatches);
    }

    private sealed record WriterFixture(
        List<string> Events,
        FakeInputNative Native,
        FakeWriterAutomation Automation,
        WindowsInputWriter Subject)
    {
        public static WriterFixture Create(ValueWriteAttempt valueAttempt)
        {
            var events = new List<string>();
            var native = new FakeInputNative(events);
            var automation = new FakeWriterAutomation(events)
            {
                ValueAttempt = valueAttempt
            };
            return new(events, native, automation, new WindowsInputWriter(native, automation));
        }
    }

    private sealed class FakeInputNative(List<string> events) : IWindowsInputNative
    {
        public nint ForegroundWindow { get; set; } = (nint)42;

        public uint ProcessId { get; set; } = 99;

        public uint AcceptedInputCount { get; set; } = 2;

        public Dictionary<int, short> KeyStates { get; } = [];

        public List<IReadOnlyList<KeyboardInputCommand>> InputBatches { get; } = [];

        public nint GetForegroundWindow()
        {
            events.Add("foreground");
            return ForegroundWindow;
        }

        public uint GetWindowProcessId(nint hwnd)
        {
            events.Add("pid");
            return ProcessId;
        }

        public short GetAsyncKeyState(int virtualKey) =>
            KeyStates.GetValueOrDefault(virtualKey);

        public uint SendInput(IReadOnlyList<KeyboardInputCommand> inputs)
        {
            events.Add("send-input");
            InputBatches.Add(inputs.ToArray());
            return AcceptedInputCount;
        }
    }

    private sealed class RecordingUser32InputApi : IUser32InputApi
    {
        public uint InputCount { get; private set; }

        public NativeMethods.NativeInput[]? Inputs { get; private set; }

        public int InputSize { get; private set; }

        public nint GetForegroundWindow() => (nint)42;

        public uint GetWindowProcessId(nint hwnd) => 99;

        public short GetAsyncKeyState(int virtualKey) => 0;

        public uint SendInput(
            uint inputCount,
            NativeMethods.NativeInput[] inputs,
            int inputSize)
        {
            InputCount = inputCount;
            Inputs = inputs;
            InputSize = inputSize;
            return inputCount;
        }
    }

    private sealed class FakeWriterAutomation(List<string> events) : IWriterAutomationBackend
    {
        public string RuntimeId { get; set; } = "42.7";

        public ValueWriteAttempt ValueAttempt { get; set; }

        public int FocusedElementCalls { get; private set; }

        public int ValueWriteCount { get; private set; }

        public IFocusedInputElement GetFocusedElement(CancellationToken cancellationToken)
        {
            events.Add("focused");
            FocusedElementCalls++;
            return new FakeFocusedElement(this, events);
        }

        private sealed class FakeFocusedElement(
            FakeWriterAutomation owner,
            List<string> events) : IFocusedInputElement
        {
            public string RuntimeId => owner.RuntimeId;

            public ValueWriteAttempt TryWriteValue(
                string value,
                CancellationToken cancellationToken)
            {
                events.Add($"value:{value}");
                owner.ValueWriteCount++;
                return owner.ValueAttempt;
            }
        }
    }
}
