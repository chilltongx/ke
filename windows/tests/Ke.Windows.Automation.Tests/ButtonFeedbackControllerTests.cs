using Ke.Windows.App;
using Ke.Windows.Core;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using Xunit;

namespace Ke.Windows.Automation.Tests;

public sealed class ButtonFeedbackControllerTests
{
    public static TheoryData<SendErrorCode, string> ErrorMessages => new()
    {
        { SendErrorCode.UnsupportedApplication, "当前只支持 Codex 和 VS Code" },
        { SendErrorCode.NotChatComposer, "请先点击 Codex 或 VS Code 的聊天输入框" },
        { SendErrorCode.DraftPresent, "输入框已有内容，未发送" },
        { SendErrorCode.TargetChanged, "焦点已变化，未发送" },
        { SendErrorCode.AutomationUnavailable, "无法安全读取当前输入框" },
        { SendErrorCode.AutomationTimeout, "读取输入框超时，没有按回车" },
        { SendErrorCode.ModifierKeyDown, "请松开 Ctrl、Alt、Shift 或 Windows 键后重试" },
        { SendErrorCode.ElevatedTarget, "目标可能以管理员身份运行，未发送" },
        { SendErrorCode.WriteUnconfirmed, "写入未确认，没有按回车" },
        { SendErrorCode.ReturnDeliveryFailed, "无法发送回车，不会重试" }
    };

    [Theory]
    [MemberData(nameof(ErrorMessages))]
    public void Error_code_has_exact_Chinese_message(SendErrorCode error, string expected)
    {
        Assert.Equal(expected, ButtonFeedbackController.MessageFor(error));
    }

    [Fact]
    public async Task Success_uses_mint_style_for_650ms_and_tooltip_for_at_most_2500ms()
    {
        var view = new RecordingFeedbackView();
        var delay = new ManualFeedbackDelay();
        using var controller = new ButtonFeedbackController(view, delay, animationsEnabled: true);

        var sequence = controller.ShowResultAsync(SendResult.Success());

        Assert.Equal(ButtonFeedbackVisual.Success, view.Visual);
        Assert.Equal("已发送可", view.ToolTip);
        Assert.Equal("已发送可", Assert.Single(view.AccessibilityMessages));
        Assert.True(view.LastAnimate);
        Assert.Equal(
            new[] { TimeSpan.FromMilliseconds(650), TimeSpan.FromMilliseconds(2500) },
            delay.Requested.Order());

        var visualChanged = view.WaitForVisual(ButtonFeedbackVisual.Idle);
        delay.Complete(TimeSpan.FromMilliseconds(650));
        await visualChanged;
        Assert.Equal(ButtonFeedbackVisual.Idle, view.Visual);
        Assert.Equal("已发送可", view.ToolTip);

        var tooltipCleared = view.WaitForToolTip(message: null);
        delay.Complete(TimeSpan.FromMilliseconds(2500));
        await tooltipCleared;
        await sequence;
        Assert.Null(view.ToolTip);
    }

    [Fact]
    public async Task Failure_uses_red_ring_for_900ms()
    {
        var view = new RecordingFeedbackView();
        var delay = new ManualFeedbackDelay();
        using var controller = new ButtonFeedbackController(view, delay, animationsEnabled: true);

        var sequence = controller.ShowResultAsync(
            SendResult.Failure(SendErrorCode.DraftPresent));

        Assert.Equal(ButtonFeedbackVisual.Failure, view.Visual);
        Assert.Equal("输入框已有内容，未发送", view.ToolTip);
        var visualChanged = view.WaitForVisual(ButtonFeedbackVisual.Idle);
        delay.Complete(TimeSpan.FromMilliseconds(900));
        await visualChanged;
        Assert.Equal(ButtonFeedbackVisual.Idle, view.Visual);

        var tooltipCleared = view.WaitForToolTip(message: null);
        delay.Complete(TimeSpan.FromMilliseconds(2500));
        await tooltipCleared;
        await sequence;
    }

    [Fact]
    public void Pressed_is_96_percent_and_reduced_motion_never_animates()
    {
        var view = new RecordingFeedbackView();
        using var controller = new ButtonFeedbackController(
            view,
            new ManualFeedbackDelay(),
            animationsEnabled: false);

        controller.ShowPressed();

        Assert.Equal(ButtonFeedbackVisual.Pressed, view.Visual);
        Assert.Equal(0.96, view.Scale);
        Assert.False(view.LastAnimate);
    }

    [Fact]
    public void Released_press_returns_to_idle_immediately()
    {
        var view = new RecordingFeedbackView();
        using var controller = new ButtonFeedbackController(
            view,
            new ManualFeedbackDelay(),
            animationsEnabled: true);
        controller.ShowPressed();

        controller.ShowIdle();

        Assert.Equal(ButtonFeedbackVisual.Idle, view.Visual);
        Assert.Equal(1, view.Scale);
        Assert.Null(view.ToolTip);
    }

    [Fact]
    public async Task Earlier_generation_cannot_reset_newer_result()
    {
        var view = new RecordingFeedbackView();
        var delay = new ManualFeedbackDelay();
        using var controller = new ButtonFeedbackController(view, delay, animationsEnabled: true);

        var first = controller.ShowResultAsync(SendResult.Success());
        var second = controller.ShowResultAsync(
            SendResult.Failure(SendErrorCode.TargetChanged));

        delay.CompleteOccurrence(TimeSpan.FromMilliseconds(650), occurrence: 1);
        delay.CompleteOccurrence(TimeSpan.FromMilliseconds(2500), occurrence: 1);
        await first;
        Assert.Equal(ButtonFeedbackVisual.Failure, view.Visual);
        Assert.Equal("焦点已变化，未发送", view.ToolTip);

        var idle = view.WaitForVisual(ButtonFeedbackVisual.Idle);
        var tooltipCleared = view.WaitForToolTip(message: null);
        delay.CompleteOccurrence(TimeSpan.FromMilliseconds(900), occurrence: 1);
        delay.CompleteOccurrence(TimeSpan.FromMilliseconds(2500), occurrence: 2);
        await idle;
        await tooltipCleared;
        await second;
        Assert.Equal(ButtonFeedbackVisual.Idle, view.Visual);
        Assert.Null(view.ToolTip);
    }

    [Fact]
    public async Task Repeated_feedback_waits_for_view_continuations_without_sleep()
    {
        const int repetitions = 100;
        var view = new RecordingFeedbackView();
        var delay = new ManualFeedbackDelay();
        using var controller = new ButtonFeedbackController(view, delay, animationsEnabled: true);

        for (var index = 1; index <= repetitions; index++)
        {
            var sequence = controller.ShowResultAsync(SendResult.Success());
            var idle = view.WaitForVisual(ButtonFeedbackVisual.Idle);
            var tooltipCleared = view.WaitForToolTip(message: null);

            delay.CompleteOccurrence(ButtonFeedbackController.SuccessDuration, index);
            await idle;
            delay.CompleteOccurrence(ButtonFeedbackController.ToolTipDuration, index);
            await tooltipCleared;
            await sequence;

            Assert.Equal(ButtonFeedbackVisual.Idle, view.Visual);
            Assert.Null(view.ToolTip);
        }
    }

    [Fact]
    public async Task Automation_peer_has_exact_name_and_current_help_text()
    {
        await RunStaAsync(
            () =>
            {
                var peer = new KeButtonAutomationPeer(new Border());

                Assert.Equal("可", peer.GetName());
                Assert.Equal(string.Empty, peer.GetHelpText());

                peer.PublishResult("焦点已变化，未发送");

                Assert.Equal("焦点已变化，未发送", peer.GetHelpText());
            });
    }

    [Fact]
    public async Task Automation_peer_publishes_exact_property_and_notification_events()
    {
        await RunStaAsync(
            () =>
            {
                var events = new RecordingAutomationEventSink();
                var peer = new KeButtonAutomationPeer(new Border(), events);

                peer.PublishResult("已发送可");
                peer.PublishResult("输入框已有内容，未发送");

                Assert.Equal(
                    new (AutomationProperty, object?, object?)[]
                    {
                        (AutomationElementIdentifiers.HelpTextProperty, string.Empty, "已发送可"),
                        (AutomationElementIdentifiers.HelpTextProperty, "已发送可", "输入框已有内容，未发送")
                    },
                    events.PropertyChanges);
                Assert.All(
                    events.Notifications,
                    notification =>
                    {
                        Assert.Equal(
                            AutomationNotificationKind.ActionCompleted,
                            notification.Kind);
                        Assert.Equal(
                            AutomationNotificationProcessing.ImportantMostRecent,
                            notification.Processing);
                        Assert.Equal("Ke.SendResult", notification.ActivityId);
                    });
                Assert.Equal(
                    new[] { "已发送可", "输入框已有内容，未发送" },
                    events.Notifications.Select(notification => notification.Message));
            });
    }

    [Fact]
    public async Task Wpf_view_preserves_exact_idle_success_and_failure_palette()
    {
        await RunStaAsync(
            () =>
            {
                var disc = new Border();
                var glyph = new TextBlock();
                var view = new WpfButtonFeedbackView(disc, glyph, disc, _ => { });

                view.ApplyVisual(ButtonFeedbackVisual.Idle, 1, animate: false);
                AssertPalette(disc, glyph, "#1E1E1F", "#55D6BE", "#F6F7F8");

                view.ApplyVisual(ButtonFeedbackVisual.Success, 1, animate: false);
                AssertPalette(disc, glyph, "#55D6BE", "#FFF8E7", "#1E1E1F");

                view.ApplyVisual(ButtonFeedbackVisual.Failure, 1, animate: false);
                AssertPalette(disc, glyph, "#1E1E1F", "#FF5A5F", "#F6F7F8");
                Assert.False(((SolidColorBrush)disc.Background).HasAnimatedProperties);
                Assert.False(((SolidColorBrush)disc.BorderBrush).HasAnimatedProperties);
                Assert.False(((SolidColorBrush)glyph.Foreground).HasAnimatedProperties);
                Assert.False(((ScaleTransform)disc.RenderTransform).HasAnimatedProperties);
            });
    }

    private static void AssertPalette(
        Border disc,
        TextBlock glyph,
        string background,
        string border,
        string foreground)
    {
        Assert.Equal(
            (Color)ColorConverter.ConvertFromString(background),
            ((SolidColorBrush)disc.Background).Color);
        Assert.Equal(
            (Color)ColorConverter.ConvertFromString(border),
            ((SolidColorBrush)disc.BorderBrush).Color);
        Assert.Equal(
            (Color)ColorConverter.ConvertFromString(foreground),
            ((SolidColorBrush)glyph.Foreground).Color);
    }

    private static Task RunStaAsync(Action action)
    {
        var completion = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(
            () =>
            {
                try
                {
                    action();
                    completion.TrySetResult();
                }
                catch (Exception exception)
                {
                    completion.TrySetException(exception);
                }
            });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        return completion.Task;
    }

    private sealed class RecordingFeedbackView : IButtonFeedbackView
    {
        private readonly object _gate = new();
        private readonly List<VisualWaiter> _visualWaiters = [];
        private readonly List<ToolTipWaiter> _toolTipWaiters = [];

        public ButtonFeedbackVisual Visual { get; private set; }

        public double Scale { get; private set; } = 1;

        public bool LastAnimate { get; private set; }

        public string? ToolTip { get; private set; }

        public List<string> AccessibilityMessages { get; } = [];

        public Task WaitForVisual(ButtonFeedbackVisual visual)
        {
            lock (_gate)
            {
                var completion = NewCompletion();
                _visualWaiters.Add(new(visual, completion));
                return completion.Task;
            }
        }

        public Task WaitForToolTip(string? message)
        {
            lock (_gate)
            {
                var completion = NewCompletion();
                _toolTipWaiters.Add(new(message, completion));
                return completion.Task;
            }
        }

        public void ApplyVisual(
            ButtonFeedbackVisual visual,
            double scale,
            bool animate)
        {
            TaskCompletionSource[] changed;
            lock (_gate)
            {
                Visual = visual;
                Scale = scale;
                LastAnimate = animate;
                changed = _visualWaiters
                    .Where(waiter => waiter.Visual == visual)
                    .Select(waiter => waiter.Completion)
                    .ToArray();
                _visualWaiters.RemoveAll(waiter => waiter.Visual == visual);
            }

            foreach (var completion in changed)
            {
                completion.TrySetResult();
            }
        }

        public void SetToolTip(string? message)
        {
            TaskCompletionSource[] changed;
            lock (_gate)
            {
                ToolTip = message;
                changed = _toolTipWaiters
                    .Where(waiter => waiter.Message == message)
                    .Select(waiter => waiter.Completion)
                    .ToArray();
                _toolTipWaiters.RemoveAll(waiter => waiter.Message == message);
            }

            foreach (var completion in changed)
            {
                completion.TrySetResult();
            }
        }

        public void PublishAccessibility(string message) =>
            AccessibilityMessages.Add(message);

        private static TaskCompletionSource NewCompletion() =>
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        private sealed record VisualWaiter(
            ButtonFeedbackVisual Visual,
            TaskCompletionSource Completion);

        private sealed record ToolTipWaiter(
            string? Message,
            TaskCompletionSource Completion);
    }

    private sealed class RecordingAutomationEventSink : IKeAutomationEventSink
    {
        public List<(AutomationProperty Property, object? Previous, object? Current)>
            PropertyChanges { get; } = [];

        public List<Notification> Notifications { get; } = [];

        public void RaisePropertyChanged(
            AutomationProperty property,
            object? previous,
            object? current) =>
            PropertyChanges.Add((property, previous, current));

        public void RaiseNotification(
            AutomationNotificationKind kind,
            AutomationNotificationProcessing processing,
            string message,
            string activityId) =>
            Notifications.Add(new(kind, processing, message, activityId));

        public sealed record Notification(
            AutomationNotificationKind Kind,
            AutomationNotificationProcessing Processing,
            string Message,
            string ActivityId);
    }

    private sealed class ManualFeedbackDelay : IFeedbackDelay
    {
        private readonly object _gate = new();
        private readonly List<DelayRequest> _requests = [];

        public IReadOnlyList<TimeSpan> Requested
        {
            get
            {
                lock (_gate)
                {
                    return _requests.Select(request => request.Duration).ToArray();
                }
            }
        }

        public Task DelayAsync(TimeSpan duration, CancellationToken cancellationToken)
        {
            lock (_gate)
            {
                var completion = new TaskCompletionSource(
                    TaskCreationOptions.RunContinuationsAsynchronously);
                cancellationToken.Register(() => completion.TrySetCanceled(cancellationToken));
                _requests.Add(new(duration, completion));
                return completion.Task;
            }
        }

        public void Complete(TimeSpan duration) => CompleteOccurrence(duration, 1);

        public void CompleteOccurrence(TimeSpan duration, int occurrence)
        {
            lock (_gate)
            {
                var request = _requests
                    .Where(candidate => candidate.Duration == duration)
                    .ElementAt(occurrence - 1);
                request.Completion.TrySetResult();
            }
        }

        private sealed record DelayRequest(TimeSpan Duration, TaskCompletionSource Completion);
    }
}
