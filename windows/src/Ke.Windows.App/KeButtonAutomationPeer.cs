using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;

namespace Ke.Windows.App;

public sealed class KeButtonAutomationPeer(FrameworkElement owner)
    : FrameworkElementAutomationPeer(owner)
{
    private string _helpText = string.Empty;

    public void PublishResult(string message)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(message);
        var previous = _helpText;
        _helpText = message;
        RaisePropertyChangedEvent(
            AutomationElementIdentifiers.HelpTextProperty,
            previous,
            message);
        RaiseNotificationEvent(
            AutomationNotificationKind.ActionCompleted,
            AutomationNotificationProcessing.ImportantMostRecent,
            message,
            "Ke.SendResult");
    }

    protected override string GetNameCore() => "可";

    protected override string GetHelpTextCore() => _helpText;

    protected override string GetClassNameCore() => "KeButton";

    protected override AutomationControlType GetAutomationControlTypeCore() =>
        AutomationControlType.Button;
}
