using System.IO;

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

    private static InvalidDataException Rejected() =>
        new("Fixture metadata contains an unreviewed value.");

    private sealed record ApplicationPolicy(
        string ProcessImageName,
        IReadOnlySet<string> Scenarios);
}
