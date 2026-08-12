using Ke.Windows.Automation;
using Xunit;

namespace Ke.Windows.Automation.Tests;

public sealed class AutomationDispatcherTests
{
    [Fact]
    public async Task Dispatcher_runs_serially_on_one_MTA_thread()
    {
        using var dispatcher = new AutomationDispatcher();

        var first = await dispatcher.InvokeAsync(
            _ => (Environment.CurrentManagedThreadId, Thread.CurrentThread.GetApartmentState()),
            CancellationToken.None);
        var second = await dispatcher.InvokeAsync(
            _ => (Environment.CurrentManagedThreadId, Thread.CurrentThread.GetApartmentState()),
            CancellationToken.None);

        Assert.Equal(first.Item1, second.Item1);
        Assert.Equal(ApartmentState.MTA, first.Item2);
    }

    [Fact]
    public async Task Work_is_cancelled_before_it_starts()
    {
        using var dispatcher = new AutomationDispatcher();
        using var entered = new ManualResetEventSlim();
        using var release = new ManualResetEventSlim();
        using var cancellation = new CancellationTokenSource();

        var blocker = dispatcher.InvokeAsync(
            _ =>
            {
                entered.Set();
                release.Wait();
                return 1;
            },
            CancellationToken.None);
        Assert.True(entered.Wait(TimeSpan.FromSeconds(2)));

        var cancelled = dispatcher.InvokeAsync(_ => 2, cancellation.Token);
        cancellation.Cancel();
        release.Set();

        Assert.Equal(1, await blocker);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => cancelled);
    }

    [Fact]
    public void Work_is_rejected_after_disposal()
    {
        var dispatcher = new AutomationDispatcher();
        dispatcher.Dispose();

        Assert.Throws<InvalidOperationException>(
            () =>
            {
                _ = dispatcher.InvokeAsync(_ => 1, CancellationToken.None);
            });
    }

    [Fact]
    public async Task Concurrent_dispose_waits_for_queued_work_and_rejects_new_work()
    {
        var dispatcher = new AutomationDispatcher();
        using var entered = new ManualResetEventSlim();
        using var release = new ManualResetEventSlim();
        using var secondDisposeStarted = new ManualResetEventSlim();

        var blocker = dispatcher.InvokeAsync(
            _ =>
            {
                entered.Set();
                release.Wait();
                return 1;
            },
            CancellationToken.None);
        Assert.True(entered.Wait(TimeSpan.FromSeconds(2)));
        var queued = dispatcher.InvokeAsync(_ => 2, CancellationToken.None);

        var firstDispose = Task.Run(dispatcher.Dispose);
        Assert.True(SpinWait.SpinUntil(
            () => IsWorkRejected(dispatcher),
            TimeSpan.FromSeconds(2)));
        var secondDispose = Task.Run(
            () =>
            {
                secondDisposeStarted.Set();
                dispatcher.Dispose();
            });
        Assert.True(secondDisposeStarted.Wait(TimeSpan.FromSeconds(2)));

        Assert.False(firstDispose.IsCompleted);
        Assert.False(secondDispose.IsCompleted);

        release.Set();
        Assert.Equal(1, await blocker);
        Assert.Equal(2, await queued);
        await Task.WhenAll(firstDispose, secondDispose);
        Assert.True(IsWorkRejected(dispatcher));
    }

    [Fact]
    public async Task Completion_continuations_do_not_run_inline_on_dispatcher_thread()
    {
        using var dispatcher = new AutomationDispatcher();
        using var entered = new ManualResetEventSlim();
        using var release = new ManualResetEventSlim();

        var work = dispatcher.InvokeAsync(
            _ =>
            {
                entered.Set();
                release.Wait();
                return Environment.CurrentManagedThreadId;
            },
            CancellationToken.None);
        Assert.True(entered.Wait(TimeSpan.FromSeconds(2)));
        var continuation = work.ContinueWith(
            _ => Environment.CurrentManagedThreadId,
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);

        release.Set();

        Assert.NotEqual(await work, await continuation);
    }

    private static bool IsWorkRejected(AutomationDispatcher dispatcher)
    {
        try
        {
            _ = dispatcher.InvokeAsync(_ => 3, CancellationToken.None);
            return false;
        }
        catch (InvalidOperationException)
        {
            return true;
        }
    }
}
