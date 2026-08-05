using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Ke.Windows.Core;

namespace Ke.Windows.Automation.Tests;

public sealed record SanitizedFixture(
    string Application,
    string ProcessImageName,
    string Scenario,
    SanitizedElement Focused,
    IReadOnlyList<SanitizedElement> Ancestors,
    IReadOnlyList<SanitizedElement> Nearby);

public sealed record SanitizedElement(
    string ControlType,
    string ClassName,
    string AutomationId,
    IReadOnlyList<string> GenericRoleTokens,
    bool IsEnabled,
    bool IsKeyboardFocusable,
    bool IsPassword,
    bool IsReadOnly,
    string TextShape,
    string? EmptyArtifactUtf16Hex);

internal static class FixtureJson
{
    public static JsonSerializerOptions Options { get; } = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = false,
        WriteIndented = true,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };
}

internal static class FixtureSanitizer
{
    public static SanitizedFixture Sanitize(
        FocusSnapshot snapshot,
        string application,
        string scenario)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(application);
        ArgumentException.ThrowIfNullOrWhiteSpace(scenario);
        FixtureFieldPolicy.ValidateMetadata(
            application,
            snapshot.ProcessImageName,
            scenario);
        return new(
            application,
            snapshot.ProcessImageName,
            scenario,
            Sanitize(snapshot.Focused, requireText: true),
            snapshot.Ancestors.Select(x => Sanitize(x, requireText: false)).ToArray(),
            snapshot.Nearby.Select(x => Sanitize(x, requireText: false)).ToArray());
    }

    private static SanitizedElement Sanitize(ElementSummary element, bool requireText)
    {
        var (shape, artifact) = DescribeText(element.Text, requireText);
        var tokenSource = string.Join(
            ' ',
            element.ControlType,
            element.ClassName,
            element.AutomationId,
            element.Name);
        var tokens = FixtureFieldPolicy.ApprovedRoleTokens
            .Where(token => ContainsBoundedToken(tokenSource, token))
            .ToArray();

        var sanitized = new SanitizedElement(
            element.ControlType,
            element.ClassName,
            element.AutomationId,
            tokens,
            element.IsEnabled,
            element.IsKeyboardFocusable,
            element.IsPassword,
            element.IsReadOnly,
            shape,
            artifact);
        FixtureFieldPolicy.ValidateElementSchema(
            sanitized.ControlType,
            sanitized.ClassName,
            sanitized.AutomationId,
            sanitized.GenericRoleTokens,
            sanitized.TextShape,
            sanitized.EmptyArtifactUtf16Hex,
            requireEmptyComposer: false);
        return sanitized;
    }

    private static (string Shape, string? Artifact) DescribeText(
        string? text,
        bool requireText)
    {
        if (!requireText)
        {
            return ("non-empty", null);
        }

        return text switch
        {
            null => throw new InvalidDataException(
                "Focused text must be readable before a fixture can be captured."),
            "" => ("empty", ""),
            "\n" => ("contenteditable-break", "000A"),
            "\r\n" => ("contenteditable-break", "000D000A"),
            _ => ("non-empty", null)
        };
    }

    private static bool ContainsBoundedToken(string source, string token)
    {
        var start = 0;
        while (start < source.Length)
        {
            var index = source.IndexOf(token, start, StringComparison.OrdinalIgnoreCase);
            if (index < 0)
            {
                return false;
            }

            var leftBoundary = index == 0 || !char.IsLetterOrDigit(source[index - 1]);
            var after = index + token.Length;
            var rightBoundary = after == source.Length || !char.IsLetterOrDigit(source[after]);
            if (leftBoundary && rightBoundary)
            {
                return true;
            }

            start = index + 1;
        }

        return false;
    }
}

internal static class FixtureCapture
{
    public static void Write(
        FocusSnapshot snapshot,
        string expectedProcess,
        string application,
        string scenario,
        string path,
        bool append)
    {
        if (!string.Equals(
                snapshot.ProcessImageName,
                expectedProcess,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException(
                $"Expected process '{expectedProcess}' but focused '{snapshot.ProcessImageName}'.");
        }

        var fixture = FixtureSanitizer.Sanitize(snapshot, application, scenario);
        var isPositive = string.Equals(scenario, "chat-empty", StringComparison.Ordinal);
        if (isPositive && append)
        {
            throw new InvalidDataException("A chat-empty fixture cannot be appended.");
        }

        object payload;
        if (isPositive)
        {
            payload = fixture;
        }
        else
        {
            var fixtures = append
                ? FixtureLoader.ReadSanitizedMany(path).ToList()
                : [];
            fixtures.Add(fixture);
            payload = fixtures;
        }

        WriteAtomically(path, JsonSerializer.Serialize(payload, FixtureJson.Options));
    }

    private static void WriteAtomically(string path, string contents)
    {
        var fullPath = Path.GetFullPath(path);
        var directory = Path.GetDirectoryName(fullPath)
            ?? throw new InvalidDataException("Fixture path must have a parent directory.");
        Directory.CreateDirectory(directory);
        var temporaryPath = Path.Combine(
            directory,
            $"{Path.GetFileName(fullPath)}.{Guid.NewGuid():N}.tmp");

        try
        {
            File.WriteAllText(temporaryPath, contents, new UTF8Encoding(false));
            File.Move(temporaryPath, fullPath, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }
}

internal static class FixtureLoader
{
    public static FocusSnapshot Load(string path)
    {
        var fixture = ReadSanitized(ResolvePath(path));
        return ToSnapshot(fixture);
    }

    public static IReadOnlyList<FocusSnapshot> LoadMany(string path) =>
        ReadSanitizedMany(ResolvePath(path)).Select(ToSnapshot).ToArray();

    public static string ResolvePath(string path)
    {
        if (Path.IsPathRooted(path))
        {
            return path;
        }

        var outputPath = Path.Combine(AppContext.BaseDirectory, path);
        if (File.Exists(outputPath))
        {
            return outputPath;
        }

        return Path.GetFullPath(path);
    }

    internal static IReadOnlyList<SanitizedFixture> ReadSanitizedMany(string path)
    {
        using var stream = File.OpenRead(path);
        var fixtures = JsonSerializer.Deserialize<List<SanitizedFixture>>(
            stream,
            FixtureJson.Options) ?? throw InvalidFixture();
        foreach (var fixture in fixtures)
        {
            Validate(fixture);
        }

        return fixtures;
    }

    private static SanitizedFixture ReadSanitized(string path)
    {
        using var stream = File.OpenRead(path);
        var fixture = JsonSerializer.Deserialize<SanitizedFixture>(stream, FixtureJson.Options)
            ?? throw InvalidFixture();
        Validate(fixture);
        return fixture;
    }

    private static FocusSnapshot ToSnapshot(SanitizedFixture fixture)
    {
        var runtimeId = $"fixture.{fixture.Application}.{fixture.Scenario}";
        return new(
            (nint)1,
            1,
            fixture.ProcessImageName,
            0x2000,
            0x2000,
            ToSummary(fixture.Focused, runtimeId, includeText: true),
            fixture.Ancestors.Select((x, index) =>
                ToSummary(x, $"{runtimeId}.ancestor.{index}", includeText: false)).ToArray(),
            fixture.Nearby.Select((x, index) =>
                ToSummary(x, $"{runtimeId}.nearby.{index}", includeText: false)).ToArray());
    }

    private static ElementSummary ToSummary(
        SanitizedElement element,
        string runtimeId,
        bool includeText) => new(
            runtimeId,
            element.ControlType,
            element.ClassName,
            element.AutomationId,
            string.Join(' ', element.GenericRoleTokens),
            element.IsEnabled,
            element.IsKeyboardFocusable,
            element.IsPassword,
            element.IsReadOnly,
            includeText ? DecodeText(element) : null);

    private static string DecodeText(SanitizedElement element) => element.TextShape switch
    {
        "empty" => string.Empty,
        "contenteditable-break" => DecodeArtifact(element.EmptyArtifactUtf16Hex),
        "non-empty" => "fixture-non-empty",
        _ => throw InvalidFixture()
    };

    private static string DecodeArtifact(string? artifact) => artifact switch
    {
        "" => string.Empty,
        "000A" => "\n",
        "000D000A" => "\r\n",
        _ => throw InvalidFixture()
    };

    private static void Validate(SanitizedFixture fixture)
    {
        if (fixture.Application is not ("codex" or "visual-studio-code") ||
            string.IsNullOrWhiteSpace(fixture.Scenario) ||
            fixture.Focused is null || fixture.Ancestors is null || fixture.Nearby is null)
        {
            throw InvalidFixture();
        }

        FixtureFieldPolicy.ValidateMetadata(
            fixture.Application,
            fixture.ProcessImageName,
            fixture.Scenario);
        ValidateElement(fixture.Focused);
        foreach (var element in fixture.Ancestors.Concat(fixture.Nearby))
        {
            ValidateElement(element);
        }
    }

    private static void ValidateElement(SanitizedElement element)
    {
        FixtureFieldPolicy.ValidateElementSchema(
            element.ControlType,
            element.ClassName,
            element.AutomationId,
            element.GenericRoleTokens,
            element.TextShape,
            element.EmptyArtifactUtf16Hex,
            requireEmptyComposer: false);
    }

    private static InvalidDataException InvalidFixture() =>
        new("The sanitized fixture is malformed or contains a non-allowlisted value.");
}
