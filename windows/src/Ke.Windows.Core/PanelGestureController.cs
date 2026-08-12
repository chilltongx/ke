namespace Ke.Windows.Core;

public readonly record struct PanelGestureUpdate(
    GestureDecision Decision,
    PhysicalPoint PanelTopLeft);

public readonly record struct PanelGestureRelease(
    GestureDecision Decision,
    PhysicalPoint PanelTopLeft)
{
    public bool ShouldSend => Decision == GestureDecision.Click;

    public bool ShouldPersist => Decision == GestureDecision.Drag;
}

public sealed class PanelGestureController
{
    private const double DefaultDpi = 96;

    private readonly PhysicalPoint _cursorDown;
    private readonly PhysicalPoint _grabOffset;
    private readonly double _windowDpi;
    private readonly GestureTracker _tracker;

    public PanelGestureController(
        PhysicalPoint cursorDown,
        PhysicalPoint panelTopLeft,
        double windowDpi,
        double dragThresholdDip)
    {
        _cursorDown = cursorDown;
        _grabOffset = new PhysicalPoint(
            cursorDown.X - panelTopLeft.X,
            cursorDown.Y - panelTopLeft.Y);
        _windowDpi = double.IsFinite(windowDpi) && windowDpi > 0 ? windowDpi : DefaultDpi;
        _tracker = new GestureTracker(new DipPoint(0, 0), dragThresholdDip);
    }

    public PanelGestureUpdate MoveTo(PhysicalPoint cursor)
    {
        var decision = _tracker.MoveTo(CursorDisplacementDip(cursor));
        return new PanelGestureUpdate(decision, PanelTopLeft(cursor));
    }

    public PanelGestureRelease ReleaseAt(PhysicalPoint cursor)
    {
        MoveTo(cursor);
        var decision = _tracker.Release();
        return new PanelGestureRelease(decision, PanelTopLeft(cursor));
    }

    private DipPoint CursorDisplacementDip(PhysicalPoint cursor)
    {
        var physicalToDip = DefaultDpi / _windowDpi;
        return new DipPoint(
            (cursor.X - _cursorDown.X) * physicalToDip,
            (cursor.Y - _cursorDown.Y) * physicalToDip);
    }

    private PhysicalPoint PanelTopLeft(PhysicalPoint cursor) =>
        new(cursor.X - _grabOffset.X, cursor.Y - _grabOffset.Y);
}
