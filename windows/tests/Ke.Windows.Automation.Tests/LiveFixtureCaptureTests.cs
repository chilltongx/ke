using Ke.Windows.Automation;
using Xunit;
using Xunit.Sdk;

namespace Ke.Windows.Automation.Tests;

public sealed class LiveFixtureCaptureTests
{
    [Fact]
    public void Capture_sanitized_focused_control()
    {
        var output = Environment.GetEnvironmentVariable("KE_CAPTURE_FIXTURE");
        if (string.IsNullOrWhiteSpace(output))
        {
            throw SkipException.ForSkip(
                "Set KE_CAPTURE_FIXTURE for interactive capture.");
        }

        var expectedProcess = RequiredEnvironmentVariable("KE_EXPECT_PROCESS");
        var scenario = RequiredEnvironmentVariable("KE_CAPTURE_SCENARIO");
        var application = expectedProcess switch
        {
            "Codex.exe" => "codex",
            "Code.exe" => "visual-studio-code",
            _ => throw new InvalidDataException("KE_EXPECT_PROCESS must be Codex.exe or Code.exe.")
        };

        Thread.Sleep(TimeSpan.FromSeconds(5));
        var capture = new FocusSnapshotProvider().Capture(CancellationToken.None);
        Assert.Null(capture.Error);
        Assert.NotNull(capture.Snapshot);

        FixtureCapture.Write(
            capture.Snapshot,
            expectedProcess,
            application,
            scenario,
            output,
            append: Environment.GetEnvironmentVariable("KE_CAPTURE_APPEND") == "1");
    }

    private static string RequiredEnvironmentVariable(string name)
    {
        var value = Environment.GetEnvironmentVariable(name);
        return string.IsNullOrWhiteSpace(value)
            ? throw new InvalidDataException($"{name} is required for interactive capture.")
            : value;
    }
}
