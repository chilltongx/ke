using Ke.Windows.Core;
using Xunit;

namespace Ke.Windows.Core.Tests;

public sealed class PanelGestureControllerTests
{
    [Fact]
    public void Release_beyond_threshold_without_move_event_is_drag_and_never_send()
    {
        var gesture = new PanelGestureController(
            cursorDown: new PhysicalPoint(100, 100),
            panelTopLeft: new PhysicalPoint(80, 75),
            windowDpi: 96,
            dragThresholdDip: 6);

        var released = gesture.ReleaseAt(new PhysicalPoint(107, 100));

        Assert.Equal(GestureDecision.Drag, released.Decision);
        Assert.False(released.ShouldSend);
        Assert.True(released.ShouldPersist);
        Assert.Equal(new PhysicalPoint(87, 75), released.PanelTopLeft);
    }

    [Fact]
    public void Release_at_exact_threshold_without_move_event_remains_click()
    {
        var gesture = new PanelGestureController(
            cursorDown: new PhysicalPoint(100, 100),
            panelTopLeft: new PhysicalPoint(80, 75),
            windowDpi: 144,
            dragThresholdDip: 6);

        var released = gesture.ReleaseAt(new PhysicalPoint(109, 100));

        Assert.Equal(GestureDecision.Click, released.Decision);
        Assert.True(released.ShouldSend);
        Assert.False(released.ShouldPersist);
    }

    [Fact]
    public void Drag_update_preserves_physical_cursor_to_window_offset()
    {
        var gesture = new PanelGestureController(
            cursorDown: new PhysicalPoint(2050, 200),
            panelTopLeft: new PhysicalPoint(2010, 170),
            windowDpi: 144,
            dragThresholdDip: 6);

        var update = gesture.MoveTo(new PhysicalPoint(2070, 230));

        Assert.Equal(GestureDecision.Drag, update.Decision);
        Assert.Equal(new PhysicalPoint(2030, 200), update.PanelTopLeft);
    }
}
