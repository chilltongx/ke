using Ke.Windows.App;
using Ke.Windows.Automation;
using Ke.Windows.Core;
using Xunit;

namespace Ke.Windows.Automation.Tests;

public sealed class SendCoordinatorTests
{
    private static readonly TimeSpan ExpectedDeadline = TimeSpan.FromSeconds(2.5);

    [Fact]
    public async Task Timeout_reports_once_but_holds_in_flight_until_worker_returns()
    {
        var sender = new ControlledSender();
        var deadline = new ManualDeadline();
        var reports = new List<SendResult>();
        var reported = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        using var coordinator = Create(sender, deadline);

        var running = coordinator.TryStartAsync(
            result =>
            {
                reports.Add(result);
                reported.TrySetResult();
                return Task.CompletedTask;
            });
        await sender.Entered;
        deadline.Expire();
        await reported.Task;

        var timeout = Assert.Single(reports);
        Assert.Equal(SendErrorCode.AutomationTimeout, timeout.Error);
        Assert.False(await coordinator.TryStartAsync(_ => Task.CompletedTask));

        sender.Return(SendResult.Success());
        Assert.True(await running);
        Assert.Single(reports);
        Assert.Equal(ExpectedDeadline, deadline.RequestedDuration);

        var next = coordinator.TryStartAsync(_ => Task.CompletedTask);
        sender.Return(SendResult.Success());
        Assert.True(await next);
    }

    [Fact]
    public async Task Worker_result_wins_and_is_reported_once_on_ui_dispatcher()
    {
        var sender = new ControlledSender();
        var deadline = new ManualDeadline();
        var ui = new RecordingUiDispatcher();
        var reports = new List<SendResult>();
        using var coordinator = Create(sender, deadline, ui);

        var running = coordinator.TryStartAsync(
            result =>
            {
                reports.Add(result);
                Assert.True(ui.IsDispatching);
                return Task.CompletedTask;
            });
        await sender.Entered;
        sender.Return(SendResult.Failure(SendErrorCode.DraftPresent));

        Assert.True(await running);
        Assert.Equal(SendErrorCode.DraftPresent, Assert.Single(reports).Error);
        Assert.Equal(1, ui.InvocationCount);
        Assert.True(deadline.WasCancelled);
    }

    [Fact]
    public async Task Concurrent_attempt_is_rejected_without_starting_or_reporting()
    {
        var sender = new ControlledSender();
        var deadline = new ManualDeadline();
        var reports = 0;
        using var coordinator = Create(sender, deadline);

        var first = coordinator.TryStartAsync(
            _ =>
            {
                reports++;
                return Task.CompletedTask;
            });
        await sender.Entered;

        Assert.False(await coordinator.TryStartAsync(
            _ =>
            {
                reports++;
                return Task.CompletedTask;
            }));
        Assert.Equal(1, sender.Attempts);

        sender.Return(SendResult.Success());
        Assert.True(await first);
        Assert.Equal(1, reports);
    }

    [Fact]
    public async Task Sender_exception_maps_to_automation_unavailable_once()
    {
        var sender = new ControlledSender();
        var deadline = new ManualDeadline();
        var reports = new List<SendResult>();
        using var coordinator = Create(sender, deadline);

        var running = coordinator.TryStartAsync(
            result =>
            {
                reports.Add(result);
                return Task.CompletedTask;
            });
        await sender.Entered;
        sender.Throw(new InvalidOperationException("boom"));

        Assert.True(await running);
        Assert.Equal(SendErrorCode.AutomationUnavailable, Assert.Single(reports).Error);
    }

    [Fact]
    public async Task Callback_exception_does_not_report_twice_and_releases_in_flight()
    {
        var sender = new ControlledSender();
        var deadline = new ManualDeadline();
        var callbacks = 0;
        using var coordinator = Create(sender, deadline);

        var first = coordinator.TryStartAsync(
            _ =>
            {
                callbacks++;
                throw new InvalidOperationException("ui failed");
            });
        await sender.Entered;
        sender.Return(SendResult.Success());

        Assert.True(await first);
        Assert.Equal(1, callbacks);

        var second = coordinator.TryStartAsync(_ => Task.CompletedTask);
        sender.Return(SendResult.Success());
        Assert.True(await second);
    }

    [Fact]
    public async Task Dispose_cancels_worker_rejects_new_work_and_observes_unwind()
    {
        var sender = new ControlledSender();
        var deadline = new ManualDeadline();
        var reports = 0;
        var coordinator = Create(sender, deadline);

        var running = coordinator.TryStartAsync(
            _ =>
            {
                reports++;
                return Task.CompletedTask;
            });
        await sender.Entered;

        coordinator.Dispose();

        Assert.True(sender.CancellationRequested);
        Assert.False(await coordinator.TryStartAsync(_ => Task.CompletedTask));
        sender.Return(SendResult.Success());
        Assert.True(await running);
        Assert.Equal(0, reports);
    }

    private static SendCoordinator Create(
        ControlledSender sender,
        ManualDeadline deadline,
        RecordingUiDispatcher? ui = null) =>
        new(new ThreadPoolAutomationDispatcher(), sender, deadline, ui ?? new());

    private sealed class ControlledSender : IFocusedChatSender
    {
        private readonly object _gate = new();
        private TaskCompletionSource<SendResult> _result = NewCompletion();
        private readonly TaskCompletionSource _entered =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private CancellationToken _token;

        public int Attempts { get; private set; }

        public Task Entered => _entered.Task;

        public bool CancellationRequested => _token.IsCancellationRequested;

        public SendResult TrySend(CancellationToken cancellationToken)
        {
            Task<SendResult> task;
            lock (_gate)
            {
                Attempts++;
                _token = cancellationToken;
                task = _result.Task;
                _entered.TrySetResult();
            }

            return task.GetAwaiter().GetResult();
        }

        public void Return(SendResult result)
        {
            lock (_gate)
            {
                _result.TrySetResult(result);
                _result = NewCompletion();
            }
        }

        public void Throw(Exception exception)
        {
            lock (_gate)
            {
                _result.TrySetException(exception);
                _result = NewCompletion();
            }
        }

        private static TaskCompletionSource<SendResult> NewCompletion() =>
            new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    private sealed class ThreadPoolAutomationDispatcher : IAutomationDispatcher
    {
        public Task<T> InvokeAsync<T>(
            Func<CancellationToken, T> work,
            CancellationToken cancellationToken) =>
            Task.Run(() => work(cancellationToken), CancellationToken.None);

        public void Dispose()
        {
        }
    }

    private sealed class ManualDeadline : ISendDeadline
    {
        private readonly TaskCompletionSource _expired =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TimeSpan RequestedDuration { get; private set; }

        public bool WasCancelled { get; private set; }

        public async Task WaitAsync(TimeSpan duration, CancellationToken cancellationToken)
        {
            RequestedDuration = duration;
            try
            {
                await _expired.Task.WaitAsync(cancellationToken);
            }
            catch (OperationCanceledException)
            {
                WasCancelled = true;
                throw;
            }
        }

        public void Expire() => _expired.TrySetResult();
    }

    private sealed class RecordingUiDispatcher : IUiCallbackDispatcher
    {
        private readonly AsyncLocal<bool> _dispatching = new();

        public int InvocationCount { get; private set; }

        public bool IsDispatching => _dispatching.Value;

        public async Task InvokeAsync(Func<Task> callback)
        {
            InvocationCount++;
            _dispatching.Value = true;
            try
            {
                await callback();
            }
            finally
            {
                _dispatching.Value = false;
            }
        }
    }
}
