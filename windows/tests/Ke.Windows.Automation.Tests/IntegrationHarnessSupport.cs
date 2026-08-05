using System.Diagnostics;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows.Automation;
using Ke.Windows.Automation;
using Ke.Windows.Core;
using Xunit;
using Xunit.Sdk;

namespace Ke.Windows.Automation.Tests;

internal static class HarnessPaths
{
    private const string HarnessProjectDirectory = "Ke.Windows.IntegrationHarness";

    internal static string MainWindowXaml => Path.Combine(
        FindRepositoryRoot(),
        "windows",
        "tests",
        HarnessProjectDirectory,
        "MainWindow.xaml");

    internal static string ProjectFile => Path.Combine(
        FindRepositoryRoot(),
        "windows",
        "tests",
        HarnessProjectDirectory,
        "Ke.Windows.IntegrationHarness.csproj");

    internal static string Executable
    {
        get
        {
            var configured = Environment.GetEnvironmentVariable("KE_INTEGRATION_HARNESS_PATH");
            if (!string.IsNullOrWhiteSpace(configured))
            {
                return Path.GetFullPath(configured);
            }

            var binaryRoot = Path.Combine(
                FindRepositoryRoot(),
                "windows",
                "tests",
                HarnessProjectDirectory,
                "bin");
            return Directory.EnumerateFiles(
                    binaryRoot,
                    "Ke.Windows.IntegrationHarness.exe",
                    SearchOption.AllDirectories)
                .OrderByDescending(File.GetLastWriteTimeUtc)
                .FirstOrDefault()
                ?? throw new XunitException(
                    "The integration harness executable was not built. Build the solution first.");
        }
    }

    private static string FindRepositoryRoot()
    {
        var current = new DirectoryInfo(AppContext.BaseDirectory);
        while (current is not null)
        {
            if (File.Exists(Path.Combine(current.FullName, "windows", "Ke.Windows.slnx")))
            {
                return current.FullName;
            }

            current = current.Parent;
        }

        throw new XunitException("Could not locate the repository root.");
    }
}

internal static class HarnessProfile
{
    internal const string ProcessImageName = "Ke.Windows.IntegrationHarness.exe";

    internal static TargetAdapterRegistry CreateRegistry() => new(
    [
        new ProfileTargetAdapter(new AdapterProfile(
            ProcessImageName,
            SupportedApplication.Codex,
            new HashSet<ElementSignature>
            {
                new("ControlType.Edit", "TextBox", "ChatEmpty"),
                new("ControlType.Document", "RichTextBox", "DocumentEmpty"),
                new("ControlType.Edit", "TextBox", "FocusChanges")
            },
            new HashSet<string>(["composer"], StringComparer.Ordinal),
            new HashSet<string>(StringComparer.Ordinal),
            new HashSet<string>([string.Empty, "\r", "\n", "\r\n"], StringComparer.Ordinal)))
    ]);

    internal static FocusSnapshot ChatEmpty() => CreateSnapshot(
        "ChatEmpty",
        "ControlType.Edit",
        "TextBox",
        "Chat composer",
        string.Empty);

    internal static FocusSnapshot DocumentEmpty() => CreateSnapshot(
        "DocumentEmpty",
        "ControlType.Document",
        "RichTextBox",
        "Conversation composer",
        string.Empty);

    internal static FocusSnapshot FocusChanges() => CreateSnapshot(
        "FocusChanges",
        "ControlType.Edit",
        "TextBox",
        "Chat composer",
        string.Empty);

    internal static IEnumerable<FocusSnapshot> NegativeControls()
    {
        yield return CreateSnapshot("Search", "ControlType.Edit", "TextBox", "Search", string.Empty);
        yield return CreateSnapshot("Editor", "ControlType.Edit", "TextBox", "Text editor", string.Empty);
        yield return CreateSnapshot("Terminal", "ControlType.Edit", "TextBox", "Terminal", string.Empty);
        yield return CreateSnapshot(
            "Password",
            "ControlType.Edit",
            "PasswordBox",
            "Password",
            string.Empty,
            isPassword: true);
        yield return CreateSnapshot(
            "ReadOnly",
            "ControlType.Edit",
            "TextBox",
            "Read only",
            string.Empty,
            isReadOnly: true);
        yield return CreateSnapshot(
            "Disabled",
            "ControlType.Edit",
            "TextBox",
            "Disabled",
            string.Empty,
            isEnabled: false,
            isKeyboardFocusable: false);
    }

    internal static FocusSnapshot CreateSnapshot(
        string automationId,
        string controlType,
        string className,
        string name,
        string? text,
        bool isEnabled = true,
        bool isKeyboardFocusable = true,
        bool isPassword = false,
        bool isReadOnly = false) => new(
            (nint)101,
            202,
            ProcessImageName,
            0x2000,
            0x2000,
            new ElementSummary(
                $"fixture.{automationId}",
                controlType,
                className,
                automationId,
                name,
                isEnabled,
                isKeyboardFocusable,
                isPassword,
                isReadOnly,
                text),
            [],
            []);
}

internal static class HarnessReadiness
{
    internal static async Task<bool> WaitAsync(
        Func<bool> probe,
        TimeSpan timeout,
        TimeSpan pollInterval)
    {
        ArgumentNullException.ThrowIfNull(probe);
        if (timeout <= TimeSpan.Zero || pollInterval <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(timeout));
        }

        var stopwatch = Stopwatch.StartNew();
        while (stopwatch.Elapsed < timeout)
        {
            if (probe())
            {
                return true;
            }

            var remaining = timeout - stopwatch.Elapsed;
            await Task.Delay(remaining < pollInterval ? remaining : pollInterval)
                .ConfigureAwait(false);
        }

        return probe();
    }
}

internal sealed record HarnessTeardownResult(
    bool Forced,
    bool Exited,
    IReadOnlyList<uint> RemainingDescendantProcessIds);

internal static class HarnessProcessTeardown
{
    private static readonly TimeSpan ForcedExitTimeout = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan ExitPollInterval = TimeSpan.FromMilliseconds(20);

    internal static async Task<HarnessTeardownResult> CloseExactAsync(
        Process process,
        TimeSpan closeTimeout)
    {
        ArgumentNullException.ThrowIfNull(process);
        var processId = checked((uint)process.Id);
        var forced = false;
        using var descendants = new ExactDescendantTracker(processId);
        descendants.Discover();

        if (!process.HasExited)
        {
            _ = process.CloseMainWindow();
            if (!await WaitForExactTreeExitAsync(
                    process,
                    descendants,
                    closeTimeout).ConfigureAwait(false))
            {
                forced = true;
                descendants.Discover();
                process.Kill(entireProcessTree: true);
                _ = await WaitForExactTreeExitAsync(
                    process,
                    descendants,
                    ForcedExitTimeout).ConfigureAwait(false);
            }
        }

        descendants.Discover();
        return new(
            forced,
            process.HasExited,
            descendants.GetRemainingProcessIds());
    }

    private static async Task<bool> WaitForExactTreeExitAsync(
        Process root,
        ExactDescendantTracker descendants,
        TimeSpan timeout)
    {
        if (timeout <= TimeSpan.Zero)
        {
            descendants.Discover();
            return root.HasExited && descendants.GetRemainingProcessIds().Count == 0;
        }

        var stopwatch = Stopwatch.StartNew();
        var quiescentSamples = 0;
        while (stopwatch.Elapsed < timeout)
        {
            descendants.Discover();
            if (root.HasExited && descendants.GetRemainingProcessIds().Count == 0)
            {
                quiescentSamples++;
                if (quiescentSamples == 2)
                {
                    return true;
                }
            }
            else
            {
                quiescentSamples = 0;
            }

            var remaining = timeout - stopwatch.Elapsed;
            if (remaining <= TimeSpan.Zero)
            {
                break;
            }

            await Task.Delay(
                    remaining < ExitPollInterval ? remaining : ExitPollInterval)
                .ConfigureAwait(false);
        }

        descendants.Discover();
        return root.HasExited && descendants.GetRemainingProcessIds().Count == 0;
    }
}

internal sealed class ExactDescendantTracker(uint rootProcessId) : IDisposable
{
    private readonly Dictionary<uint, Process> _processes = [];
    private readonly HashSet<uint> _unresolvedProcessIds = [];
    private int _disposed;

    internal void Discover()
    {
        ObjectDisposedException.ThrowIf(_disposed != 0, this);
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        var current = ProcessTreeInspector.FindDescendants(rootProcessId).ToHashSet();
        _unresolvedProcessIds.RemoveWhere(processId => !current.Contains(processId));
        foreach (var processId in current)
        {
            if (_processes.TryGetValue(processId, out var tracked))
            {
                if (!HasExited(tracked))
                {
                    continue;
                }

                tracked.Dispose();
                _processes.Remove(processId);
            }

            if (_unresolvedProcessIds.Contains(processId))
            {
                continue;
            }

            Process? candidate = null;
            try
            {
                candidate = Process.GetProcessById(checked((int)processId));
                _ = candidate.StartTime;
                _ = candidate.Handle;
                if (!candidate.HasExited)
                {
                    _processes.Add(processId, candidate);
                    candidate = null;
                }
            }
            catch (ArgumentException)
            {
                // The exact PID exited between Toolhelp discovery and handle acquisition.
            }
            catch (InvalidOperationException)
            {
                // The exact PID exited while its stable process handle was opened.
            }
            catch (Win32Exception)
            {
                _unresolvedProcessIds.Add(processId);
            }
            finally
            {
                candidate?.Dispose();
            }
        }
    }

    internal IReadOnlyList<uint> GetRemainingProcessIds()
    {
        ObjectDisposedException.ThrowIf(_disposed != 0, this);
        var remaining = _processes
            .Where(pair => !HasExited(pair.Value))
            .Select(pair => pair.Key)
            .Concat(_unresolvedProcessIds)
            .Distinct()
            .Order()
            .ToArray();
        return remaining;
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
        {
            return;
        }

        foreach (var process in _processes.Values)
        {
            process.Dispose();
        }

        _processes.Clear();
        _unresolvedProcessIds.Clear();
    }

    private static bool HasExited(Process process)
    {
        try
        {
            return process.HasExited;
        }
        catch (InvalidOperationException)
        {
            return true;
        }
    }
}

internal static class HarnessInteractiveScenario
{
    private static readonly TimeSpan ReadinessTimeout = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(50);

    internal static async Task RunAsync()
    {
        RequireInteractiveWindowsDesktop();

        var readyEventName = $"Local\\Ke.Windows.Integration.{Guid.NewGuid():N}";
        using var ready = new EventWaitHandle(
            false,
            EventResetMode.ManualReset,
            readyEventName);
        using var process = StartHarness(readyEventName);
        HarnessTeardownResult? teardown = null;
        try
        {
            var signaled = await Task.Run(() => ready.WaitOne(ReadinessTimeout))
                .ConfigureAwait(false);
            if (!signaled || process.HasExited)
            {
                throw new XunitException(
                    "The integration harness did not become ready within five seconds.");
            }

            using var dispatcher = new AutomationDispatcher();
            using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            await dispatcher.InvokeAsync(
                token =>
                {
                    RunPipeline(process, token);
                    return true;
                },
                cancellation.Token).ConfigureAwait(false);
        }
        finally
        {
            teardown = await HarnessProcessTeardown.CloseExactAsync(
                process,
                TimeSpan.FromSeconds(5)).ConfigureAwait(false);
            if (teardown.Forced || !teardown.Exited ||
                teardown.RemainingDescendantProcessIds.Count != 0)
            {
                throw new XunitException(
                    "The harness did not close cleanly; its exact process tree was terminated.");
            }
        }
    }

    private static void RunPipeline(Process process, CancellationToken cancellationToken)
    {
        var window = WaitForWindow(process.Id, cancellationToken);
        var sender = new FocusedChatSender(
            new FocusSnapshotProvider(),
            HarnessProfile.CreateRegistry(),
            new WindowsInputWriter());

        AssertSend(sender, window, "ChatEmpty", expectedSuccess: true, cancellationToken);
        Assert.Equal(ProductInfo.ApprovalText, ReadValue(window, "ChatEmpty"));
        Assert.Equal("1", ReadName(window, "EnterCount"));

        AssertSend(sender, window, "DocumentEmpty", expectedSuccess: true, cancellationToken);
        Assert.Equal(ProductInfo.ApprovalText, ReadValue(window, "DocumentEmpty"));
        Assert.Equal("2", ReadName(window, "EnterCount"));

        foreach (var automationId in new[]
                 {
                     "Search", "Editor", "Terminal", "Password", "ReadOnly", "Disabled"
                 })
        {
            var control = FindByAutomationId(window, automationId);
            var before = ReadValueIfAvailable(control);
            var focused = TryFocus(window, control, cancellationToken);
            if (automationId == "Disabled")
            {
                Assert.False(focused);
            }
            else
            {
                Assert.True(focused);
            }

            var result = sender.TrySend(cancellationToken);
            Assert.False(result.IsSuccess);
            Assert.Equal(before, ReadValueIfAvailable(control));
            Assert.Equal("2", ReadName(window, "EnterCount"));
        }

        var focusChanges = FindByAutomationId(window, "FocusChanges");
        Assert.True(TryFocus(window, focusChanges, cancellationToken));
        var focusChangeResult = sender.TrySend(cancellationToken);
        Assert.Equal(SendErrorCode.WriteUnconfirmed, focusChangeResult.Error);
        Assert.Equal("2", ReadName(window, "EnterCount"));
    }

    private static void AssertSend(
        FocusedChatSender sender,
        AutomationElement window,
        string automationId,
        bool expectedSuccess,
        CancellationToken cancellationToken)
    {
        var control = FindByAutomationId(window, automationId);
        Assert.True(TryFocus(window, control, cancellationToken));
        Assert.Equal(expectedSuccess, sender.TrySend(cancellationToken).IsSuccess);
    }

    private static bool TryFocus(
        AutomationElement window,
        AutomationElement control,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        _ = NativeDesktop.SetForegroundWindow(new nint(window.Current.NativeWindowHandle));
        try
        {
            control.SetFocus();
        }
        catch (InvalidOperationException)
        {
            return false;
        }

        var expectedRuntimeId = control.GetRuntimeId();
        return WaitUntil(
            () =>
            {
                var focused = AutomationElement.FocusedElement;
                return focused is not null &&
                    focused.GetRuntimeId().SequenceEqual(expectedRuntimeId);
            },
            ReadinessTimeout,
            cancellationToken);
    }

    private static AutomationElement WaitForWindow(
        int processId,
        CancellationToken cancellationToken)
    {
        AutomationElement? window = null;
        var found = WaitUntil(
            () =>
            {
                window = AutomationElement.RootElement.FindFirst(
                    TreeScope.Children,
                    new PropertyCondition(
                        AutomationElement.ProcessIdProperty,
                        processId));
                return window is not null;
            },
            ReadinessTimeout,
            cancellationToken);
        return found
            ? window!
            : throw new XunitException(
                "The ready harness window was not available through UI Automation.");
    }

    private static AutomationElement FindByAutomationId(
        AutomationElement window,
        string automationId) =>
        window.FindFirst(
            TreeScope.Descendants,
            new PropertyCondition(
                AutomationElement.AutomationIdProperty,
                automationId))
        ?? throw new XunitException($"Harness control '{automationId}' was not found.");

    private static string? ReadValueIfAvailable(AutomationElement element)
    {
        if (element.TryGetCurrentPattern(ValuePattern.Pattern, out var value) &&
            value is ValuePattern valuePattern)
        {
            return valuePattern.Current.Value;
        }

        if (element.TryGetCurrentPattern(TextPattern.Pattern, out var text) &&
            text is TextPattern textPattern)
        {
            return textPattern.DocumentRange.GetText(-1);
        }

        return null;
    }

    private static string ReadValue(AutomationElement window, string automationId) =>
        ReadValueIfAvailable(FindByAutomationId(window, automationId))
        ?? throw new XunitException($"Harness control '{automationId}' has no readable value.");

    private static string ReadName(AutomationElement window, string automationId) =>
        FindByAutomationId(window, automationId).Current.Name;

    private static bool WaitUntil(
        Func<bool> probe,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        var stopwatch = Stopwatch.StartNew();
        while (stopwatch.Elapsed < timeout)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (probe())
            {
                return true;
            }

            Thread.Sleep(PollInterval);
        }

        cancellationToken.ThrowIfCancellationRequested();
        return probe();
    }

    private static Process StartHarness(string readyEventName)
    {
        var start = new ProcessStartInfo
        {
            FileName = HarnessPaths.Executable,
            UseShellExecute = false
        };
        start.ArgumentList.Add("--ready-event");
        start.ArgumentList.Add(readyEventName);
        return Process.Start(start)
            ?? throw new XunitException("Failed to start the integration harness.");
    }

    private static void RequireInteractiveWindowsDesktop()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new XunitException("Interactive harness tests require Windows.");
        }

        if (!Environment.UserInteractive || Process.GetCurrentProcess().SessionId == 0)
        {
            throw new XunitException(
                "Interactive harness tests require a logged-in, non-service Windows desktop session.");
        }

        if (AutomationElement.RootElement is null)
        {
            throw new XunitException("Windows UI Automation is unavailable in this session.");
        }
    }
}

internal static class NativeDesktop
{
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool SetForegroundWindow(nint window);
}

internal static class ProcessTreeInspector
{
    private const uint SnapshotProcesses = 0x00000002;
    private static readonly nint InvalidHandleValue = new(-1);

    internal static IReadOnlyList<uint> FindDescendants(uint rootProcessId)
    {
        var snapshot = CreateToolhelp32Snapshot(SnapshotProcesses, 0);
        if (snapshot == InvalidHandleValue)
        {
            throw new XunitException("Could not inspect the harness process tree.");
        }

        try
        {
            var entries = new List<(uint ProcessId, uint ParentProcessId)>();
            var entry = new ProcessEntry32
            {
                Size = checked((uint)Marshal.SizeOf<ProcessEntry32>())
            };
            if (Process32First(snapshot, ref entry))
            {
                do
                {
                    entries.Add((entry.ProcessId, entry.ParentProcessId));
                    entry.Size = checked((uint)Marshal.SizeOf<ProcessEntry32>());
                }
                while (Process32Next(snapshot, ref entry));
            }

            var descendants = new HashSet<uint>();
            var frontier = new Queue<uint>();
            frontier.Enqueue(rootProcessId);
            while (frontier.Count != 0)
            {
                var parent = frontier.Dequeue();
                foreach (var child in entries.Where(item => item.ParentProcessId == parent))
                {
                    if (descendants.Add(child.ProcessId))
                    {
                        frontier.Enqueue(child.ProcessId);
                    }
                }
            }

            return descendants.Order().ToArray();
        }
        finally
        {
            _ = CloseHandle(snapshot);
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ProcessEntry32
    {
        internal uint Size;
        private uint _usage;
        internal uint ProcessId;
        private nuint _defaultHeapId;
        private uint _moduleId;
        private uint _threads;
        internal uint ParentProcessId;
        private int _basePriority;
        private uint _flags;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        private string _executableFile;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern nint CreateToolhelp32Snapshot(uint flags, uint processId);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Process32First(nint snapshot, ref ProcessEntry32 entry);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Process32Next(nint snapshot, ref ProcessEntry32 entry);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(nint handle);
}
