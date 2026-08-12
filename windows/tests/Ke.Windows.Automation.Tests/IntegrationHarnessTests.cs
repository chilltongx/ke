using System.Diagnostics;
using System.Xml.Linq;
using Ke.Windows.Automation;
using Ke.Windows.Core;
using Xunit;

namespace Ke.Windows.Automation.Tests;

public sealed class IntegrationHarnessTests
{
    private static readonly string[] ExpectedAutomationIds =
    [
        "ChatEmpty",
        "DocumentEmpty",
        "Search",
        "Editor",
        "Terminal",
        "Password",
        "ReadOnly",
        "Disabled",
        "FocusChanges",
        "EnterCount"
    ];

    [Fact]
    public void Harness_xaml_exposes_the_exact_control_contract()
    {
        var document = XDocument.Load(HarnessPaths.MainWindowXaml);
        var ids = document.Descendants()
            .SelectMany(element => element.Attributes())
            .Where(attribute =>
                attribute.Name.LocalName == "AutomationProperties.AutomationId")
            .Select(attribute => attribute.Value)
            .Order(StringComparer.Ordinal)
            .ToArray();

        Assert.Equal(
            ExpectedAutomationIds.Order(StringComparer.Ordinal),
            ids);
    }

    [Fact]
    public void Interactive_test_is_skipped_without_explicit_opt_in()
    {
        Assert.NotNull(InteractiveWindowsFactAttribute.GetSkipReason(null));
        Assert.NotNull(InteractiveWindowsFactAttribute.GetSkipReason("0"));
        Assert.Null(InteractiveWindowsFactAttribute.GetSkipReason("1"));
    }

    [Fact]
    public void Production_registry_cannot_reach_the_harness_process()
    {
        var snapshot = HarnessProfile.CreateSnapshot(
            "ChatEmpty",
            "ControlType.Edit",
            "TextBox",
            "Chat composer",
            text: string.Empty);

        Assert.Equal(
            SendErrorCode.UnsupportedApplication,
            TargetAdapterRegistry.CreateDefault().Classify(snapshot).Error);
    }

    [Fact]
    public void Test_profile_accepts_safe_composers_and_rejects_negative_controls()
    {
        var registry = HarnessProfile.CreateRegistry();

        Assert.NotNull(registry.Classify(HarnessProfile.ChatEmpty()).Match);
        Assert.NotNull(registry.Classify(HarnessProfile.DocumentEmpty()).Match);
        Assert.NotNull(registry.Classify(HarnessProfile.FocusChanges()).Match);
        foreach (var snapshot in HarnessProfile.NegativeControls())
        {
            Assert.NotNull(registry.Classify(snapshot).Error);
        }
    }

    [Fact]
    public async Task Readiness_wait_is_bounded()
    {
        var stopwatch = Stopwatch.StartNew();

        var ready = await HarnessReadiness.WaitAsync(
            () => false,
            TimeSpan.FromMilliseconds(80),
            TimeSpan.FromMilliseconds(10));

        Assert.False(ready);
        Assert.InRange(stopwatch.Elapsed, TimeSpan.FromMilliseconds(50), TimeSpan.FromSeconds(1));
    }

    [Fact]
    public async Task Teardown_kills_only_the_exact_process_after_close_timeout()
    {
        var aggregate = Stopwatch.StartNew();
        for (var iteration = 0; iteration < 8; iteration++)
        {
            using var process = Process.Start(new ProcessStartInfo
            {
                FileName = "cmd.exe",
                Arguments = "/d /s /c \"ping 127.0.0.1 -n 30 >nul\"",
                UseShellExecute = false,
                CreateNoWindow = true
            }) ?? throw new InvalidOperationException("Failed to start teardown fixture.");

            var result = await HarnessProcessTeardown.CloseExactAsync(
                process,
                TimeSpan.FromMilliseconds(50),
                descendantConfirmed: null,
                forcedExitTimeout: TimeSpan.FromSeconds(1));

            Assert.True(result.Forced);
            Assert.True(result.Exited, $"Root remained in iteration {iteration}.");
            Assert.True(
                result.RemainingDescendantProcessIds.Count == 0,
                $"Descendants remained in iteration {iteration}: " +
                string.Join(',', result.RemainingDescendantProcessIds));
        }

        Assert.InRange(aggregate.Elapsed, TimeSpan.Zero, TimeSpan.FromSeconds(15));
    }

    [Fact]
    public async Task Teardown_kills_confirmed_child_after_root_exits_first()
    {
        var fixtureDirectory = CreateFixtureDirectory();
        var childPidPath = Path.Combine(fixtureDirectory.FullName, "child.pid");
        using var root = StartRootFirstExitFixture(fixtureDirectory, childPidPath);
        Process? child = null;
        try
        {
            var childProcessId = await WaitForProcessIdAsync(childPidPath, root);
            child = Process.GetProcessById(checked((int)childProcessId));
            _ = child.Handle;
            await WaitForExitAsync(root, TimeSpan.FromSeconds(5));

            var result = await HarnessProcessTeardown.CloseExactAsync(
                root,
                TimeSpan.FromMilliseconds(50));

            Assert.True(result.Forced);
            Assert.True(result.Exited);
            Assert.Empty(result.RemainingDescendantProcessIds);
            Assert.True(child.HasExited);
        }
        finally
        {
            KillExactIfRunning(child);
            child?.Dispose();
            KillExactIfRunning(root);
            fixtureDirectory.Delete(recursive: true);
        }
    }

    [Fact]
    public async Task Teardown_cleans_orphaned_grandchild_without_killing_ping_sentinel()
    {
        var fixtureDirectory = CreateFixtureDirectory();
        var childPidPath = Path.Combine(fixtureDirectory.FullName, "child.pid");
        var grandchildPidPath = Path.Combine(fixtureDirectory.FullName, "grandchild.pid");
        var releasePath = Path.Combine(fixtureDirectory.FullName, "release");
        using var sentinel = StartPing();
        using var root = StartOrphanedGrandchildFixture(
            fixtureDirectory,
            childPidPath,
            grandchildPidPath,
            releasePath);
        Process? grandchild = null;
        try
        {
            var childProcessId = await WaitForProcessIdAsync(childPidPath, root);
            var released = 0;
            var teardown = HarnessProcessTeardown.CloseExactAsync(
                root,
                TimeSpan.FromSeconds(1),
                confirmedProcessId =>
                {
                    if (confirmedProcessId == childProcessId &&
                        Interlocked.Exchange(ref released, 1) == 0)
                    {
                        File.WriteAllText(releasePath, "release");
                    }
                });

            var grandchildProcessId = await WaitForProcessIdAsync(grandchildPidPath, root);
            grandchild = Process.GetProcessById(checked((int)grandchildProcessId));
            _ = grandchild.Handle;
            var result = await teardown;

            Assert.Equal(1, Volatile.Read(ref released));
            Assert.True(result.Forced);
            Assert.True(result.Exited);
            Assert.Empty(result.RemainingDescendantProcessIds);
            Assert.True(grandchild.HasExited);
            Assert.False(sentinel.HasExited);
        }
        finally
        {
            KillExactIfRunning(grandchild);
            grandchild?.Dispose();
            KillExactIfRunning(root);
            KillExactIfRunning(sentinel);
            fixtureDirectory.Delete(recursive: true);
        }
    }

    [Fact]
    public async Task Unresolved_intermediate_remains_discovery_only_frontier()
    {
        var fixtureDirectory = CreateFixtureDirectory();
        var childPidPath = Path.Combine(fixtureDirectory.FullName, "child.pid");
        var grandchildPidPath = Path.Combine(fixtureDirectory.FullName, "grandchild.pid");
        var releasePath = Path.Combine(fixtureDirectory.FullName, "release");
        using var root = StartOrphanedGrandchildFixture(
            fixtureDirectory,
            childPidPath,
            grandchildPidPath,
            releasePath);
        Process? child = null;
        Process? grandchild = null;
        try
        {
            var childProcessId = await WaitForProcessIdAsync(childPidPath, root);
            child = Process.GetProcessById(checked((int)childProcessId));
            _ = child.Handle;
            using var tracker = new ExactDescendantTracker(
                root,
                descendantObserved: processId =>
                {
                    if (processId == childProcessId)
                    {
                        File.WriteAllText(releasePath, "release");
                    }
                },
                identityUnavailable: processId => processId == childProcessId);

            tracker.Discover();
            var grandchildProcessId = await WaitForProcessIdAsync(grandchildPidPath, root);
            grandchild = Process.GetProcessById(checked((int)grandchildProcessId));
            _ = grandchild.Handle;
            await WaitForExitAsync(child, TimeSpan.FromSeconds(5));
            tracker.Discover();

            Assert.Contains(childProcessId, tracker.GetRemainingProcessIds());
            Assert.Contains(grandchildProcessId, tracker.GetRemainingProcessIds());
            tracker.KillRemainingExact();
            Assert.False(grandchild.HasExited);
        }
        finally
        {
            KillExactIfRunning(child);
            child?.Dispose();
            KillExactIfRunning(grandchild);
            grandchild?.Dispose();
            KillExactIfRunning(root);
            fixtureDirectory.Delete(recursive: true);
        }
    }

    [Fact]
    public void Harness_project_has_no_production_project_references()
    {
        var project = XDocument.Load(HarnessPaths.ProjectFile);

        Assert.Empty(project.Descendants("ProjectReference"));
    }

    [InteractiveWindowsFact]
    public async Task Real_pipeline_sends_only_to_safe_harness_composers()
    {
        await HarnessInteractiveScenario.RunAsync();
    }

    private static Process StartPing() =>
        Process.Start(new ProcessStartInfo
        {
            FileName = "ping.exe",
            Arguments = "127.0.0.1 -n 30",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        }) ?? throw new InvalidOperationException("Failed to start ping fixture.");

    private static Process StartOrphanedGrandchildFixture(
        DirectoryInfo fixtureDirectory,
        string childPidPath,
        string grandchildPidPath,
        string releasePath)
    {
        var childScriptPath = Path.Combine(fixtureDirectory.FullName, "child.ps1");
        var rootScriptPath = Path.Combine(fixtureDirectory.FullName, "root.ps1");
        File.WriteAllText(
            childScriptPath,
            $$"""
            $ErrorActionPreference = 'Stop'
            [IO.File]::WriteAllText('{{EscapePowerShell(childPidPath)}}', [string]$PID)
            while (-not (Test-Path -LiteralPath '{{EscapePowerShell(releasePath)}}')) {
                Start-Sleep -Milliseconds 10
            }
            $info = [Diagnostics.ProcessStartInfo]::new()
            $info.FileName = 'ping.exe'
            $info.UseShellExecute = $false
            $info.CreateNoWindow = $true
            $info.ArgumentList.Add('127.0.0.1')
            $info.ArgumentList.Add('-n')
            $info.ArgumentList.Add('30')
            $grandchild = [Diagnostics.Process]::Start($info)
            [IO.File]::WriteAllText(
                '{{EscapePowerShell(grandchildPidPath)}}',
                [string]$grandchild.Id)
            """);
        File.WriteAllText(
            rootScriptPath,
            $$"""
            $ErrorActionPreference = 'Stop'
            $info = [Diagnostics.ProcessStartInfo]::new()
            $info.FileName = 'pwsh.exe'
            $info.UseShellExecute = $false
            $info.CreateNoWindow = $true
            $info.RedirectStandardError = $true
            $info.ArgumentList.Add('-NoLogo')
            $info.ArgumentList.Add('-NoProfile')
            $info.ArgumentList.Add('-NonInteractive')
            $info.ArgumentList.Add('-ExecutionPolicy')
            $info.ArgumentList.Add('Bypass')
            $info.ArgumentList.Add('-File')
            $info.ArgumentList.Add('{{EscapePowerShell(childScriptPath)}}')
            $child = [Diagnostics.Process]::Start($info)
            while ($true) {
                if ($child.HasExited -and
                    -not [IO.File]::Exists('{{EscapePowerShell(grandchildPidPath)}}')) {
                    $childError = $child.StandardError.ReadToEnd()
                    [Console]::Error.WriteLine(
                        'fixture child exited before grandchild readiness; code={0}; stderr={1}',
                        $child.ExitCode,
                        $childError)
                    exit 41
                }
                Start-Sleep -Milliseconds 20
            }
            """);
        return StartPowerShellScript(rootScriptPath);
    }

    private static Process StartRootFirstExitFixture(
        DirectoryInfo fixtureDirectory,
        string childPidPath)
    {
        var childScriptPath = Path.Combine(fixtureDirectory.FullName, "survivor.ps1");
        var rootScriptPath = Path.Combine(fixtureDirectory.FullName, "root-first.ps1");
        File.WriteAllText(
            childScriptPath,
            "while ($true) { Start-Sleep -Milliseconds 100 }");
        File.WriteAllText(
            rootScriptPath,
            $$"""
            $ErrorActionPreference = 'Stop'
            $info = [Diagnostics.ProcessStartInfo]::new()
            $info.FileName = 'pwsh.exe'
            $info.UseShellExecute = $false
            $info.CreateNoWindow = $true
            $info.ArgumentList.Add('-NoLogo')
            $info.ArgumentList.Add('-NoProfile')
            $info.ArgumentList.Add('-NonInteractive')
            $info.ArgumentList.Add('-ExecutionPolicy')
            $info.ArgumentList.Add('Bypass')
            $info.ArgumentList.Add('-File')
            $info.ArgumentList.Add('{{EscapePowerShell(childScriptPath)}}')
            $child = [Diagnostics.Process]::Start($info)
            [IO.File]::WriteAllText('{{EscapePowerShell(childPidPath)}}', [string]$child.Id)
            """);
        return StartPowerShellScript(rootScriptPath);
    }

    private static Process StartPowerShellScript(string scriptPath)
    {
        var start = new ProcessStartInfo
        {
            FileName = "pwsh.exe",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        start.ArgumentList.Add("-NoLogo");
        start.ArgumentList.Add("-NoProfile");
        start.ArgumentList.Add("-NonInteractive");
        start.ArgumentList.Add("-ExecutionPolicy");
        start.ArgumentList.Add("Bypass");
        start.ArgumentList.Add("-File");
        start.ArgumentList.Add(scriptPath);
        return Process.Start(start)
            ?? throw new InvalidOperationException("Failed to start process-tree fixture.");
    }

    private static async Task<uint> WaitForProcessIdAsync(string path, Process root)
    {
        uint processId = 0;
        var ready = await HarnessReadiness.WaitAsync(
            () =>
            {
                try
                {
                    return uint.TryParse(File.ReadAllText(path), out processId) &&
                        processId != 0;
                }
                catch (IOException)
                {
                    return false;
                }
            },
            TimeSpan.FromSeconds(5),
            TimeSpan.FromMilliseconds(20));
        return ready
            ? processId
            : throw new InvalidOperationException(BuildFixtureFailure(path, root));
    }

    private static async Task WaitForExitAsync(Process process, TimeSpan timeout)
    {
        using var cancellation = new CancellationTokenSource(timeout);
        try
        {
            await process.WaitForExitAsync(cancellation.Token);
        }
        catch (OperationCanceledException)
        {
            throw new InvalidOperationException(
                $"Fixture PID {process.Id} did not exit within {timeout.TotalSeconds:F0}s.");
        }
    }

    private static string BuildFixtureFailure(string path, Process root)
    {
        var rootExited = root.HasExited;
        var exitCode = rootExited ? root.ExitCode.ToString() : "running";
        var standardError = rootExited
            ? root.StandardError.ReadToEnd()
            : "<root still running>";
        standardError = standardError
            .Replace('\r', ' ')
            .Replace('\n', ' ');
        if (standardError.Length > 512)
        {
            standardError = standardError[..512];
        }

        var command = string.Join(' ', root.StartInfo.ArgumentList);
        return $"Timed out waiting for fixture PID path '{path}'. " +
            $"Command='pwsh.exe {command}', Exit={exitCode}, Stderr='{standardError}'.";
    }

    private static void KillExactIfRunning(Process? process)
    {
        if (process is null || process.HasExited)
        {
            return;
        }

        process.Kill(entireProcessTree: true);
        Assert.True(process.WaitForExit(5000), $"Fixture PID {process.Id} did not exit.");
    }

    private static string EscapePowerShell(string value) => value.Replace("'", "''");

    private static DirectoryInfo CreateFixtureDirectory() =>
        Directory.CreateDirectory(Path.Combine(
            Path.GetTempPath(),
            $"Ke Windows Process Tree {Guid.NewGuid():N}"));
}

internal sealed class InteractiveWindowsFactAttribute : FactAttribute
{
    public InteractiveWindowsFactAttribute()
    {
        Skip = GetSkipReason(Environment.GetEnvironmentVariable("KE_RUN_INTERACTIVE_TESTS"));
    }

    internal static string? GetSkipReason(string? optIn) =>
        string.Equals(optIn, "1", StringComparison.Ordinal)
            ? null
            : "Set KE_RUN_INTERACTIVE_TESTS=1 on an interactive Windows desktop.";
}
