using System.Reflection;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using Ke.Windows.Core;

namespace Ke.Windows.Automation;

internal sealed record ElementSignature(
    string ControlType,
    string ClassName,
    string AutomationId);

internal sealed record AdapterProfile(
    string ProcessImageName,
    SupportedApplication Application,
    IReadOnlySet<ElementSignature> FocusedSignatures,
    IReadOnlySet<string> PositiveTokens,
    IReadOnlySet<string> NegativeTokens,
    IReadOnlySet<string> AllowedEmptyArtifacts);

internal static class AdapterProfiles
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = false,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };

    private static readonly HashSet<string> AllowedRoleTokens = new(
    [
        "chat", "conversation", "composer", "message", "copilot", "editor", "terminal",
        "search", "settings", "command palette", "quick open", "approval", "聊天", "对话",
        "消息", "编辑器", "终端", "搜索", "设置", "命令面板", "快速打开", "审批"
    ],
        StringComparer.Ordinal);

    internal static readonly AdapterProfile Codex = Load(
        "codex-chat-empty.json",
        "Codex.exe",
        "codex",
        SupportedApplication.Codex,
        ["chat", "conversation", "composer", "message", "聊天", "对话", "消息"],
        ["editor", "terminal", "search", "settings", "approval", "编辑器", "终端", "搜索", "设置", "审批"]);

    internal static readonly AdapterProfile VisualStudioCode = Load(
        "vscode-chat-empty.json",
        "Code.exe",
        "visual-studio-code",
        SupportedApplication.VisualStudioCode,
        ["chat", "copilot", "composer", "message", "聊天", "对话", "消息"],
        ["editor", "terminal", "search", "settings", "command palette", "quick open", "编辑器", "终端", "搜索", "设置", "命令面板", "快速打开"]);

    private static AdapterProfile Load(
        string filename,
        string expectedProcess,
        string expectedApplication,
        SupportedApplication application,
        string[] positiveTokens,
        string[] negativeTokens)
    {
        var assembly = typeof(AdapterProfiles).Assembly;
        var resourceName = assembly.GetManifestResourceNames().SingleOrDefault(
            name => name.EndsWith($".{filename}", StringComparison.Ordinal));
        if (resourceName is null)
        {
            throw InvalidProfile();
        }

        using var stream = assembly.GetManifestResourceStream(resourceName)
            ?? throw InvalidProfile();
        var fixture = JsonSerializer.Deserialize<ProfileFixture>(stream, JsonOptions)
            ?? throw InvalidProfile();
        Validate(fixture, expectedProcess, expectedApplication);

        return new(
            expectedProcess,
            application,
            new HashSet<ElementSignature>
            {
                new(
                    fixture.Focused.ControlType,
                    fixture.Focused.ClassName,
                    fixture.Focused.AutomationId)
            },
            new HashSet<string>(positiveTokens, StringComparer.Ordinal),
            new HashSet<string>(negativeTokens, StringComparer.Ordinal),
            new HashSet<string>(
                [DecodeArtifact(fixture.Focused.EmptyArtifactUtf16Hex)],
                StringComparer.Ordinal));
    }

    private static void Validate(
        ProfileFixture fixture,
        string expectedProcess,
        string expectedApplication)
    {
        if (fixture.Application != expectedApplication ||
            fixture.ProcessImageName != expectedProcess ||
            fixture.Scenario != "chat-empty" ||
            fixture.Focused is null ||
            fixture.Ancestors is null ||
            fixture.Nearby is null ||
            string.IsNullOrEmpty(fixture.Focused.ControlType) ||
            fixture.Focused.GenericRoleTokens is null ||
            fixture.Focused.TextShape is not ("empty" or "contenteditable-break"))
        {
            throw InvalidProfile();
        }

        foreach (var element in fixture.Ancestors
                     .Prepend(fixture.Focused)
                     .Concat(fixture.Nearby))
        {
            if (element.GenericRoleTokens is null ||
                element.GenericRoleTokens.Any(token => !AllowedRoleTokens.Contains(token)))
            {
                throw InvalidProfile();
            }
        }

        _ = DecodeArtifact(fixture.Focused.EmptyArtifactUtf16Hex);
    }

    private static string DecodeArtifact(string? artifact) => artifact switch
    {
        "" => string.Empty,
        "000A" => "\n",
        "000D000A" => "\r\n",
        _ => throw InvalidProfile()
    };

    private static InvalidDataException InvalidProfile() =>
        new("An embedded adapter profile is missing or malformed.");

    private sealed record ProfileFixture(
        string Application,
        string ProcessImageName,
        string Scenario,
        ProfileElement Focused,
        IReadOnlyList<ProfileElement> Ancestors,
        IReadOnlyList<ProfileElement> Nearby);

    private sealed record ProfileElement(
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
}
