using System.Diagnostics;
using System.Text;
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
        for (var iteration = 0; iteration < 20; iteration++)
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
                TimeSpan.FromMilliseconds(50));

            Assert.True(result.Forced);
            Assert.True(result.Exited, $"Root remained in iteration {iteration}.");
            Assert.True(
                result.RemainingDescendantProcessIds.Count == 0,
                $"Descendants remained in iteration {iteration}: " +
                string.Join(',', result.RemainingDescendantProcessIds));
        }
    }

    [Fact]
    public async Task Teardown_cleans_orphaned_grandchild_without_killing_ping_sentinel()
    {
        var fixtureDirectory = Directory.CreateDirectory(Path.Combine(
            Path.GetTempPath(),
            $"Ke.Windows.ProcessTree.{Guid.NewGuid():N}"));
        var childPidPath = Path.Combine(fixtureDirectory.FullName, "child.pid");
        var grandchildPidPath = Path.Combine(fixtureDirectory.FullName, "grandchild.pid");
        var releasePath = Path.Combine(fixtureDirectory.FullName, "release");
        using var sentinel = StartPing();
        using var root = StartOrphanedGrandchildFixture(
            childPidPath,
            grandchildPidPath,
            releasePath);
        Process? grandchild = null;
        try
        {
            var childProcessId = await WaitForProcessIdAsync(childPidPath);
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

            var grandchildProcessId = await WaitForProcessIdAsync(grandchildPidPath);
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
        string childPidPath,
        string grandchildPidPath,
        string releasePath)
    {
        var childScript = string.Join(
            ';',
            $"[IO.File]::WriteAllText('{EscapePowerShell(childPidPath)}',[string]$PID)",
            $"while(-not (Test-Path -LiteralPath '{EscapePowerShell(releasePath)}'))" +
            "{Start-Sleep -Milliseconds 10}",
            "$p=Start-Process -FilePath 'ping.exe' " +
            "-ArgumentList @('127.0.0.1','-n','30') -WindowStyle Hidden -PassThru",
            $"[IO.File]::WriteAllText('{EscapePowerShell(grandchildPidPath)}',[string]$p.Id)");
        var childEncoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(childScript));
        var rootScript =
            "$null=Start-Process -FilePath 'powershell.exe' " +
            "-ArgumentList @('-NoLogo','-NoProfile','-NonInteractive'," +
            $"'-EncodedCommand','{childEncoded}') -WindowStyle Hidden;" +
            "while($true){Start-Sleep -Milliseconds 100}";
        var rootEncoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(rootScript));
        var start = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        start.ArgumentList.Add("-NoLogo");
        start.ArgumentList.Add("-NoProfile");
        start.ArgumentList.Add("-NonInteractive");
        start.ArgumentList.Add("-EncodedCommand");
        start.ArgumentList.Add(rootEncoded);
        return Process.Start(start)
            ?? throw new InvalidOperationException("Failed to start process-tree fixture.");
    }

    private static async Task<uint> WaitForProcessIdAsync(string path)
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
            : throw new InvalidOperationException("Timed out waiting for a fixture process ID.");
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
