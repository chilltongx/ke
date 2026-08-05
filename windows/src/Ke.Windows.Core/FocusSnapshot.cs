namespace Ke.Windows.Core;

public sealed record ElementSummary(
    string RuntimeId,
    string ControlType,
    string ClassName,
    string AutomationId,
    string Name,
    bool IsEnabled,
    bool IsKeyboardFocusable,
    bool IsPassword,
    bool IsReadOnly,
    string? Text);

public sealed record FocusSnapshot(
    nint Hwnd,
    uint ProcessId,
    string ProcessImageName,
    int SourceIntegrityRid,
    int TargetIntegrityRid,
    ElementSummary Focused,
    IReadOnlyList<ElementSummary> Ancestors,
    IReadOnlyList<ElementSummary> Nearby);

public sealed record TargetIdentity(
    nint Hwnd,
    uint ProcessId,
    string RuntimeId,
    SupportedApplication Application);
