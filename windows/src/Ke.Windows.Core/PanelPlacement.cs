namespace Ke.Windows.Core;

public readonly record struct PhysicalPoint(double X, double Y);

public readonly record struct SavedPanelPosition(
    string DeviceName,
    double Dpi,
    double RelativeX,
    double RelativeY);

public readonly record struct PhysicalWorkArea(
    double X,
    double Y,
    double Width,
    double Height,
    double Dpi);

public static class PanelPlacement
{
    public const double DefaultInsetDip = 24;
    private const double DefaultDpi = 96;

    public static SavedPanelPosition Save(
        string deviceName,
        double dpi,
        PhysicalPoint position,
        PhysicalWorkArea workArea,
        double panelWidthDip,
        double panelHeightDip)
    {
        var panelWidth = DipToPhysicalLength(panelWidthDip, workArea.Dpi);
        var panelHeight = DipToPhysicalLength(panelHeightDip, workArea.Dpi);
        var usableWidth = UsableLength(workArea.Width, panelWidth);
        var usableHeight = UsableLength(workArea.Height, panelHeight);

        return new SavedPanelPosition(
            deviceName,
            dpi,
            RelativeCoordinate(position.X, workArea.X, usableWidth),
            RelativeCoordinate(position.Y, workArea.Y, usableHeight));
    }

    public static PhysicalPoint Restore(
        SavedPanelPosition? saved,
        PhysicalWorkArea workArea,
        double panelWidthDip,
        double panelHeightDip)
    {
        var originX = FiniteOrZero(workArea.X);
        var originY = FiniteOrZero(workArea.Y);
        var width = PositiveFiniteOrZero(workArea.Width);
        var height = PositiveFiniteOrZero(workArea.Height);
        if (width <= 0 || height <= 0)
        {
            return new PhysicalPoint(originX, originY);
        }

        var panelWidth = DipToPhysicalLength(panelWidthDip, workArea.Dpi);
        var panelHeight = DipToPhysicalLength(panelHeightDip, workArea.Dpi);
        var usableWidth = UsableLength(width, panelWidth);
        var usableHeight = UsableLength(height, panelHeight);

        if (HasValidCoordinates(saved))
        {
            var value = saved!.Value;
            return new PhysicalPoint(
                originX + (Math.Clamp(value.RelativeX, 0, 1) * usableWidth),
                originY + (Math.Clamp(value.RelativeY, 0, 1) * usableHeight));
        }

        var inset = DipToPhysicalLength(DefaultInsetDip, workArea.Dpi);
        return new PhysicalPoint(
            originX + Math.Max(0, usableWidth - inset),
            originY + Math.Max(0, usableHeight - inset));
    }

    public static double DipToPhysicalLength(double dip, double dpi)
    {
        var safeDip = PositiveFiniteOrZero(dip);
        var safeDpi = double.IsFinite(dpi) && dpi > 0 ? dpi : DefaultDpi;
        return safeDip * safeDpi / DefaultDpi;
    }

    private static bool HasValidCoordinates(SavedPanelPosition? saved)
    {
        return saved is { } value
            && double.IsFinite(value.Dpi)
            && value.Dpi > 0
            && double.IsFinite(value.RelativeX)
            && double.IsFinite(value.RelativeY);
    }

    private static double RelativeCoordinate(double position, double origin, double usableLength)
    {
        if (!double.IsFinite(position)
            || !double.IsFinite(origin)
            || usableLength <= 0)
        {
            return 0;
        }

        var relative = (position - origin) / usableLength;
        return double.IsFinite(relative) ? Math.Clamp(relative, 0, 1) : 0;
    }

    private static double UsableLength(double extent, double panelLength) =>
        Math.Max(0, PositiveFiniteOrZero(extent) - panelLength);

    private static double FiniteOrZero(double value) => double.IsFinite(value) ? value : 0;

    private static double PositiveFiniteOrZero(double value) =>
        double.IsFinite(value) && value > 0 ? value : 0;
}
