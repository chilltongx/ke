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
    public void Carriage_return_line_feed_without_explicit_artifact_is_present() =>
        Assert.Equal(DraftState.Present, DraftPolicy.Classify("\r\n", NoArtifacts).State);

    [Fact]
    public void Empty_text_is_empty_without_an_artifact() =>
        Assert.Equal(DraftState.Empty, DraftPolicy.Classify(string.Empty, NoArtifacts).State);

    [Fact]
    public void Maximum_length_text_is_present_and_next_length_is_unreadable()
    {
        Assert.Equal(
            DraftState.Present,
            DraftPolicy.Classify(new string('x', 4096), NoArtifacts).State);
        Assert.Equal(
            DraftState.Unreadable,
            DraftPolicy.Classify(new string('x', 4097), NoArtifacts).State);
    }

    [Fact]
    public void Null_or_over_limit_text_is_unreadable()
    {
        Assert.Equal(DraftState.Unreadable, DraftPolicy.Classify(null, NoArtifacts).State);
        Assert.Equal(
            DraftState.Unreadable,
            DraftPolicy.Classify(new string('x', 4097), NoArtifacts).State);
    }
}
