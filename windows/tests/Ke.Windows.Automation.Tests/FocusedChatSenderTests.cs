using Ke.Windows.Automation;
using Ke.Windows.Core;
using Xunit;

namespace Ke.Windows.Automation.Tests;

public sealed class FocusedChatSenderTests
{
    [Fact]
    public void Stable_empty_target_uses_three_captures_then_writes_and_enters_once()
    {
        var fixture = SenderFixture.Stable();

        var result = fixture.Subject.TrySend(CancellationToken.None);

        Assert.True(result.IsSuccess);
        Assert.Equal(
            ["capture", "capture", "modifiers", "write:可", "capture", "modifiers", "enter"],
            fixture.Events);
        Assert.Equal(3, fixture.Provider.CaptureCount);
        Assert.Equal(1, fixture.Writer.WriteAttempts);
        Assert.Equal(1, fixture.Writer.EnterAttempts);
    }

    [Theory]
    [InlineData("hwnd")]
    [InlineData("pid")]
    [InlineData("runtime")]
    [InlineData("app")]
    [InlineData("draft")]
    public void Second_capture_mutation_never_writes_or_enters(string mutation)
    {
        var fixture = SenderFixture.WithSecondMutation(mutation);

        var result = fixture.Subject.TrySend(CancellationToken.None);

        Assert.Equal(SendErrorCode.TargetChanged, result.Error);
        Assert.Equal(0, fixture.Writer.WriteAttempts);
        Assert.Equal(0, fixture.Writer.EnterAttempts);
    }

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    [InlineData(4)]
    public void Cancellation_at_each_side_effect_boundary_fails_closed(int boundary)
    {
        using var cancellation = new CancellationTokenSource();
        var fixture = SenderFixture.CancelAtBoundary(cancellation, boundary);

        var result = fixture.Subject.TrySend(cancellation.Token);

        Assert.Equal(SendErrorCode.AutomationTimeout, result.Error);
        Assert.Equal(boundary >= 3 ? 1 : 0, fixture.Writer.WriteAttempts);
        Assert.Equal(0, fixture.Writer.EnterAttempts);
    }

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    public void Capture_timeout_at_any_gate_maps_to_automation_timeout(int capture)
    {
        var fixture = SenderFixture.Stable();
        fixture.Provider.FailureAtCapture = capture;

        var result = fixture.Subject.TrySend(CancellationToken.None);

        Assert.Equal(SendErrorCode.AutomationTimeout, result.Error);
        Assert.Equal(capture == 3 ? 1 : 0, fixture.Writer.WriteAttempts);
        Assert.Equal(0, fixture.Writer.EnterAttempts);
    }

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    public void Modifier_check_at_either_gate_prevents_the_next_side_effect(int gate)
    {
        var fixture = SenderFixture.WithModifierDown(gate);

        var result = fixture.Subject.TrySend(CancellationToken.None);

        Assert.Equal(SendErrorCode.ModifierKeyDown, result.Error);
        Assert.Equal(gate == 2 ? 1 : 0, fixture.Writer.WriteAttempts);
        Assert.Equal(0, fixture.Writer.EnterAttempts);
    }

    [Fact]
    public void Failed_write_is_not_retried_and_never_enters()
    {
        var fixture = SenderFixture.Stable(writeSucceeds: false);

        var result = fixture.Subject.TrySend(CancellationToken.None);

        Assert.Equal(SendErrorCode.WriteUnconfirmed, result.Error);
        Assert.Equal(1, fixture.Writer.WriteAttempts);
        Assert.Equal(0, fixture.Writer.EnterAttempts);
    }

    [Theory]
    [InlineData("hwnd")]
    [InlineData("pid")]
    [InlineData("runtime")]
    [InlineData("app")]
    [InlineData("draft")]
    public void Third_capture_must_confirm_same_target_and_exact_approval(string mutation)
    {
        var fixture = SenderFixture.WithThirdMutation(mutation);

        var result = fixture.Subject.TrySend(CancellationToken.None);

        Assert.Equal(SendErrorCode.WriteUnconfirmed, result.Error);
        Assert.Equal(1, fixture.Writer.WriteAttempts);
        Assert.Equal(0, fixture.Writer.EnterAttempts);
    }

    [Fact]
    public void Enter_failure_is_attempted_once_without_retry()
    {
        var fixture = SenderFixture.Stable(enterSucceeds: false);

        var result = fixture.Subject.TrySend(CancellationToken.None);

        Assert.Equal(SendErrorCode.ReturnDeliveryFailed, result.Error);
        Assert.Equal(1, fixture.Writer.EnterAttempts);
    }

    [Fact]
    public void Unexpected_dependency_failure_maps_to_automation_unavailable()
    {
        var fixture = SenderFixture.Stable();
        fixture.Provider.Exception = new InvalidOperationException("boundary failed");

        var result = fixture.Subject.TrySend(CancellationToken.None);

        Assert.Equal(SendErrorCode.AutomationUnavailable, result.Error);
        Assert.Empty(fixture.Writer.SideEffects);
    }

    private sealed class SenderFixture
    {
        private SenderFixture(
            List<string> events,
            RecordingSnapshotProvider provider,
            RecordingInputWriter writer)
        {
            Events = events;
            Provider = provider;
            Writer = writer;
            Subject = new FocusedChatSender(
                provider,
                TargetAdapterRegistry.CreateDefault(),
                writer);
        }

        public List<string> Events { get; }

        public RecordingSnapshotProvider Provider { get; }

        public RecordingInputWriter Writer { get; }

        public FocusedChatSender Subject { get; }

        public static SenderFixture Stable(
            bool writeSucceeds = true,
            bool enterSucceeds = true)
        {
            var empty = EmptySnapshot();
            return Create(
                [empty, empty, empty with
                {
                    Focused = empty.Focused with { Text = ProductInfo.ApprovalText }
                }],
                writeSucceeds,
                enterSucceeds);
        }

        public static SenderFixture WithSecondMutation(string mutation)
        {
            var empty = EmptySnapshot();
            return Create([empty, Mutate(empty, mutation, secondCapture: true)]);
        }

        public static SenderFixture WithThirdMutation(string mutation)
        {
            var empty = EmptySnapshot();
            var approval = empty with
            {
                Focused = empty.Focused with { Text = ProductInfo.ApprovalText }
            };
            return Create([empty, empty, Mutate(approval, mutation, secondCapture: false)]);
        }

        public static SenderFixture WithModifierDown(int gate)
        {
            var fixture = Stable();
            fixture.Writer.ModifierResults = gate == 1 ? [false] : [true, false];
            return fixture;
        }

        public static SenderFixture CancelAtBoundary(
            CancellationTokenSource cancellation,
            int boundary)
        {
            var fixture = Stable();
            if (boundary == 1)
            {
                fixture.Provider.AfterCapture = count =>
                {
                    if (count == 1)
                    {
                        cancellation.Cancel();
                    }
                };
            }
            else if (boundary == 2)
            {
                fixture.Writer.AfterModifierCheck = count =>
                {
                    if (count == 1)
                    {
                        cancellation.Cancel();
                    }
                };
            }
            else if (boundary == 3)
            {
                fixture.Writer.AfterWrite = cancellation.Cancel;
            }
            else
            {
                fixture.Writer.AfterModifierCheck = count =>
                {
                    if (count == 2)
                    {
                        cancellation.Cancel();
                    }
                };
            }

            return fixture;
        }

        private static SenderFixture Create(
            IReadOnlyList<FocusSnapshot> snapshots,
            bool writeSucceeds = true,
            bool enterSucceeds = true)
        {
            var events = new List<string>();
            var provider = new RecordingSnapshotProvider(events, snapshots);
            var writer = new RecordingInputWriter(events)
            {
                WriteSucceeds = writeSucceeds,
                EnterSucceeds = enterSucceeds
            };
            return new(events, provider, writer);
        }

        private static FocusSnapshot EmptySnapshot()
        {
            var source = FixtureLoader.Load("Fixtures/codex-chat-empty.json");
            return source with
            {
                Hwnd = (nint)42,
                ProcessId = 99,
                Focused = source.Focused with { RuntimeId = "42.7", Text = string.Empty }
            };
        }

        private static FocusSnapshot Mutate(
            FocusSnapshot snapshot,
            string mutation,
            bool secondCapture) => mutation switch
            {
                "hwnd" => snapshot with { Hwnd = (nint)43 },
                "pid" => snapshot with { ProcessId = 100 },
                "runtime" => snapshot with
                {
                    Focused = snapshot.Focused with { RuntimeId = "42.8" }
                },
                "app" => FixtureLoader.Load("Fixtures/vscode-chat-empty.json") with
                {
                    Hwnd = snapshot.Hwnd,
                    ProcessId = snapshot.ProcessId,
                    Focused = FixtureLoader.Load("Fixtures/vscode-chat-empty.json").Focused with
                    {
                        RuntimeId = snapshot.Focused.RuntimeId,
                        Text = secondCapture ? string.Empty : ProductInfo.ApprovalText
                    }
                },
                "draft" => snapshot with
                {
                    Focused = snapshot.Focused with
                    {
                        Text = secondCapture ? "existing draft" : " 可"
                    }
                },
                _ => throw new ArgumentOutOfRangeException(nameof(mutation))
            };
    }

    private sealed class RecordingSnapshotProvider(
        List<string> events,
        IReadOnlyList<FocusSnapshot> snapshots) : IFocusSnapshotProvider
    {
        public int CaptureCount { get; private set; }

        public Exception? Exception { get; set; }

        public Action<int>? AfterCapture { get; set; }

        public int? FailureAtCapture { get; set; }

        public CaptureResult Capture(CancellationToken cancellationToken)
        {
            events.Add("capture");
            CaptureCount++;
            if (Exception is not null)
            {
                throw Exception;
            }

            if (FailureAtCapture == CaptureCount)
            {
                return CaptureResult.Failure(SendErrorCode.AutomationTimeout);
            }

            var snapshot = snapshots[Math.Min(CaptureCount - 1, snapshots.Count - 1)];
            AfterCapture?.Invoke(CaptureCount);
            return CaptureResult.Success(snapshot);
        }
    }

    private sealed class RecordingInputWriter(List<string> events) : IWindowsInputWriter
    {
        private int _modifierChecks;

        public IReadOnlyList<bool> ModifierResults { get; set; } = [true, true];

        public bool WriteSucceeds { get; set; } = true;

        public bool EnterSucceeds { get; set; } = true;

        public int WriteAttempts { get; private set; }

        public int EnterAttempts { get; private set; }

        public Action<int>? AfterModifierCheck { get; set; }

        public Action? AfterWrite { get; set; }

        public IReadOnlyList<string> SideEffects =>
            events.Where(x => x.StartsWith("write", StringComparison.Ordinal) || x == "enter").ToArray();

        public bool AreModifierKeysReleased()
        {
            events.Add("modifiers");
            _modifierChecks++;
            AfterModifierCheck?.Invoke(_modifierChecks);
            return ModifierResults[Math.Min(_modifierChecks - 1, ModifierResults.Count - 1)];
        }

        public TextWriteResult WriteApproval(
            TargetIdentity expected,
            CancellationToken cancellationToken)
        {
            events.Add($"write:{ProductInfo.ApprovalText}");
            WriteAttempts++;
            AfterWrite?.Invoke();
            return new(WriteSucceeds, WriteSucceeds ? TextWriteMethod.ValuePattern : null);
        }

        public bool SendEnter(TargetIdentity expected, CancellationToken cancellationToken)
        {
            events.Add("enter");
            EnterAttempts++;
            return EnterSucceeds;
        }
    }
}
