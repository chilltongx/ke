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
    [InlineData("ControlType.Edit", "monaco-editor", "input-primary")]
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
}
