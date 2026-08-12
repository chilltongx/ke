namespace Ke.Windows.Core;

public enum DraftState
{
    Empty,
    Present,
    Unreadable
}

public sealed record DraftDecision(DraftState State, string? NormalizedText);

public static class DraftPolicy
{
    public const int MaximumTextLength = 4096;

    public static DraftDecision Classify(string? text, IReadOnlySet<string> allowedEmptyArtifacts)
    {
        if (text is null || text.Length > MaximumTextLength)
        {
            return new(DraftState.Unreadable, null);
        }

        if (text.Length == 0 || allowedEmptyArtifacts.Contains(text))
        {
            return new(DraftState.Empty, string.Empty);
        }

        return new(DraftState.Present, text);
    }
}
