using Ke.Windows.Core;

namespace Ke.Windows.Automation;

public interface IFocusedChatSender
{
    SendResult TrySend(CancellationToken cancellationToken);
}

public sealed class FocusedChatSender(
    IFocusSnapshotProvider snapshotProvider,
    TargetAdapterRegistry adapterRegistry,
    IWindowsInputWriter inputWriter) : IFocusedChatSender
{
    public SendResult TrySend(CancellationToken cancellationToken)
    {
        try
        {
            var first = CaptureAndClassify(ComposerExpectation.Empty, cancellationToken);
            if (first.Error is not null)
            {
                return SendResult.Failure(first.Error.Value);
            }

            cancellationToken.ThrowIfCancellationRequested();

            var second = CaptureAndClassify(ComposerExpectation.Empty, cancellationToken);
            if (second.Error == SendErrorCode.AutomationTimeout)
            {
                return SendResult.Failure(SendErrorCode.AutomationTimeout);
            }

            if (second.Match is null ||
                !IsSameTargetAndText(first.Match!, second.Match))
            {
                return SendResult.Failure(SendErrorCode.TargetChanged);
            }

            if (!inputWriter.AreModifierKeysReleased())
            {
                return SendResult.Failure(SendErrorCode.ModifierKeyDown);
            }

            cancellationToken.ThrowIfCancellationRequested();

            var write = inputWriter.WriteApproval(second.Match.Identity, cancellationToken);
            if (!write.IsSuccess)
            {
                return SendResult.Failure(SendErrorCode.WriteUnconfirmed);
            }

            cancellationToken.ThrowIfCancellationRequested();

            var third = CaptureAndClassify(ComposerExpectation.Approval, cancellationToken);
            if (third.Error == SendErrorCode.AutomationTimeout)
            {
                return SendResult.Failure(SendErrorCode.AutomationTimeout);
            }

            if (third.Match is null ||
                !IsSameIdentity(second.Match.Identity, third.Match.Identity) ||
                !string.Equals(
                    third.Match.NormalizedText,
                    ProductInfo.ApprovalText,
                    StringComparison.Ordinal))
            {
                return SendResult.Failure(SendErrorCode.WriteUnconfirmed);
            }

            if (!inputWriter.AreModifierKeysReleased())
            {
                return SendResult.Failure(SendErrorCode.ModifierKeyDown);
            }

            cancellationToken.ThrowIfCancellationRequested();

            return inputWriter.SendEnter(third.Match.Identity, cancellationToken)
                ? SendResult.Success()
                : SendResult.Failure(SendErrorCode.ReturnDeliveryFailed);
        }
        catch (OperationCanceledException)
        {
            return SendResult.Failure(SendErrorCode.AutomationTimeout);
        }
        catch (Exception)
        {
            return SendResult.Failure(SendErrorCode.AutomationUnavailable);
        }
    }

    private TargetClassification CaptureAndClassify(
        ComposerExpectation expectation,
        CancellationToken cancellationToken)
    {
        var capture = snapshotProvider.Capture(cancellationToken);
        if (capture.Snapshot is null)
        {
            return new(null, capture.Error ?? SendErrorCode.AutomationUnavailable);
        }

        return adapterRegistry.Validate(capture.Snapshot, expectation);
    }

    private static bool IsSameTargetAndText(TargetMatch first, TargetMatch second) =>
        IsSameIdentity(first.Identity, second.Identity) &&
        first.Application == second.Application &&
        string.Equals(first.NormalizedText, second.NormalizedText, StringComparison.Ordinal);

    private static bool IsSameIdentity(TargetIdentity first, TargetIdentity second) =>
        first.Hwnd == second.Hwnd &&
        first.ProcessId == second.ProcessId &&
        string.Equals(first.RuntimeId, second.RuntimeId, StringComparison.Ordinal) &&
        first.Application == second.Application;
}
