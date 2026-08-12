using System.Text.Json;
using Ke.Windows.Core;
using Xunit;

namespace Ke.Windows.Automation.Tests;

public sealed class FixtureSanitizerTests
{
    private static readonly HashSet<string> FixtureProperties =
    [
        "application", "processImageName", "scenario", "focused", "ancestors", "nearby"
    ];

    private static readonly HashSet<string> ElementProperties =
    [
        "controlType", "className", "automationId", "genericRoleTokens", "isEnabled",
        "isKeyboardFocusable", "isPassword", "isReadOnly", "textShape",
        "emptyArtifactUtf16Hex"
    ];

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
        AssertFixtureSchema(json);
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
            "settings");

        Assert.Equal(["settings"], result.Focused.GenericRoleTokens);
    }

    [Theory]
    [InlineData(true, @"C:\Users\alice\Widget")]
    [InlineData(true, "alice@example.com")]
    [InlineData(false, "/Users/alice/widget")]
    [InlineData(false, "send this private message")]
    public void Loader_rejects_tampered_technical_identifiers(
        bool tamperClassName,
        string unsafeValue)
    {
        var fixture = FixtureSanitizer.Sanitize(
            Snapshot("", "chat composer"),
            "codex",
            "chat-empty");
        fixture = fixture with
        {
            Focused = tamperClassName
                ? fixture.Focused with { ClassName = unsafeValue }
                : fixture.Focused with { AutomationId = unsafeValue }
        };
        var path = Path.Combine(
            Path.GetTempPath(),
            $"ke-tampered-fixture-{Guid.NewGuid():N}.json");

        try
        {
            File.WriteAllText(path, JsonSerializer.Serialize(fixture, FixtureJson.Options));
            Assert.Throws<InvalidDataException>(() => FixtureLoader.Load(path));
        }
        finally
        {
            File.Delete(path);
        }
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
            "input-primary",
            name,
            IsEnabled: true,
            IsKeyboardFocusable: true,
            IsPassword: false,
            IsReadOnly: false,
            text),
        [],
        []);

    private static void AssertFixtureSchema(string json)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        Assert.Equal(JsonValueKind.Object, root.ValueKind);
        AssertExactProperties(root, FixtureProperties);
        AssertElement(root.GetProperty("focused"));

        AssertElements(root.GetProperty("ancestors"));
        AssertElements(root.GetProperty("nearby"));
    }

    private static void AssertElements(JsonElement elements)
    {
        Assert.Equal(JsonValueKind.Array, elements.ValueKind);
        foreach (var element in elements.EnumerateArray())
        {
            AssertElement(element);
        }
    }

    private static void AssertElement(JsonElement element)
    {
        Assert.Equal(JsonValueKind.Object, element.ValueKind);
        AssertExactProperties(element, ElementProperties);
    }

    private static void AssertExactProperties(
        JsonElement element,
        IReadOnlySet<string> expected)
    {
        var actual = element.EnumerateObject()
            .Select(property => property.Name)
            .ToHashSet(StringComparer.Ordinal);
        Assert.True(
            actual.SetEquals(expected),
            $"Unexpected JSON properties. Actual: {string.Join(", ", actual.Order())}");
    }
}
