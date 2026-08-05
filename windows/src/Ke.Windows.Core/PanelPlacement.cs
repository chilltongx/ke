namespace Ke.Windows.Core;

public readonly record struct SavedPanelPosition(
    string DeviceName,
    double Dpi,
    double RelativeX,
    double RelativeY);

public readonly record struct WorkArea(
    double X,
    double Y,
    double Width,
    double Height,
    double Dpi);

public static class PanelPlacement
{
    public const double DefaultInset = 24;

    public static SavedPanelPosition Save(
        string deviceName,
        double dpi,
        DipPoint position,
        WorkArea workArea)
    {
        var relativeX = RelativeCoordinate(position.X, workArea.X, workArea.Width);
        var relativeY = RelativeCoordinate(position.Y, workArea.Y, workArea.Height);

        return new SavedPanelPosition(deviceName, dpi, relativeX, relativeY);
    }

    public static DipPoint Restore(
        SavedPanelPosition? saved,
        WorkArea workArea,
        double panelWidth,
        double panelHeight)
    {
        var originX = FiniteOrZero(workArea.X);
        var originY = FiniteOrZero(workArea.Y);
        var width = PositiveFiniteOrZero(workArea.Width);
        var height = PositiveFiniteOrZero(workArea.Height);
        var safePanelWidth = PositiveFiniteOrZero(panelWidth);
        var safePanelHeight = PositiveFiniteOrZero(panelHeight);

        if (width <= 0 || height <= 0)
        {
            return new DipPoint(originX, originY);
        }

        var usableWidth = Math.Max(0, width - safePanelWidth);
        var usableHeight = Math.Max(0, height - safePanelHeight);

        if (HasValidCoordinates(saved))
        {
            var value = saved!.Value;
            return new DipPoint(
                originX + Math.Clamp(value.RelativeX * width, 0, usableWidth),
                originY + Math.Clamp(value.RelativeY * height, 0, usableHeight));
        }

        return new DipPoint(
            originX + Math.Max(0, usableWidth - DefaultInset),
            originY + Math.Max(0, usableHeight - DefaultInset));
    }

    private static bool HasValidCoordinates(SavedPanelPosition? saved)
    {
        return saved is { } value
            && double.IsFinite(value.Dpi)
            && value.Dpi > 0
            && double.IsFinite(value.RelativeX)
            && double.IsFinite(value.RelativeY);
    }

    private static double RelativeCoordinate(double position, double origin, double extent)
    {
        if (!double.IsFinite(position)
            || !double.IsFinite(origin)
            || !double.IsFinite(extent)
            || extent <= 0)
        {
            return 0;
        }

        return (position - origin) / extent;
    }

    private static double FiniteOrZero(double value) => double.IsFinite(value) ? value : 0;

    private static double PositiveFiniteOrZero(double value) =>
        double.IsFinite(value) && value > 0 ? value : 0;
}
