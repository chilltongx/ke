using Ke.Windows.Core;
using Xunit;

namespace Ke.Windows.Core.Tests;

public sealed class DraftPolicyTests
{
    private static readonly HashSet<string> NoArtifacts = [];

    [Theory]
    [InlineData(" ")]
    [InlineData("\t")]
    [InlineData("\n")]
    [InlineData("\u200B")]
    [InlineData("draft")]
    public void User_content_is_never_empty(string text) =>
        Assert.Equal(DraftState.Present, DraftPolicy.Classify(text, NoArtifacts).State);

    [Fact]
    public void Only_explicit_fixture_artifact_normalizes_to_empty() =>
        Assert.Equal(
            DraftState.Empty,
            DraftPolicy.Classify("\r\n", new HashSet<string> { "\r\n" }).State);

    [Fact]
    public void Null_or_over_limit_text_is_unreadable()
    {
        Assert.Equal(DraftState.Unreadable, DraftPolicy.Classify(null, NoArtifacts).State);
        Assert.Equal(
            DraftState.Unreadable,
            DraftPolicy.Classify(new string('x', 4097), NoArtifacts).State);
    }
}
