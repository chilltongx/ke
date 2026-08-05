using Ke.Windows.Automation;
using Ke.Windows.Core;
using Xunit;

namespace Ke.Windows.Automation.Tests;

public sealed class TargetAdapterRegistryTests
{
    [Theory]
    [InlineData("Fixtures/codex-chat-empty.json", SupportedApplication.Codex)]
    [InlineData("Fixtures/vscode-chat-empty.json", SupportedApplication.VisualStudioCode)]
    public void Bootstrap_chat_composer_is_accepted(string path, SupportedApplication app)
    {
        var snapshot = FixtureLoader.Load(path);

        var result = TargetAdapterRegistry.CreateDefault().Classify(snapshot);

        Assert.Null(result.Error);
        Assert.Equal(app, result.Match!.Application);
        Assert.Equal(string.Empty, result.Match.NormalizedText);
        Assert.Equal(snapshot.Hwnd, result.Match.Identity.Hwnd);
        Assert.Equal(snapshot.ProcessId, result.Match.Identity.ProcessId);
        Assert.Equal(snapshot.Focused.RuntimeId, result.Match.Identity.RuntimeId);
        Assert.Equal(app, result.Match.Identity.Application);
    }

    [Theory]
    [InlineData("Fixtures/codex-negative.json")]
    [InlineData("Fixtures/vscode-negative.json")]
    public void Bootstrap_negative_controls_are_rejected(string path)
    {
        foreach (var snapshot in FixtureLoader.LoadMany(path))
        {
            Assert.Equal(
                SendErrorCode.NotChatComposer,
                TargetAdapterRegistry.CreateDefault().Classify(snapshot).Error);
        }
    }

    [Fact]
    public void Known_process_never_uses_another_adapter()
    {
        var codex = FixtureLoader.Load("Fixtures/codex-chat-empty.json") with
        {
            ProcessImageName = "Code.exe"
        };

        Assert.Equal(
            SendErrorCode.NotChatComposer,
            TargetAdapterRegistry.CreateDefault().Classify(codex).Error);
    }

    [Fact]
    public void Unknown_process_is_unsupported_without_a_generic_fallback()
    {
        var snapshot = FixtureLoader.Load("Fixtures/codex-chat-empty.json") with
        {
            ProcessImageName = "Cursor.exe"
        };

        Assert.Equal(
            SendErrorCode.UnsupportedApplication,
            TargetAdapterRegistry.CreateDefault().Classify(snapshot).Error);
    }

    [Fact]
    public void Windows_process_name_casing_is_ignored_but_basename_is_exact()
    {
        var snapshot = FixtureLoader.Load("Fixtures/codex-chat-empty.json");
        var registry = TargetAdapterRegistry.CreateDefault();

        Assert.NotNull(registry.Classify(snapshot with { ProcessImageName = "CODEX.EXE" }).Match);
        Assert.Equal(
            SendErrorCode.UnsupportedApplication,
            registry.Classify(snapshot with { ProcessImageName = "myCodex.exe" }).Error);
    }

    [Theory]
    [InlineData(false, true, false, false)]
    [InlineData(true, false, false, false)]
    [InlineData(true, true, true, false)]
    [InlineData(true, true, false, true)]
    public void Unsafe_focused_state_is_rejected(
        bool enabled,
        bool focusable,
        bool password,
        bool readOnly)
    {
        var snapshot = FixtureLoader.Load("Fixtures/codex-chat-empty.json");
        snapshot = snapshot with
        {
            Focused = snapshot.Focused with
            {
                IsEnabled = enabled,
                IsKeyboardFocusable = focusable,
                IsPassword = password,
                IsReadOnly = readOnly
            }
        };

        Assert.Equal(
            SendErrorCode.NotChatComposer,
            TargetAdapterRegistry.CreateDefault().Classify(snapshot).Error);
    }

    [Fact]
    public void Exact_focused_signature_is_required()
    {
        var snapshot = FixtureLoader.Load("Fixtures/codex-chat-empty.json");
        snapshot = snapshot with
        {
            Focused = snapshot.Focused with { AutomationId = "other-composer" }
        };

        Assert.Equal(
            SendErrorCode.NotChatComposer,
            TargetAdapterRegistry.CreateDefault().Classify(snapshot).Error);
    }

    [Fact]
    public void Deny_token_wins_even_when_allow_token_is_present()
    {
        var snapshot = FixtureLoader.Load("Fixtures/codex-chat-empty.json");
        snapshot = snapshot with
        {
            Ancestors =
            [
                snapshot.Ancestors[0] with { Name = "chat terminal composer" }
            ]
        };

        Assert.Equal(
            SendErrorCode.NotChatComposer,
            TargetAdapterRegistry.CreateDefault().Classify(snapshot).Error);
    }

    [Fact]
    public void At_least_one_allow_token_is_required()
    {
        var snapshot = FixtureLoader.Load("Fixtures/codex-chat-empty.json");
        snapshot = snapshot with
        {
            Focused = snapshot.Focused with { Name = string.Empty },
            Ancestors = snapshot.Ancestors.Select(x => x with { Name = string.Empty }).ToArray(),
            Nearby = snapshot.Nearby.Select(x => x with { Name = string.Empty }).ToArray()
        };

        Assert.Equal(
            SendErrorCode.NotChatComposer,
            TargetAdapterRegistry.CreateDefault().Classify(snapshot).Error);
    }

    [Fact]
    public void Unreadable_and_present_drafts_fail_closed_with_distinct_errors()
    {
        var snapshot = FixtureLoader.Load("Fixtures/vscode-chat-empty.json");
        var registry = TargetAdapterRegistry.CreateDefault();

        Assert.Equal(
            SendErrorCode.AutomationUnavailable,
            registry.Classify(snapshot with
            {
                Focused = snapshot.Focused with { Text = null }
            }).Error);
        Assert.Equal(
            SendErrorCode.DraftPresent,
            registry.Classify(snapshot with
            {
                Focused = snapshot.Focused with { Text = "draft" }
            }).Error);
    }

    [Fact]
    public void Approval_requires_raw_text_exactly_equal_to_product_text()
    {
        var snapshot = FixtureLoader.Load("Fixtures/vscode-chat-empty.json");
        var registry = TargetAdapterRegistry.CreateDefault();

        Assert.NotNull(registry.Validate(snapshot with
        {
            Focused = snapshot.Focused with { Text = ProductInfo.ApprovalText }
        }, ComposerExpectation.Approval).Match);
        Assert.Equal(
            SendErrorCode.DraftPresent,
            registry.Validate(snapshot with
            {
                Focused = snapshot.Focused with { Text = $" {ProductInfo.ApprovalText}" }
            }, ComposerExpectation.Approval).Error);
    }

    [Fact]
    public void Fixture_loader_injects_deterministic_runtime_ids_without_serializing_them()
    {
        var snapshot = FixtureLoader.Load("Fixtures/codex-chat-empty.json");
        var json = File.ReadAllText(FixtureLoader.ResolvePath("Fixtures/codex-chat-empty.json"));

        Assert.Equal("fixture.codex.chat-empty", snapshot.Focused.RuntimeId);
        Assert.DoesNotContain("runtime", json, StringComparison.OrdinalIgnoreCase);
    }
}
