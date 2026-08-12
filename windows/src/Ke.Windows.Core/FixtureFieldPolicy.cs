using System.IO;
using System.Collections.ObjectModel;

namespace Ke.Windows.Core;

public static class FixtureFieldPolicy
{
    private static readonly IReadOnlyDictionary<string, ApplicationPolicy> Applications =
        new Dictionary<string, ApplicationPolicy>(StringComparer.Ordinal)
        {
            ["codex"] = new(
                "Codex.exe",
                new HashSet<string>(
                    ["chat-empty", "terminal", "search", "settings", "approval"],
                    StringComparer.Ordinal)),
            ["visual-studio-code"] = new(
                "Code.exe",
                new HashSet<string>(
                    [
                        "chat-empty", "editor", "terminal", "search", "settings",
                        "command-palette", "quick-open"
                    ],
                    StringComparer.Ordinal))
        };

    private static readonly HashSet<string> AllowedControlTypes = new(
        ["ControlType.Edit", "ControlType.Pane"],
        StringComparer.Ordinal);

    private static readonly HashSet<string> AllowedClassNames = new(
    [
        "Chrome_RenderWidgetHostHWND",
        "Chrome_WidgetWin_1",
        "monaco-editor",
        "part panel"
    ],
        StringComparer.Ordinal);

    private static readonly HashSet<string> AllowedAutomationIds = new(
    [
        "input-primary",
        "workbench.panel.input",
        "container-primary",
        "terminal",
        "search",
        "settings",
        "approval",
        "editor",
        "command palette",
        "quick open"
    ],
        StringComparer.Ordinal);

    private static readonly string[] ApprovedRoleTokenValues =
    [
        "chat", "conversation", "composer", "message", "copilot", "editor", "terminal",
        "search", "settings", "command palette", "quick open", "approval", "聊天", "对话",
        "消息", "编辑器", "终端", "搜索", "设置", "命令面板", "快速打开", "审批"
    ];

    private static readonly HashSet<string> AllowedRoleTokens = new(
        ApprovedRoleTokenValues,
        StringComparer.Ordinal);

    private static readonly ReadOnlyCollection<string> RoleTokens =
        Array.AsReadOnly(ApprovedRoleTokenValues);

    public static IReadOnlyList<string> ApprovedRoleTokens => RoleTokens;

    public static void ValidateMetadata(
        string application,
        string processImageName,
        string scenario)
    {
        if (!Applications.TryGetValue(application, out var policy) ||
            !string.Equals(processImageName, policy.ProcessImageName, StringComparison.Ordinal) ||
            !policy.Scenarios.Contains(scenario))
        {
            throw Rejected();
        }
    }

    public static void ValidateElementIdentifiers(
        string controlType,
        string className,
        string automationId)
    {
        if (!AllowedControlTypes.Contains(controlType) ||
            !AllowedClassNames.Contains(className) ||
            !AllowedAutomationIds.Contains(automationId))
        {
            throw Rejected();
        }
    }

    public static void ValidateElementSchema(
        string controlType,
        string className,
        string automationId,
        IReadOnlyList<string> genericRoleTokens,
        string textShape,
        string? emptyArtifactUtf16Hex,
        bool requireEmptyComposer)
    {
        ValidateElementIdentifiers(controlType, className, automationId);
        if (genericRoleTokens is null ||
            genericRoleTokens.Distinct(StringComparer.Ordinal).Count() !=
                genericRoleTokens.Count ||
            genericRoleTokens.Any(token => !AllowedRoleTokens.Contains(token)) ||
            !IsValidTextPair(textShape, emptyArtifactUtf16Hex) ||
            requireEmptyComposer && textShape == "non-empty")
        {
            throw Rejected();
        }
    }

    private static bool IsValidTextPair(string textShape, string? artifact) =>
        textShape switch
        {
            "empty" => artifact == string.Empty,
            "contenteditable-break" => artifact is "000A" or "000D000A",
            "non-empty" => artifact is null,
            _ => false
        };

    private static InvalidDataException Rejected() =>
        new("Fixture metadata contains an unreviewed value.");

    private sealed record ApplicationPolicy(
        string ProcessImageName,
        IReadOnlySet<string> Scenarios);
}
