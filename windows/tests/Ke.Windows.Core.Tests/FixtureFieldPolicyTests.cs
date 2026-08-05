using Ke.Windows.Core;
using Xunit;

namespace Ke.Windows.Core.Tests;

public sealed class FixtureFieldPolicyTests
{
    [Theory]
    [InlineData("codex", "Codex.exe", "chat-empty")]
    [InlineData("codex", "Codex.exe", "terminal")]
    [InlineData("codex", "Codex.exe", "search")]
    [InlineData("codex", "Codex.exe", "settings")]
    [InlineData("codex", "Codex.exe", "approval")]
    [InlineData("visual-studio-code", "Code.exe", "chat-empty")]
    [InlineData("visual-studio-code", "Code.exe", "editor")]
    [InlineData("visual-studio-code", "Code.exe", "terminal")]
    [InlineData("visual-studio-code", "Code.exe", "search")]
    [InlineData("visual-studio-code", "Code.exe", "settings")]
    [InlineData("visual-studio-code", "Code.exe", "command-palette")]
    [InlineData("visual-studio-code", "Code.exe", "quick-open")]
    public void Reviewed_application_process_and_scenarios_are_allowed(
        string application,
        string process,
        string scenario) =>
        FixtureFieldPolicy.ValidateMetadata(application, process, scenario);

    [Theory]
    [InlineData("codex", "Codex.exe", "editor")]
    [InlineData("codex", "Codex.exe", "anything-user-entered")]
    [InlineData("visual-studio-code", "Code.exe", "approval")]
    [InlineData("visual-studio-code", "Code.exe", "private-message")]
    [InlineData("unknown", "Unknown.exe", "chat-empty")]
    [InlineData("codex", "Code.exe", "chat-empty")]
    public void Unknown_or_cross_application_metadata_is_rejected(
        string application,
        string process,
        string scenario) =>
        Assert.Throws<InvalidDataException>(() =>
            FixtureFieldPolicy.ValidateMetadata(application, process, scenario));

    [Theory]
    [InlineData("ControlType.Edit", "Chrome_RenderWidgetHostHWND", "input-primary")]
    [InlineData("ControlType.Pane", "Chrome_WidgetWin_1", "container-primary")]
    [InlineData("ControlType.Edit", "monaco-editor", "workbench.panel.input")]
    [InlineData("ControlType.Pane", "part panel", "command palette")]
    public void Reviewed_technical_identifiers_are_allowed(
        string controlType,
        string className,
        string automationId) =>
        FixtureFieldPolicy.ValidateElementIdentifiers(
            controlType,
            className,
            automationId);

    [Theory]
    [InlineData(@"C:\Users\alice\Widget")]
    [InlineData("/Users/alice/widget")]
    [InlineData("alice@example.com")]
    [InlineData("DESKTOP-ABC123")]
    [InlineData("alice-account")]
    [InlineData("send this private message")]
    public void Arbitrary_or_private_values_are_rejected_in_class_and_automation_id(
        string unsafeValue)
    {
        Assert.Throws<InvalidDataException>(() =>
            FixtureFieldPolicy.ValidateElementIdentifiers(
                "ControlType.Edit",
                unsafeValue,
                "input-primary"));
        Assert.Throws<InvalidDataException>(() =>
            FixtureFieldPolicy.ValidateElementIdentifiers(
                "ControlType.Edit",
                "Chrome_RenderWidgetHostHWND",
                unsafeValue));
    }

    [Theory]
    [InlineData("empty", "")]
    [InlineData("contenteditable-break", "000A")]
    [InlineData("contenteditable-break", "000D000A")]
    [InlineData("non-empty", null)]
    public void Reviewed_text_shape_and_artifact_pairs_are_allowed(
        string textShape,
        string? artifact) =>
        FixtureFieldPolicy.ValidateElementSchema(
            "ControlType.Edit",
            "Chrome_RenderWidgetHostHWND",
            "input-primary",
            ["chat", "composer"],
            textShape,
            artifact,
            requireEmptyComposer: false);

    [Theory]
    [InlineData("empty", null)]
    [InlineData("empty", "000A")]
    [InlineData("contenteditable-break", "")]
    [InlineData("contenteditable-break", "0041")]
    [InlineData("contenteditable-break", "433A5C5573657273")]
    [InlineData("contenteditable-break", "616C696365406578616D706C652E636F6D")]
    [InlineData("contenteditable-break", "73656E642070726976617465206D657373616765")]
    [InlineData("non-empty", "")]
    [InlineData("unknown", null)]
    public void Mismatched_or_arbitrary_artifacts_are_rejected(
        string textShape,
        string? artifact) =>
        Assert.Throws<InvalidDataException>(() =>
            FixtureFieldPolicy.ValidateElementSchema(
                "ControlType.Edit",
                "Chrome_RenderWidgetHostHWND",
                "input-primary",
                ["chat"],
                textShape,
                artifact,
                requireEmptyComposer: false));

    [Fact]
    public void Positive_profile_focused_element_must_be_empty() =>
        Assert.Throws<InvalidDataException>(() =>
            FixtureFieldPolicy.ValidateElementSchema(
                "ControlType.Edit",
                "Chrome_RenderWidgetHostHWND",
                "input-primary",
                ["chat"],
                "non-empty",
                null,
                requireEmptyComposer: true));

    [Theory]
    [InlineData("Chat")]
    [InlineData("private message")]
    [InlineData("account@example.com")]
    public void Unreviewed_role_tokens_are_rejected(string token) =>
        Assert.Throws<InvalidDataException>(() =>
            FixtureFieldPolicy.ValidateElementSchema(
                "ControlType.Edit",
                "Chrome_RenderWidgetHostHWND",
                "input-primary",
                [token],
                "empty",
                "",
                requireEmptyComposer: true));
}
