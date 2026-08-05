using Ke.Windows.Core;
using Xunit;

namespace Ke.Windows.Core.Tests;

public sealed class PanelPositionMathTests
{
    [Fact]
    public void Save_uses_relative_work_area_coordinates()
    {
        var saved = PanelPlacement.Save(
            "DISPLAY1",
            144,
            new DipPoint(700, 500),
            new WorkArea(100, 100, 1200, 800, 144));

        Assert.Equal("DISPLAY1", saved.DeviceName);
        Assert.Equal(144, saved.Dpi);
        Assert.Equal(0.5, saved.RelativeX, 3);
        Assert.Equal(0.5, saved.RelativeY, 3);
    }

    [Fact]
    public void Restore_preserves_relative_position_after_dpi_change()
    {
        var saved = new SavedPanelPosition("DISPLAY1", 96, 0.25, 0.75);

        var restored = PanelPlacement.Restore(
            saved,
            new WorkArea(200, 100, 1600, 900, 144),
            panelWidth: 64,
            panelHeight: 64);

        Assert.Equal(600, restored.X, 3);
        Assert.Equal(775, restored.Y, 3);
    }

    [Fact]
    public void Restored_position_is_clamped_inside_work_area()
    {
        var result = PanelPlacement.Restore(
            new SavedPanelPosition("DISPLAY1", 96, 1.4, -0.5),
            new WorkArea(100, 100, 1200, 800, 144),
            panelWidth: 64,
            panelHeight: 64);

        Assert.Equal(1236, result.X, 3);
        Assert.Equal(100, result.Y, 3);
    }

    [Theory]
    [InlineData(double.NaN, 0.5)]
    [InlineData(double.PositiveInfinity, 0.5)]
    [InlineData(0.5, double.NegativeInfinity)]
    public void Invalid_saved_coordinates_use_bottom_right_default(double relativeX, double relativeY)
    {
        var result = PanelPlacement.Restore(
            new SavedPanelPosition("DISPLAY1", 96, relativeX, relativeY),
            new WorkArea(100, 100, 1200, 800, 144),
            panelWidth: 64,
            panelHeight: 64);

        Assert.Equal(1212, result.X, 3);
        Assert.Equal(812, result.Y, 3);
    }

    [Fact]
    public void Missing_saved_position_uses_bottom_right_default()
    {
        var result = PanelPlacement.Restore(
            saved: null,
            new WorkArea(-1920, 0, 1920, 1080, 96),
            panelWidth: 64,
            panelHeight: 64);

        Assert.Equal(-88, result.X, 3);
        Assert.Equal(992, result.Y, 3);
    }

    [Theory]
    [InlineData(0, 0)]
    [InlineData(-100, 200)]
    [InlineData(200, -100)]
    public void Non_positive_work_area_keeps_panel_at_finite_origin(double width, double height)
    {
        var result = PanelPlacement.Restore(
            new SavedPanelPosition("DISPLAY1", 96, 0.5, 0.5),
            new WorkArea(20, 30, width, height, 96),
            panelWidth: 64,
            panelHeight: 64);

        Assert.Equal(20, result.X);
        Assert.Equal(30, result.Y);
    }

    [Fact]
    public void Save_with_invalid_work_area_uses_safe_relative_origin()
    {
        var saved = PanelPlacement.Save(
            "DISPLAY1",
            96,
            new DipPoint(double.NaN, double.PositiveInfinity),
            new WorkArea(0, 0, 0, -1, 96));

        Assert.Equal(0, saved.RelativeX);
        Assert.Equal(0, saved.RelativeY);
    }
}
