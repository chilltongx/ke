using System.Collections.Concurrent;

namespace Ke.Windows.Automation;

public interface IAutomationDispatcher : IDisposable
{
    Task<T> InvokeAsync<T>(
        Func<CancellationToken, T> work,
        CancellationToken cancellationToken);
}

public sealed class AutomationDispatcher : IAutomationDispatcher
{
    private static readonly TimeSpan JoinTimeout = TimeSpan.FromSeconds(5);

    private readonly BlockingCollection<IWorkItem> _queue = [];
    private readonly object _disposeGate = new();
    private readonly Thread _thread;
    private int _disposed;
    private InvalidOperationException? _disposeFailure;

    public AutomationDispatcher()
    {
        _thread = new Thread(Run)
        {
            IsBackground = true,
            Name = "Ke.Windows.Automation"
        };
        _thread.SetApartmentState(ApartmentState.MTA);
        _thread.Start();
    }

    public Task<T> InvokeAsync<T>(
        Func<CancellationToken, T> work,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(work);
        if (Volatile.Read(ref _disposed) != 0)
        {
            throw new InvalidOperationException("The automation dispatcher is closed.");
        }

        var item = new WorkItem<T>(work, cancellationToken);
        try
        {
            _queue.Add(item, CancellationToken.None);
        }
        catch (InvalidOperationException exception)
        {
            throw new InvalidOperationException(
                "The automation dispatcher is closed.",
                exception);
        }

        return item.Task;
    }

    public void Dispose()
    {
        lock (_disposeGate)
        {
            if (Volatile.Read(ref _disposed) != 0)
            {
                if (_disposeFailure is not null)
                {
                    throw new InvalidOperationException(
                        "The automation dispatcher failed to stop.",
                        _disposeFailure);
                }

                return;
            }

            Volatile.Write(ref _disposed, 1);
            _queue.CompleteAdding();
            if (!_thread.Join(JoinTimeout))
            {
                _disposeFailure = new InvalidOperationException(
                    "The automation dispatcher did not stop within five seconds.");
                throw _disposeFailure;
            }
        }
    }

    private void Run()
    {
        foreach (var item in _queue.GetConsumingEnumerable())
        {
            item.Execute();
        }
    }

    private interface IWorkItem
    {
        void Execute();
    }

    private sealed class WorkItem<T>(
        Func<CancellationToken, T> work,
        CancellationToken cancellationToken) : IWorkItem
    {
        private readonly TaskCompletionSource<T> _completion =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public Task<T> Task => _completion.Task;

        public void Execute()
        {
            if (cancellationToken.IsCancellationRequested)
            {
                _completion.TrySetCanceled(cancellationToken);
                return;
            }

            try
            {
                _completion.TrySetResult(work(cancellationToken));
            }
            catch (OperationCanceledException exception)
            {
                _completion.TrySetCanceled(exception.CancellationToken);
            }
            catch (Exception exception)
            {
                _completion.TrySetException(exception);
            }
        }
    }
}
