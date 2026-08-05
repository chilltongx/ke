using System.Text.Json;
using Ke.Windows.Core;
using Xunit;

namespace Ke.Windows.Automation.Tests;

public sealed class FixtureCaptureWriterTests
{
    [Fact]
    public void Process_mismatch_fails_before_touching_output()
    {
        using var directory = new TemporaryDirectory();
        var path = Path.Combine(directory.Path, "fixture.json");
        File.WriteAllText(path, "unchanged");

        Assert.Throws<InvalidDataException>(() => FixtureCapture.Write(
            Snapshot("Code.exe"),
            expectedProcess: "Codex.exe",
            application: "codex",
            scenario: "chat-empty",
            path,
            append: false));

        Assert.Equal("unchanged", File.ReadAllText(path));
    }

    [Fact]
    public void Negative_scenarios_are_atomically_appended_as_an_array()
    {
        using var directory = new TemporaryDirectory();
        var path = Path.Combine(directory.Path, "negative.json");

        FixtureCapture.Write(
            Snapshot("Codex.exe"),
            "Codex.exe",
            "codex",
            "terminal",
            path,
            append: false);
        FixtureCapture.Write(
            Snapshot("Codex.exe"),
            "Codex.exe",
            "codex",
            "search",
            path,
            append: true);

        using var json = JsonDocument.Parse(File.ReadAllText(path));
        Assert.Equal(JsonValueKind.Array, json.RootElement.ValueKind);
        Assert.Equal(2, json.RootElement.GetArrayLength());
        Assert.Equal("terminal", json.RootElement[0].GetProperty("scenario").GetString());
        Assert.Equal("search", json.RootElement[1].GetProperty("scenario").GetString());
        Assert.Empty(Directory.GetFiles(directory.Path, "*.tmp"));
    }

    [Fact]
    public void Chat_empty_is_written_as_a_single_object()
    {
        using var directory = new TemporaryDirectory();
        var path = Path.Combine(directory.Path, "positive.json");

        FixtureCapture.Write(
            Snapshot("Codex.exe"),
            "Codex.exe",
            "codex",
            "chat-empty",
            path,
            append: false);

        using var json = JsonDocument.Parse(File.ReadAllText(path));
        Assert.Equal(JsonValueKind.Object, json.RootElement.ValueKind);
    }

    [Fact]
    public void Unknown_scenario_is_rejected_before_touching_output()
    {
        using var directory = new TemporaryDirectory();
        var path = Path.Combine(directory.Path, "fixture.json");
        File.WriteAllText(path, "unchanged");

        Assert.Throws<InvalidDataException>(() => FixtureCapture.Write(
            Snapshot("Codex.exe"),
            "Codex.exe",
            "codex",
            "private-message",
            path,
            append: false));

        Assert.Equal("unchanged", File.ReadAllText(path));
    }

    [Theory]
    [InlineData(@"C:\Users\alice\Widget")]
    [InlineData("/Users/alice/widget")]
    [InlineData("alice@example.com")]
    [InlineData("DESKTOP-ABC123")]
    [InlineData("alice-account")]
    [InlineData("send this private message")]
    public void Unsafe_class_name_is_rejected_before_file_creation(string unsafeValue)
    {
        using var directory = new TemporaryDirectory();
        var path = Path.Combine(directory.Path, "fixture.json");

        Assert.Throws<InvalidDataException>(() => FixtureCapture.Write(
            Snapshot("Codex.exe", className: unsafeValue),
            "Codex.exe",
            "codex",
            "chat-empty",
            path,
            append: false));

        Assert.False(File.Exists(path));
    }

    [Theory]
    [InlineData(@"C:\Users\alice\Widget")]
    [InlineData("/Users/alice/widget")]
    [InlineData("alice@example.com")]
    [InlineData("DESKTOP-ABC123")]
    [InlineData("alice-account")]
    [InlineData("send this private message")]
    public void Unsafe_automation_id_is_rejected_before_file_creation(string unsafeValue)
    {
        using var directory = new TemporaryDirectory();
        var path = Path.Combine(directory.Path, "fixture.json");

        Assert.Throws<InvalidDataException>(() => FixtureCapture.Write(
            Snapshot("Codex.exe", automationId: unsafeValue),
            "Codex.exe",
            "codex",
            "chat-empty",
            path,
            append: false));

        Assert.False(File.Exists(path));
    }

    private static FocusSnapshot Snapshot(
        string process,
        string className = "Chrome_RenderWidgetHostHWND",
        string automationId = "input-primary") => new(
        (nint)1,
        2,
        process,
        0x2000,
        0x2000,
        new ElementSummary(
            "private.runtime",
            "ControlType.Edit",
            className,
            automationId,
            "chat composer",
            true,
            true,
            false,
            false,
            string.Empty),
        [],
        []);

    private sealed class TemporaryDirectory : IDisposable
    {
        public TemporaryDirectory()
        {
            Path = System.IO.Path.Combine(
                System.IO.Path.GetTempPath(),
                $"ke-fixture-{Guid.NewGuid():N}");
            Directory.CreateDirectory(Path);
        }

        public string Path { get; }

        public void Dispose() => Directory.Delete(Path, recursive: true);
    }
}
