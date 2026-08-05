namespace Ke.Windows.Core;

public readonly record struct DipPoint(double X, double Y);

public enum GestureDecision
{
    Pending,
    Click,
    Drag
}

public sealed class GestureTracker(DipPoint origin, double dragThreshold)
{
    private bool _dragging;

    public GestureDecision MoveTo(DipPoint point)
    {
        var dx = point.X - origin.X;
        var dy = point.Y - origin.Y;
        _dragging |= Math.Sqrt((dx * dx) + (dy * dy)) > dragThreshold;
        return _dragging ? GestureDecision.Drag : GestureDecision.Pending;
    }

    public GestureDecision Release() => _dragging ? GestureDecision.Drag : GestureDecision.Click;
}
