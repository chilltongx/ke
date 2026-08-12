using Ke.Windows.Core;
using Xunit;

namespace Ke.Windows.Core.Tests;

public sealed class GestureDecisionTests
{
    [Fact]
    public void Drag_latches_after_six_dip()
    {
        var tracker = new GestureTracker(new DipPoint(10, 10), 6);
        Assert.Equal(GestureDecision.Pending, tracker.MoveTo(new DipPoint(15.9, 10)));
        Assert.Equal(GestureDecision.Drag, tracker.MoveTo(new DipPoint(16.1, 10)));
        Assert.Equal(GestureDecision.Drag, tracker.MoveTo(new DipPoint(10, 10)));
        Assert.Equal(GestureDecision.Drag, tracker.Release());
    }

    [Fact]
    public void Stationary_release_is_click()
    {
        var tracker = new GestureTracker(new DipPoint(0, 0), 6);
        Assert.Equal(GestureDecision.Click, tracker.Release());
    }

    [Fact]
    public void Exactly_six_dip_remains_pending_and_releases_as_click()
    {
        var tracker = new GestureTracker(new DipPoint(0, 0), 6);
        Assert.Equal(GestureDecision.Pending, tracker.MoveTo(new DipPoint(6, 0)));
        Assert.Equal(GestureDecision.Click, tracker.Release());
    }
}
