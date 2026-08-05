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
}
