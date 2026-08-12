using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;

namespace Ke.Windows.App;

public interface IKeAutomationEventSink
{
    void RaisePropertyChanged(
        AutomationProperty property,
        object? previous,
        object? current);

    void RaiseNotification(
        AutomationNotificationKind kind,
        AutomationNotificationProcessing processing,
        string message,
        string activityId);
}

public sealed class KeButtonAutomationPeer : FrameworkElementAutomationPeer
{
    private readonly IKeAutomationEventSink _events;
    private string _helpText = string.Empty;

    public KeButtonAutomationPeer(FrameworkElement owner)
        : this(owner, events: null)
    {
    }

    public KeButtonAutomationPeer(
        FrameworkElement owner,
        IKeAutomationEventSink? events)
        : base(owner)
    {
        _events = events ?? new PeerAutomationEventSink(this);
    }

    public void PublishResult(string message)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(message);
        var previous = _helpText;
        _helpText = message;
        _events.RaisePropertyChanged(
            AutomationElementIdentifiers.HelpTextProperty,
            previous,
            message);
        _events.RaiseNotification(
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

    private void RaiseAutomationPropertyChanged(
        AutomationProperty property,
        object? previous,
        object? current) =>
        RaisePropertyChangedEvent(property, previous, current);

    private void RaiseResultNotification(
        AutomationNotificationKind kind,
        AutomationNotificationProcessing processing,
        string message,
        string activityId) =>
        RaiseNotificationEvent(kind, processing, message, activityId);

    private sealed class PeerAutomationEventSink(KeButtonAutomationPeer peer)
        : IKeAutomationEventSink
    {
        public void RaisePropertyChanged(
            AutomationProperty property,
            object? previous,
            object? current) =>
            peer.RaiseAutomationPropertyChanged(property, previous, current);

        public void RaiseNotification(
            AutomationNotificationKind kind,
            AutomationNotificationProcessing processing,
            string message,
            string activityId) =>
            peer.RaiseResultNotification(kind, processing, message, activityId);
    }
}
