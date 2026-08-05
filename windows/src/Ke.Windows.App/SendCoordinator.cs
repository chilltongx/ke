using System.Windows.Threading;
using Ke.Windows.Automation;
using Ke.Windows.Core;

namespace Ke.Windows.App;

public interface ISendDeadline
{
    Task WaitAsync(
        TimeSpan duration,
        Action onExpired,
        CancellationToken cancellationToken);
}

public sealed class SystemSendDeadline : ISendDeadline
{
    public async Task WaitAsync(
        TimeSpan duration,
        Action onExpired,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(onExpired);

        var completion = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var completed = 0;
        using var timer = new System.Threading.Timer(
            _ =>
            {
                if (Interlocked.CompareExchange(ref completed, 1, 0) != 0)
                {
                    return;
                }

                try
                {
                    onExpired();
                    completion.TrySetResult();
                }
                catch (Exception exception)
                {
                    completion.TrySetException(exception);
                }
            },
            state: null,
            Timeout.InfiniteTimeSpan,
            Timeout.InfiniteTimeSpan);
        using var registration = cancellationToken.UnsafeRegister(
            _ =>
            {
                if (Interlocked.CompareExchange(ref completed, 1, 0) == 0)
                {
                    completion.TrySetCanceled(cancellationToken);
                }
            },
            state: null);

        if (Volatile.Read(ref completed) == 0)
        {
            timer.Change(duration, Timeout.InfiniteTimeSpan);
        }

        await completion.Task.ConfigureAwait(false);
    }
}

public interface IUiCallbackDispatcher
{
    Task InvokeAsync(Func<Task> callback);
}

public sealed class WpfUiCallbackDispatcher(Dispatcher dispatcher) : IUiCallbackDispatcher
{
    public Task InvokeAsync(Func<Task> callback)
    {
        ArgumentNullException.ThrowIfNull(callback);
        return dispatcher.InvokeAsync(callback).Task.Unwrap();
    }
}

public enum SendCompletion
{
    Worker,
    Deadline
}

public interface ISendCompletionRace
{
    Task<SendCompletion> WaitAsync(Task<SendResult> worker, Task deadline);
}

public sealed class TaskSendCompletionRace : ISendCompletionRace
{
    public async Task<SendCompletion> WaitAsync(
        Task<SendResult> worker,
        Task deadline)
    {
        var winner = await Task.WhenAny(worker, deadline).ConfigureAwait(false);
        return winner == worker ? SendCompletion.Worker : SendCompletion.Deadline;
    }
}

public sealed class SendCoordinator : IDisposable
{
    public static readonly TimeSpan SendTimeout = TimeSpan.FromSeconds(2.5);

    private readonly IAutomationDispatcher _automationDispatcher;
    private readonly IFocusedChatSender _sender;
    private readonly ISendDeadline _deadline;
    private readonly IUiCallbackDispatcher _uiDispatcher;
    private readonly ISendCompletionRace _completionRace;
    private readonly CancellationTokenSource _shutdown = new();
    private int _inFlight;
    private int _disposed;

    public SendCoordinator(
        IAutomationDispatcher automationDispatcher,
        IFocusedChatSender sender,
        ISendDeadline deadline,
        IUiCallbackDispatcher uiDispatcher)
        : this(
            automationDispatcher,
            sender,
            deadline,
            uiDispatcher,
            new TaskSendCompletionRace())
    {
    }

    public SendCoordinator(
        IAutomationDispatcher automationDispatcher,
        IFocusedChatSender sender,
        ISendDeadline deadline,
        IUiCallbackDispatcher uiDispatcher,
        ISendCompletionRace completionRace)
    {
        _automationDispatcher = automationDispatcher ??
            throw new ArgumentNullException(nameof(automationDispatcher));
        _sender = sender ?? throw new ArgumentNullException(nameof(sender));
        _deadline = deadline ?? throw new ArgumentNullException(nameof(deadline));
        _uiDispatcher = uiDispatcher ?? throw new ArgumentNullException(nameof(uiDispatcher));
        _completionRace = completionRace ??
            throw new ArgumentNullException(nameof(completionRace));
    }

    public Task<bool> TryStartAsync(Func<SendResult, Task> report)
    {
        ArgumentNullException.ThrowIfNull(report);
        if (Volatile.Read(ref _disposed) != 0 ||
            Interlocked.CompareExchange(ref _inFlight, 1, 0) != 0)
        {
            return Task.FromResult(false);
        }

        if (Volatile.Read(ref _disposed) != 0)
        {
            Interlocked.Exchange(ref _inFlight, 0);
            return Task.FromResult(false);
        }

        return RunAsync(report);
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
        {
            return;
        }

        _shutdown.Cancel();
    }

    private async Task<bool> RunAsync(Func<SendResult, Task> report)
    {
        using var workerCancellation =
            CancellationTokenSource.CreateLinkedTokenSource(_shutdown.Token);
        using var deadlineCancellation =
            CancellationTokenSource.CreateLinkedTokenSource(_shutdown.Token);

        Task<SendResult> worker = StartWorker(workerCancellation.Token);
        Task deadline = StartDeadline(
            workerCancellation.Cancel,
            deadlineCancellation.Token);
        try
        {
            var completed = await _completionRace
                .WaitAsync(worker, deadline)
                .ConfigureAwait(false);
            if (completed == SendCompletion.Worker)
            {
                deadlineCancellation.Cancel();
                var result = await ReadWorkerResultAsync(worker).ConfigureAwait(false);
                if (!_shutdown.IsCancellationRequested)
                {
                    await ReportOnceAsync(report, result).ConfigureAwait(false);
                }
            }
            else
            {
                workerCancellation.Cancel();
                if (!_shutdown.IsCancellationRequested)
                {
                    await ReportOnceAsync(
                        report,
                        SendResult.Failure(SendErrorCode.AutomationTimeout))
                        .ConfigureAwait(false);
                }

                _ = await ReadWorkerResultAsync(worker).ConfigureAwait(false);
            }

            return true;
        }
        finally
        {
            deadlineCancellation.Cancel();
            await ObserveDeadlineAsync(deadline).ConfigureAwait(false);
            Interlocked.Exchange(ref _inFlight, 0);
        }
    }

    private Task<SendResult> StartWorker(CancellationToken cancellationToken)
    {
        try
        {
            return _automationDispatcher.InvokeAsync(
                _sender.TrySend,
                cancellationToken);
        }
        catch (Exception exception)
        {
            return Task.FromException<SendResult>(exception);
        }
    }

    private Task StartDeadline(
        Action onExpired,
        CancellationToken cancellationToken)
    {
        try
        {
            return _deadline.WaitAsync(
                SendTimeout,
                onExpired,
                cancellationToken);
        }
        catch (Exception exception)
        {
            return Task.FromException(exception);
        }
    }

    private static async Task<SendResult> ReadWorkerResultAsync(Task<SendResult> worker)
    {
        try
        {
            return await worker.ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return SendResult.Failure(SendErrorCode.AutomationTimeout);
        }
        catch (Exception)
        {
            return SendResult.Failure(SendErrorCode.AutomationUnavailable);
        }
    }

    private async Task ReportOnceAsync(
        Func<SendResult, Task> report,
        SendResult result)
    {
        try
        {
            await _uiDispatcher.InvokeAsync(() => report(result)).ConfigureAwait(false);
        }
        catch (Exception)
        {
            // Feedback must never start a second send-result sequence.
        }
    }

    private static async Task ObserveDeadlineAsync(Task deadline)
    {
        try
        {
            await deadline.ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception)
        {
        }
    }
}
