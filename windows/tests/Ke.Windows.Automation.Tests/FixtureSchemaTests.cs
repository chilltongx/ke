using System.Text.Json;
using Ke.Windows.Automation;
using Ke.Windows.Core;
using Xunit;

namespace Ke.Windows.Automation.Tests;

public sealed class FixtureSchemaTests
{
    private static readonly string[] FixtureNames =
    [
        "codex-chat-empty.json",
        "codex-negative.json",
        "vscode-chat-empty.json",
        "vscode-negative.json"
    ];

    [Theory]
    [MemberData(nameof(FixtureFiles))]
    public void Source_fixture_and_test_copy_are_byte_identical(string filename)
    {
        var source = Path.Combine(FindRepositoryFixtureDirectory(), filename);
        var copy = Path.Combine(AppContext.BaseDirectory, "Fixtures", filename);

        Assert.Equal(File.ReadAllBytes(source), File.ReadAllBytes(copy));
    }

    [Theory]
    [MemberData(nameof(FixtureFiles))]
    public void Every_committed_source_fixture_element_is_accepted_by_shared_policy(
        string filename)
    {
        var path = Path.Combine(FindRepositoryFixtureDirectory(), filename);
        var fixtures = ReadFixtures(path);
        var elementCount = 0;

        foreach (var fixture in fixtures)
        {
            FixtureFieldPolicy.ValidateMetadata(
                fixture.Application,
                fixture.ProcessImageName,
                fixture.Scenario);
            foreach (var element in fixture.Ancestors
                         .Prepend(fixture.Focused)
                         .Concat(fixture.Nearby))
            {
                FixtureFieldPolicy.ValidateElementSchema(
                    element.ControlType,
                    element.ClassName,
                    element.AutomationId,
                    element.GenericRoleTokens,
                    element.TextShape,
                    element.EmptyArtifactUtf16Hex,
                    requireEmptyComposer: false);
                elementCount++;
            }
        }

        Assert.True(elementCount > 0);
    }

    [Theory]
    [InlineData("empty", "000A")]
    [InlineData("contenteditable-break", @"C:\Users\alice\draft")]
    [InlineData("non-empty", "alice@example.com")]
    [InlineData("contenteditable-break", "0041")]
    [InlineData("message", "send this private message")]
    public void Embedded_profile_element_validation_rejects_tampered_schema(
        string textShape,
        string? artifact)
    {
        var element = new AdapterProfiles.ProfileElement(
            "ControlType.Pane",
            "Chrome_WidgetWin_1",
            "container-primary",
            ["chat"],
            IsEnabled: true,
            IsKeyboardFocusable: false,
            IsPassword: false,
            IsReadOnly: false,
            textShape,
            artifact);

        Assert.Throws<InvalidDataException>(() =>
            AdapterProfiles.ValidateElement(element, requireEmptyComposer: false));
    }

    [Theory]
    [InlineData(true, "empty", "000A")]
    [InlineData(false, "contenteditable-break", @"C:\Users\alice\draft")]
    [InlineData(true, "non-empty", "alice@example.com")]
    [InlineData(false, "contenteditable-break", "0041")]
    [InlineData(true, "message", "send this private message")]
    public void Loader_rejects_tampered_ancestor_or_nearby_schema(
        bool tamperAncestor,
        string textShape,
        string? artifact)
    {
        var source = Path.Combine(
            AppContext.BaseDirectory,
            "Fixtures",
            "codex-chat-empty.json");
        var fixture = JsonSerializer.Deserialize<SanitizedFixture>(
            File.ReadAllText(source),
            FixtureJson.Options)!;
        var tampered = fixture.Ancestors[0] with
        {
            TextShape = textShape,
            EmptyArtifactUtf16Hex = artifact
        };
        fixture = tamperAncestor
            ? fixture with { Ancestors = [tampered] }
            : fixture with { Nearby = [tampered] };
        var path = Path.Combine(
            Path.GetTempPath(),
            $"ke-tampered-schema-{Guid.NewGuid():N}.json");

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

    public static IEnumerable<object[]> FixtureFiles() =>
        FixtureNames.Select(filename => new object[] { filename });

    private static IReadOnlyList<SanitizedFixture> ReadFixtures(string path)
    {
        using var document = JsonDocument.Parse(File.ReadAllText(path));
        return document.RootElement.ValueKind == JsonValueKind.Array
            ? JsonSerializer.Deserialize<List<SanitizedFixture>>(
                document.RootElement.GetRawText(),
                FixtureJson.Options)!
            :
            [
                JsonSerializer.Deserialize<SanitizedFixture>(
                    document.RootElement.GetRawText(),
                    FixtureJson.Options)!
            ];
    }

    private static string FindRepositoryFixtureDirectory()
    {
        for (var current = new DirectoryInfo(AppContext.BaseDirectory);
             current is not null;
             current = current.Parent)
        {
            var candidate = Path.Combine(current.FullName, "windows", "fixtures");
            if (File.Exists(Path.Combine(candidate, "codex-chat-empty.json")))
            {
                return candidate;
            }
        }

        throw new DirectoryNotFoundException("Could not locate windows/fixtures.");
    }
}
