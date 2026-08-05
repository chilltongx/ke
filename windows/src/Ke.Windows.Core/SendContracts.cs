namespace Ke.Windows.Core;

public enum SendErrorCode
{
    UnsupportedApplication,
    NotChatComposer,
    DraftPresent,
    TargetChanged,
    AutomationUnavailable,
    AutomationTimeout,
    ModifierKeyDown,
    ElevatedTarget,
    WriteUnconfirmed,
    ReturnDeliveryFailed
}

public sealed record SendResult(bool IsSuccess, SendErrorCode? Error)
{
    public static SendResult Success() => new(true, null);

    public static SendResult Failure(SendErrorCode error) => new(false, error);
}

public enum SupportedApplication
{
    Codex,
    VisualStudioCode
}
