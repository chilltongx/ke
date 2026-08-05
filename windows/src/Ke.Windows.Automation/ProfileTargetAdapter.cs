using Ke.Windows.Core;

namespace Ke.Windows.Automation;

public sealed record TargetMatch(
    SupportedApplication Application,
    string NormalizedText,
    TargetIdentity Identity);

public sealed record TargetClassification(TargetMatch? Match, SendErrorCode? Error);

public interface ITargetAdapter
{
    string ProcessImageName { get; }

    TargetClassification Classify(
        FocusSnapshot snapshot,
        ComposerExpectation expectation);
}

public enum ComposerExpectation
{
    Empty,
    Approval
}

internal sealed class ProfileTargetAdapter(AdapterProfile profile) : ITargetAdapter
{
    public string ProcessImageName => profile.ProcessImageName;

    public TargetClassification Classify(
        FocusSnapshot snapshot,
        ComposerExpectation expectation)
    {
        if (!string.Equals(
                snapshot.ProcessImageName,
                profile.ProcessImageName,
                StringComparison.OrdinalIgnoreCase))
        {
            return Failure(SendErrorCode.NotChatComposer);
        }

        var signature = new ElementSignature(
            snapshot.Focused.ControlType,
            snapshot.Focused.ClassName,
            snapshot.Focused.AutomationId);
        if (!profile.FocusedSignatures.Contains(signature))
        {
            return Failure(SendErrorCode.NotChatComposer);
        }

        if (!snapshot.Focused.IsEnabled ||
            !snapshot.Focused.IsKeyboardFocusable ||
            snapshot.Focused.IsPassword ||
            snapshot.Focused.IsReadOnly)
        {
            return Failure(SendErrorCode.NotChatComposer);
        }

        var context = snapshot.Ancestors.Concat(snapshot.Nearby).ToArray();
        if (context.Any(element => ContainsAnyToken(element, profile.NegativeTokens)))
        {
            return Failure(SendErrorCode.NotChatComposer);
        }

        if (!context.Prepend(snapshot.Focused)
                .Any(element => ContainsAnyToken(element, profile.PositiveTokens)))
        {
            return Failure(SendErrorCode.NotChatComposer);
        }

        string normalizedText;
        switch (expectation)
        {
            case ComposerExpectation.Empty:
                var draft = DraftPolicy.Classify(
                    snapshot.Focused.Text,
                    profile.AllowedEmptyArtifacts);
                if (draft.State == DraftState.Unreadable)
                {
                    return Failure(SendErrorCode.AutomationUnavailable);
                }

                if (draft.State == DraftState.Present)
                {
                    return Failure(SendErrorCode.DraftPresent);
                }

                normalizedText = draft.NormalizedText!;
                break;

            case ComposerExpectation.Approval:
                if (snapshot.Focused.Text is null ||
                    snapshot.Focused.Text.Length > DraftPolicy.MaximumTextLength)
                {
                    return Failure(SendErrorCode.AutomationUnavailable);
                }

                if (!string.Equals(
                        snapshot.Focused.Text,
                        ProductInfo.ApprovalText,
                        StringComparison.Ordinal))
                {
                    return Failure(SendErrorCode.DraftPresent);
                }

                normalizedText = ProductInfo.ApprovalText;
                break;

            default:
                return Failure(SendErrorCode.AutomationUnavailable);
        }

        var identity = new TargetIdentity(
            snapshot.Hwnd,
            snapshot.ProcessId,
            snapshot.Focused.RuntimeId,
            profile.Application);
        return new(
            new TargetMatch(profile.Application, normalizedText, identity),
            null);
    }

    private static bool ContainsAnyToken(
        ElementSummary element,
        IReadOnlySet<string> tokens)
    {
        var source = string.Join(
            ' ',
            element.ControlType,
            element.ClassName,
            element.AutomationId,
            element.Name);
        return tokens.Any(token => ContainsBoundedToken(source, token));
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

    private static TargetClassification Failure(SendErrorCode error) => new(null, error);
}
