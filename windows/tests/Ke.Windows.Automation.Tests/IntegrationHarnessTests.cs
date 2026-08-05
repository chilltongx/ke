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
        Assert.True(result.Exited);
        Assert.Empty(result.RemainingDescendantProcessIds);
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
