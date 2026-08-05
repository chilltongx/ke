using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using Ke.Windows.Core;

namespace Ke.Windows.App;

public enum ButtonFeedbackVisual
{
    Idle,
    Pressed,
    Success,
    Failure
}

public interface IButtonFeedbackView
{
    void ApplyVisual(ButtonFeedbackVisual visual, double scale, bool animate);

    void SetToolTip(string? message);

    void PublishAccessibility(string message);
}

public interface IFeedbackDelay
{
    Task DelayAsync(TimeSpan duration, CancellationToken cancellationToken);
}

public sealed class SystemFeedbackDelay : IFeedbackDelay
{
    public Task DelayAsync(TimeSpan duration, CancellationToken cancellationToken) =>
        Task.Delay(duration, cancellationToken);
}

public sealed class ButtonFeedbackController : IDisposable
{
    public static readonly TimeSpan SuccessDuration = TimeSpan.FromMilliseconds(650);
    public static readonly TimeSpan FailureDuration = TimeSpan.FromMilliseconds(900);
    public static readonly TimeSpan ToolTipDuration = TimeSpan.FromSeconds(2.5);

    private static readonly IReadOnlyDictionary<SendErrorCode, string> Messages =
        new Dictionary<SendErrorCode, string>
        {
            [SendErrorCode.UnsupportedApplication] = "当前只支持 Codex 和 VS Code",
            [SendErrorCode.NotChatComposer] = "请先点击 Codex 或 VS Code 的聊天输入框",
            [SendErrorCode.DraftPresent] = "输入框已有内容，未发送",
            [SendErrorCode.TargetChanged] = "焦点已变化，未发送",
            [SendErrorCode.AutomationUnavailable] = "无法安全读取当前输入框",
            [SendErrorCode.AutomationTimeout] = "读取输入框超时，没有按回车",
            [SendErrorCode.ModifierKeyDown] = "请松开 Ctrl、Alt、Shift 或 Windows 键后重试",
            [SendErrorCode.ElevatedTarget] = "目标可能以管理员身份运行，未发送",
            [SendErrorCode.WriteUnconfirmed] = "写入未确认，没有按回车",
            [SendErrorCode.ReturnDeliveryFailed] = "无法发送回车，不会重试"
        };

    private readonly IButtonFeedbackView _view;
    private readonly IFeedbackDelay _delay;
    private readonly bool _animationsEnabled;
    private readonly CancellationTokenSource _shutdown = new();
    private long _generation;
    private int _disposed;

    public ButtonFeedbackController(
        IButtonFeedbackView view,
        IFeedbackDelay delay,
        bool animationsEnabled)
    {
        _view = view ?? throw new ArgumentNullException(nameof(view));
        _delay = delay ?? throw new ArgumentNullException(nameof(delay));
        _animationsEnabled = animationsEnabled;
    }

    public static string MessageFor(SendErrorCode error) => Messages[error];

    public void ShowPressed()
    {
        if (Volatile.Read(ref _disposed) != 0)
        {
            return;
        }

        Interlocked.Increment(ref _generation);
        _view.SetToolTip(null);
        _view.ApplyVisual(ButtonFeedbackVisual.Pressed, 0.96, animate: false);
    }

    public void ShowIdle()
    {
        if (Volatile.Read(ref _disposed) != 0)
        {
            return;
        }

        Interlocked.Increment(ref _generation);
        _view.SetToolTip(null);
        _view.ApplyVisual(ButtonFeedbackVisual.Idle, 1, animate: false);
    }

    public Task ShowResultAsync(SendResult result)
    {
        ArgumentNullException.ThrowIfNull(result);
        if (Volatile.Read(ref _disposed) != 0)
        {
            return Task.CompletedTask;
        }

        var generation = Interlocked.Increment(ref _generation);
        var message = result.IsSuccess
            ? "已发送可"
            : MessageFor(result.Error ?? SendErrorCode.AutomationUnavailable);
        var visual = result.IsSuccess
            ? ButtonFeedbackVisual.Success
            : ButtonFeedbackVisual.Failure;
        var visualDuration = result.IsSuccess ? SuccessDuration : FailureDuration;

        _view.ApplyVisual(visual, 1, _animationsEnabled);
        _view.SetToolTip(message);
        _view.PublishAccessibility(message);

        return CompleteSequenceAsync(generation, visualDuration, _shutdown.Token);
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
        {
            return;
        }

        Interlocked.Increment(ref _generation);
        _shutdown.Cancel();
    }

    private async Task CompleteSequenceAsync(
        long generation,
        TimeSpan visualDuration,
        CancellationToken cancellationToken)
    {
        try
        {
            var visualDelay = _delay.DelayAsync(visualDuration, cancellationToken);
            var tooltipDelay = _delay.DelayAsync(ToolTipDuration, cancellationToken);

            await visualDelay.ConfigureAwait(true);
            if (IsCurrent(generation))
            {
                _view.ApplyVisual(ButtonFeedbackVisual.Idle, 1, _animationsEnabled);
            }

            await tooltipDelay.ConfigureAwait(true);
            if (IsCurrent(generation))
            {
                _view.SetToolTip(null);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
    }

    private bool IsCurrent(long generation) =>
        Volatile.Read(ref _disposed) == 0 &&
        Interlocked.Read(ref _generation) == generation;
}

public sealed class WpfButtonFeedbackView : IButtonFeedbackView
{
    private static readonly Color Charcoal = Color.FromRgb(0x1E, 0x1E, 0x1F);
    private static readonly Color Mint = Color.FromRgb(0x55, 0xD6, 0xBE);
    private static readonly Color Ivory = Color.FromRgb(0xFF, 0xF8, 0xE7);
    private static readonly Color FailureRed = Color.FromRgb(0xFF, 0x5A, 0x5F);
    private static readonly Duration TransitionDuration =
        new(TimeSpan.FromMilliseconds(100));

    private readonly Border _disc;
    private readonly TextBlock _glyph;
    private readonly FrameworkElement _toolTipOwner;
    private readonly Action<string> _publishAccessibility;
    private readonly SolidColorBrush _background = new(Charcoal);
    private readonly SolidColorBrush _border = new(Mint);
    private readonly SolidColorBrush _foreground = new(Ivory);
    private readonly ScaleTransform _scale = new(1, 1);

    public WpfButtonFeedbackView(
        Border disc,
        TextBlock glyph,
        FrameworkElement toolTipOwner,
        Action<string> publishAccessibility)
    {
        _disc = disc ?? throw new ArgumentNullException(nameof(disc));
        _glyph = glyph ?? throw new ArgumentNullException(nameof(glyph));
        _toolTipOwner = toolTipOwner ??
            throw new ArgumentNullException(nameof(toolTipOwner));
        _publishAccessibility = publishAccessibility ??
            throw new ArgumentNullException(nameof(publishAccessibility));

        _disc.Background = _background;
        _disc.BorderBrush = _border;
        _glyph.Foreground = _foreground;
        _disc.RenderTransformOrigin = new Point(0.5, 0.5);
        _disc.RenderTransform = _scale;
    }

    public void ApplyVisual(ButtonFeedbackVisual visual, double scale, bool animate)
    {
        var colors = visual switch
        {
            ButtonFeedbackVisual.Success => (Mint, Ivory, Charcoal),
            ButtonFeedbackVisual.Failure => (Charcoal, FailureRed, Ivory),
            _ => (Charcoal, Mint, Ivory)
        };

        ApplyColor(_background, colors.Item1, animate);
        ApplyColor(_border, colors.Item2, animate);
        ApplyColor(_foreground, colors.Item3, animate);
        ApplyScale(scale, animate);
    }

    public void SetToolTip(string? message) => _toolTipOwner.ToolTip = message;

    public void PublishAccessibility(string message) => _publishAccessibility(message);

    private static void ApplyColor(SolidColorBrush brush, Color target, bool animate)
    {
        brush.BeginAnimation(SolidColorBrush.ColorProperty, null);
        if (!animate)
        {
            brush.Color = target;
            return;
        }

        var current = brush.Color;
        brush.Color = target;
        brush.BeginAnimation(
            SolidColorBrush.ColorProperty,
            new ColorAnimation(current, target, TransitionDuration));
    }

    private void ApplyScale(double target, bool animate)
    {
        _scale.BeginAnimation(ScaleTransform.ScaleXProperty, null);
        _scale.BeginAnimation(ScaleTransform.ScaleYProperty, null);
        if (!animate)
        {
            _scale.ScaleX = target;
            _scale.ScaleY = target;
            return;
        }

        var current = _scale.ScaleX;
        _scale.ScaleX = target;
        _scale.ScaleY = target;
        _scale.BeginAnimation(
            ScaleTransform.ScaleXProperty,
            new DoubleAnimation(current, target, TransitionDuration));
        _scale.BeginAnimation(
            ScaleTransform.ScaleYProperty,
            new DoubleAnimation(current, target, TransitionDuration));
    }
}
