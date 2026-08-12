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
        var attempt = sender.PrepareAttempt();

        var running = coordinator.TryStartAsync(
            result =>
            {
                reports.Add(result);
                reported.TrySetResult();
                return Task.CompletedTask;
            });
        await attempt.Entered;
        deadline.Expire();
        await reported.Task;

        var timeout = Assert.Single(reports);
        Assert.Equal(SendErrorCode.AutomationTimeout, timeout.Error);
        Assert.False(await coordinator.TryStartAsync(_ => Task.CompletedTask));

        attempt.Return(SendResult.Success());
        Assert.True(await running);
        Assert.Single(reports);
        Assert.Equal(ExpectedDeadline, deadline.RequestedDuration);

        var nextAttempt = sender.PrepareAttempt();
        var next = coordinator.TryStartAsync(_ => Task.CompletedTask);
        await nextAttempt.Entered;
        nextAttempt.Return(SendResult.Success());
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
        var attempt = sender.PrepareAttempt();

        var running = coordinator.TryStartAsync(
            result =>
            {
                reports.Add(result);
                Assert.True(ui.IsDispatching);
                return Task.CompletedTask;
            });
        await attempt.Entered;
        attempt.Return(SendResult.Failure(SendErrorCode.DraftPresent));

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
        var attempt = sender.PrepareAttempt();

        var first = coordinator.TryStartAsync(
            _ =>
            {
                reports++;
                return Task.CompletedTask;
            });
        await attempt.Entered;

        Assert.False(await coordinator.TryStartAsync(
            _ =>
            {
                reports++;
                return Task.CompletedTask;
            }));
        Assert.Equal(1, sender.Attempts);

        attempt.Return(SendResult.Success());
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
        var attempt = sender.PrepareAttempt();

        var running = coordinator.TryStartAsync(
            result =>
            {
                reports.Add(result);
                return Task.CompletedTask;
            });
        await attempt.Entered;
        attempt.Throw(new InvalidOperationException("boom"));

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
        var firstAttempt = sender.PrepareAttempt();

        var first = coordinator.TryStartAsync(
            _ =>
            {
                callbacks++;
                throw new InvalidOperationException("ui failed");
            });
        await firstAttempt.Entered;
        firstAttempt.Return(SendResult.Success());

        Assert.True(await first);
        Assert.Equal(1, callbacks);

        var secondAttempt = sender.PrepareAttempt();
        var second = coordinator.TryStartAsync(_ => Task.CompletedTask);
        await secondAttempt.Entered;
        secondAttempt.Return(SendResult.Success());
        Assert.True(await second);
    }

    [Fact]
    public async Task Dispose_cancels_worker_rejects_new_work_and_observes_unwind()
    {
        var sender = new ControlledSender();
        var deadline = new ManualDeadline();
        var reports = 0;
        var coordinator = Create(sender, deadline);
        var attempt = sender.PrepareAttempt();

        var running = coordinator.TryStartAsync(
            _ =>
            {
                reports++;
                return Task.CompletedTask;
            });
        await attempt.Entered;

        coordinator.Dispose();

        Assert.True(attempt.CancellationRequested);
        Assert.False(await coordinator.TryStartAsync(_ => Task.CompletedTask));
        attempt.Return(SendResult.Success());
        Assert.True(await running);
        Assert.Equal(0, reports);
    }

    [Fact]
    public async Task Repeated_attempts_use_distinct_entry_and_completion_handshakes()
    {
        const int repetitions = 100;
        var sender = new ControlledSender();
        var deadline = new ManualDeadline();
        using var coordinator = Create(sender, deadline);

        for (var index = 1; index <= repetitions; index++)
        {
            var attempt = sender.PrepareAttempt();
            var running = coordinator.TryStartAsync(_ => Task.CompletedTask);

            await attempt.Entered;
            Assert.Equal(index, attempt.Sequence);
            attempt.Return(SendResult.Success());

            Assert.True(await running);
        }

        Assert.Equal(repetitions, sender.Attempts);
    }

    [Fact]
    public async Task Deadline_winner_stays_timeout_when_worker_completes_before_continuation()
    {
        var sender = new ControlledSender();
        var deadline = new ManualDeadline();
        var race = new ManualCompletionRace();
        var reports = new List<SendResult>();
        using var coordinator = Create(sender, deadline, race: race);
        var attempt = sender.PrepareAttempt();

        var running = coordinator.TryStartAsync(
            result =>
            {
                reports.Add(result);
                return Task.CompletedTask;
            });
        await attempt.Entered;
        await race.Registered;

        deadline.Expire();
        await race.DeadlineCompleted;
        race.Decide(SendCompletion.Deadline);
        attempt.Return(SendResult.Success());
        await race.WorkerCompleted;
        race.Release();

        Assert.True(await running);
        Assert.Equal(SendErrorCode.AutomationTimeout, Assert.Single(reports).Error);
    }

    [Fact]
    public async Task Deadline_expiry_cancels_queued_worker_before_coordinator_continuation()
    {
        var sender = new CountingSender();
        var dispatcher = new PausedAutomationDispatcher();
        var deadline = new ManualDeadline();
        var race = new ManualCompletionRace();
        using var coordinator = new SendCoordinator(
            dispatcher,
            sender,
            deadline,
            new RecordingUiDispatcher(),
            race);

        var running = coordinator.TryStartAsync(_ => Task.CompletedTask);
        await dispatcher.Queued;
        await race.Registered;

        deadline.Expire();
        await race.DeadlineCompleted;

        Assert.True(dispatcher.CancellationRequested);
        dispatcher.Release();
        Assert.Equal(0, sender.Attempts);

        race.Decide(SendCompletion.Deadline);
        race.Release();
        Assert.True(await running);
    }

    private static SendCoordinator Create(
        ControlledSender sender,
        ManualDeadline deadline,
        RecordingUiDispatcher? ui = null,
        ISendCompletionRace? race = null) =>
        new(
            new ThreadPoolAutomationDispatcher(),
            sender,
            deadline,
            ui ?? new(),
            race ?? new TaskSendCompletionRace());

    private sealed class ControlledSender : IFocusedChatSender
    {
        private readonly object _gate = new();
        private readonly Queue<ControlledAttempt> _prepared = new();
        private int _attempts;
        private int _sequence;

        public int Attempts => Volatile.Read(ref _attempts);

        public ControlledAttempt PrepareAttempt()
        {
            lock (_gate)
            {
                var attempt = new ControlledAttempt(++_sequence);
                _prepared.Enqueue(attempt);
                return attempt;
            }
        }

        public SendResult TrySend(CancellationToken cancellationToken)
        {
            ControlledAttempt attempt;
            lock (_gate)
            {
                attempt = _prepared.Count > 0
                    ? _prepared.Dequeue()
                    : throw new InvalidOperationException(
                        "Each worker attempt must be prepared before dispatch.");
            }

            Interlocked.Increment(ref _attempts);
            return attempt.Run(cancellationToken);
        }

        public sealed class ControlledAttempt
        {
            private readonly TaskCompletionSource _entered =
                new(TaskCreationOptions.RunContinuationsAsynchronously);
            private readonly TaskCompletionSource<SendResult> _result =
                new(TaskCreationOptions.RunContinuationsAsynchronously);
            private CancellationToken _token;
            private int _hasEntered;

            public ControlledAttempt(int sequence)
            {
                Sequence = sequence;
            }

            public int Sequence { get; }

            public Task Entered => _entered.Task;

            public bool CancellationRequested => _token.IsCancellationRequested;

            public void Return(SendResult result)
            {
                EnsureEntered();
                _result.TrySetResult(result);
            }

            public void Throw(Exception exception)
            {
                EnsureEntered();
                _result.TrySetException(exception);
            }

            internal SendResult Run(CancellationToken cancellationToken)
            {
                _token = cancellationToken;
                Volatile.Write(ref _hasEntered, 1);
                _entered.TrySetResult();
                return _result.Task.GetAwaiter().GetResult();
            }

            private void EnsureEntered()
            {
                if (Volatile.Read(ref _hasEntered) == 0)
                {
                    throw new InvalidOperationException(
                        "An attempt cannot complete before its worker enters.");
                }
            }
        }
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

    private sealed class PausedAutomationDispatcher : IAutomationDispatcher
    {
        private readonly TaskCompletionSource _queued =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private Func<CancellationToken, SendResult>? _work;
        private TaskCompletionSource<SendResult>? _result;
        private CancellationToken _token;

        public Task Queued => _queued.Task;

        public bool CancellationRequested => _token.IsCancellationRequested;

        public Task<T> InvokeAsync<T>(
            Func<CancellationToken, T> work,
            CancellationToken cancellationToken)
        {
            Assert.Null(_work);
            _work = token => (SendResult)(object)work(token)!;
            _token = cancellationToken;
            _result = new TaskCompletionSource<SendResult>(
                TaskCreationOptions.RunContinuationsAsynchronously);
            _queued.TrySetResult();
            return (Task<T>)(object)_result.Task;
        }

        public void Release()
        {
            var result = _result ?? throw new InvalidOperationException("No work is queued.");
            if (_token.IsCancellationRequested)
            {
                result.TrySetCanceled(_token);
                return;
            }

            var work = _work ?? throw new InvalidOperationException("No work is queued.");
            result.TrySetResult(work(_token));
        }

        public void Dispose()
        {
        }
    }

    private sealed class CountingSender : IFocusedChatSender
    {
        private int _attempts;

        public int Attempts => Volatile.Read(ref _attempts);

        public SendResult TrySend(CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref _attempts);
            return SendResult.Success();
        }
    }

    private sealed class ManualDeadline : ISendDeadline
    {
        private readonly TaskCompletionSource _expired =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private Action? _onExpired;
        public TimeSpan RequestedDuration { get; private set; }

        public bool WasCancelled { get; private set; }

        public async Task WaitAsync(
            TimeSpan duration,
            Action onExpired,
            CancellationToken cancellationToken)
        {
            RequestedDuration = duration;
            _onExpired = onExpired;
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

        public void Expire()
        {
            var onExpired = _onExpired
                ?? throw new InvalidOperationException("Deadline is not registered.");
            onExpired();
            _expired.TrySetResult();
        }
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

    private sealed class ManualCompletionRace : ISendCompletionRace
    {
        private readonly TaskCompletionSource _registered =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource _released =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private Task<SendResult>? _worker;
        private Task? _deadline;
        private SendCompletion? _decision;

        public Task Registered => _registered.Task;

        public Task WorkerCompleted =>
            _worker ?? throw new InvalidOperationException("Race is not registered.");

        public Task DeadlineCompleted =>
            _deadline ?? throw new InvalidOperationException("Race is not registered.");

        public async Task<SendCompletion> WaitAsync(
            Task<SendResult> worker,
            Task deadline)
        {
            _worker = worker;
            _deadline = deadline;
            _registered.TrySetResult();
            await _released.Task;
            return _decision ?? throw new InvalidOperationException("Race has no decision.");
        }

        public void Decide(SendCompletion decision) => _decision = decision;

        public void Release() => _released.TrySetResult();
    }
}
