using System.Text.Json;
using Ke.Windows.Core;
using Xunit;

namespace Ke.Windows.Automation.Tests;

public sealed class FixtureSanitizerTests
{
    [Fact]
    public void Sanitizer_emits_only_generic_tokens_and_never_raw_private_fields()
    {
        var snapshot = Snapshot(
            text: "private message",
            name: @"C:\Users\alice\secret chat / personal@example.com");

        var fixture = FixtureSanitizer.Sanitize(snapshot, "codex", "chat-empty");
        var json = JsonSerializer.Serialize(fixture, FixtureJson.Options);

        Assert.Equal(["chat"], fixture.Focused.GenericRoleTokens);
        Assert.Equal("non-empty", fixture.Focused.TextShape);
        Assert.Null(fixture.Focused.EmptyArtifactUtf16Hex);
        Assert.DoesNotContain("alice", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("secret", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("private message", json, StringComparison.Ordinal);
        Assert.DoesNotContain("RuntimeId", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("\"name\":", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("Hwnd", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("ProcessId", json, StringComparison.OrdinalIgnoreCase);
    }

    [Theory]
    [InlineData("", "empty", "")]
    [InlineData("\n", "contenteditable-break", "000A")]
    [InlineData("\r\n", "contenteditable-break", "000D000A")]
    [InlineData(" ", "non-empty", null)]
    [InlineData("\t", "non-empty", null)]
    [InlineData("可", "non-empty", null)]
    public void Text_is_reduced_to_an_allowlisted_shape(
        string text,
        string expectedShape,
        string? expectedArtifact)
    {
        var result = FixtureSanitizer.Sanitize(
            Snapshot(text, "chat composer"),
            "codex",
            "chat-empty");

        Assert.Equal(expectedShape, result.Focused.TextShape);
        Assert.Equal(expectedArtifact, result.Focused.EmptyArtifactUtf16Hex);
    }

    [Fact]
    public void Null_text_is_rejected_instead_of_becoming_an_empty_profile()
    {
        Assert.Throws<InvalidDataException>(() => FixtureSanitizer.Sanitize(
            Snapshot(null, "chat composer"),
            "codex",
            "chat-empty"));
    }

    [Fact]
    public void Token_matching_requires_a_role_boundary()
    {
        var result = FixtureSanitizer.Sanitize(
            Snapshot("", "chatter terminally settings-panel"),
            "codex",
            "negative");

        Assert.Equal(["chat", "settings"], result.Focused.GenericRoleTokens);
    }

    private static FocusSnapshot Snapshot(string? text, string name) => new(
        (nint)24,
        101,
        "Codex.exe",
        0x2000,
        0x2000,
        new ElementSummary(
            "private.runtime.id",
            "ControlType.Edit",
            "Chrome_RenderWidgetHostHWND",
            "chat-input",
            name,
            IsEnabled: true,
            IsKeyboardFocusable: true,
            IsPassword: false,
            IsReadOnly: false,
            text),
        [],
        []);
}
