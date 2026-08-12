using Ke.Windows.Automation;
using Ke.Windows.Core;
using Xunit;

namespace Ke.Windows.Automation.Tests;

public sealed class FocusSnapshotProviderTests
{
    [Fact]
    public void Capture_uses_fixed_order_and_keeps_only_image_filename()
    {
        var calls = new List<string>();
        var provider = new FocusSnapshotProvider(
            new RecordingForegroundReader(calls, (nint)12, 99, @"C:\Apps\Code.exe"),
            new RecordingIntegrityReader(calls, sourceRid: 0x2000, targetRid: 0x2000),
            new RecordingUiAutomationReader(calls));

        var result = provider.Capture(CancellationToken.None);

        Assert.Null(result.Error);
        Assert.NotNull(result.Snapshot);
        Assert.Equal("Code.exe", result.Snapshot.ProcessImageName);
        Assert.Equal(["hwnd", "pid", "image", "integrity", "uia"], calls);
    }

    [Fact]
    public void Elevated_target_is_rejected_before_UIA_read()
    {
        var calls = new List<string>();
        var provider = new FocusSnapshotProvider(
            new RecordingForegroundReader(calls, (nint)12, 99, "Code.exe"),
            new RecordingIntegrityReader(calls, sourceRid: 0x2000, targetRid: 0x3000),
            new RecordingUiAutomationReader(calls, throwIfCalled: true));

        var result = provider.Capture(CancellationToken.None);

        Assert.Equal(SendErrorCode.ElevatedTarget, result.Error);
        Assert.Null(result.Snapshot);
        Assert.DoesNotContain("uia", calls);
    }

    [Theory]
    [InlineData(31, 1)]
    [InlineData(1, 513)]
    public void Traversal_over_limit_fails_closed(int depth, int count)
    {
        var result = BoundedTreeFixture.Read(depth, count, textLength: 0);

        Assert.Equal(SendErrorCode.AutomationUnavailable, result.Error);
    }

    [Fact]
    public void Traversal_at_limits_succeeds()
    {
        var result = BoundedTreeFixture.Read(depth: 30, count: 512, textLength: 4096);

        Assert.Null(result.Error);
        Assert.NotNull(result.Snapshot);
    }

    [Fact]
    public void Missing_runtime_id_fails_closed()
    {
        var result = BoundedTreeFixture.Read(
            depth: 2,
            count: 2,
            textLength: 0,
            runtimeId: "");

        Assert.Equal(SendErrorCode.AutomationUnavailable, result.Error);
    }

    [Fact]
    public void Focused_text_at_probe_limit_fails_closed()
    {
        var result = BoundedTreeFixture.Read(depth: 1, count: 1, textLength: 4097);

        Assert.Equal(SendErrorCode.AutomationUnavailable, result.Error);
    }

    [Fact]
    public void Focused_element_is_requested_once_per_capture()
    {
        var backend = BoundedTreeFixture.Create(depth: 2, count: 4, textLength: 0);
        var reader = new UiAutomationTreeReader(backend);

        var result = CaptureTree(reader);

        Assert.Null(result.Error);
        Assert.Equal(1, backend.FocusedElementCallCount);
    }

    [Fact]
    public void Cancellation_is_reported_as_automation_timeout()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        var result = BoundedTreeFixture.Read(
            depth: 1,
            count: 1,
            textLength: 0,
            cancellationToken: cancellation.Token);

        Assert.Equal(SendErrorCode.AutomationTimeout, result.Error);
    }

    private static CaptureResult CaptureTree(UiAutomationTreeReader reader)
    {
        try
        {
            var tree = reader.Read(CancellationToken.None);
            return CaptureResult.Success(new FocusSnapshot(
                (nint)12,
                99,
                "Code.exe",
                0x2000,
                0x2000,
                tree.Focused,
                tree.Ancestors,
                tree.Nearby));
        }
        catch (AutomationCaptureException exception)
        {
            return CaptureResult.Failure(exception.Error);
        }
    }

    private sealed class RecordingForegroundReader(
        List<string> calls,
        nint hwnd,
        uint processId,
        string imagePath) : IForegroundWindowReader
    {
        public nint GetForegroundWindow(CancellationToken cancellationToken)
        {
            calls.Add("hwnd");
            return hwnd;
        }

        public uint GetProcessId(nint window, CancellationToken cancellationToken)
        {
            calls.Add("pid");
            return processId;
        }

        public string GetProcessImagePath(uint targetProcessId, CancellationToken cancellationToken)
        {
            calls.Add("image");
            return imagePath;
        }
    }

    private sealed class RecordingIntegrityReader(
        List<string> calls,
        int sourceRid,
        int targetRid) : IIntegrityLevelReader
    {
        public IntegrityLevels Read(uint targetProcessId, CancellationToken cancellationToken)
        {
            calls.Add("integrity");
            return new(sourceRid, targetRid);
        }
    }

    private sealed class RecordingUiAutomationReader(
        List<string> calls,
        bool throwIfCalled = false) : IUiAutomationTreeReader
    {
        public UiAutomationSnapshot Read(CancellationToken cancellationToken)
        {
            calls.Add("uia");
            if (throwIfCalled)
            {
                throw new InvalidOperationException("UIA must not be called");
            }

            return new(
                BoundedTreeFixture.Summary("42", string.Empty),
                Array.Empty<ElementSummary>(),
                Array.Empty<ElementSummary>());
        }
    }
}

internal static class BoundedTreeFixture
{
    public static CaptureResult Read(
        int depth,
        int count,
        int textLength,
        string runtimeId = "42",
        CancellationToken cancellationToken = default)
    {
        var reader = new UiAutomationTreeReader(Create(depth, count, textLength, runtimeId));
        try
        {
            var tree = reader.Read(cancellationToken);
            return CaptureResult.Success(new FocusSnapshot(
                (nint)12,
                99,
                "Code.exe",
                0x2000,
                0x2000,
                tree.Focused,
                tree.Ancestors,
                tree.Nearby));
        }
        catch (AutomationCaptureException exception)
        {
            return CaptureResult.Failure(exception.Error);
        }
    }

    public static FakeUiAutomationBackend Create(
        int depth,
        int count,
        int textLength,
        string runtimeId = "42")
    {
        var focused = new FakeAutomationElement(Summary(runtimeId, new string('x', textLength)));
        var current = focused;
        var all = new List<FakeAutomationElement> { focused };

        for (var index = 0; index < depth; index++)
        {
            var parent = new FakeAutomationElement(Summary($"ancestor-{index}", string.Empty));
            parent.AddChild(current);
            current = parent;
            all.Add(parent);
        }

        var nearbyNeeded = Math.Max(0, count - all.Count);
        for (var index = 0; index < nearbyNeeded; index++)
        {
            current.AddChild(new FakeAutomationElement(
                Summary($"nearby-{index}", string.Empty)));
        }

        return new(focused);
    }

    public static ElementSummary Summary(string runtimeId, string text) => new(
        runtimeId,
        "Edit",
        "TextBox",
        "composer",
        string.Empty,
        IsEnabled: true,
        IsKeyboardFocusable: true,
        IsPassword: false,
        IsReadOnly: false,
        text);
}

internal sealed class FakeUiAutomationBackend(FakeAutomationElement focused) : IUiAutomationBackend
{
    public int FocusedElementCallCount { get; private set; }

    public IUiAutomationElement GetFocusedElement(CancellationToken cancellationToken)
    {
        FocusedElementCallCount++;
        return focused;
    }
}

internal sealed class FakeAutomationElement(ElementSummary summary) : IUiAutomationElement
{
    private readonly List<FakeAutomationElement> _children = [];

    public FakeAutomationElement? Parent { get; private set; }

    public void AddChild(FakeAutomationElement child)
    {
        child.Parent = this;
        _children.Add(child);
    }

    public ElementSummary ReadSummary(bool includeText, CancellationToken cancellationToken) =>
        includeText ? summary : summary with { Text = null };

    public IUiAutomationElement? GetParent(CancellationToken cancellationToken) => Parent;

    public IUiAutomationElement? GetFirstChild(CancellationToken cancellationToken) =>
        _children.Count == 0 ? null : _children[0];

    public IUiAutomationElement? GetNextSibling(CancellationToken cancellationToken)
    {
        if (Parent is null)
        {
            return null;
        }

        var index = Parent._children.IndexOf(this);
        return index >= 0 && index + 1 < Parent._children.Count
            ? Parent._children[index + 1]
            : null;
    }
}
