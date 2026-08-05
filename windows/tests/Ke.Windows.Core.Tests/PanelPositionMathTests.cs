using Ke.Windows.Core;
using Xunit;

namespace Ke.Windows.Core.Tests;

public sealed class PanelPositionMathTests
{
    [Fact]
    public void Save_uses_physical_local_offset_over_available_travel()
    {
        var saved = PanelPlacement.Save(
            "DISPLAY1",
            144,
            new PhysicalPoint(652, 452),
            new PhysicalWorkArea(100, 100, 1200, 800, 144),
            panelWidthDip: 64,
            panelHeightDip: 64);

        Assert.Equal("DISPLAY1", saved.DeviceName);
        Assert.Equal(144, saved.Dpi);
        Assert.Equal(0.5, saved.RelativeX, 3);
        Assert.Equal(0.5, saved.RelativeY, 3);
    }

    [Fact]
    public void Right_monitor_physical_origin_is_not_scaled_by_target_dpi()
    {
        var restored = PanelPlacement.Restore(
            new SavedPanelPosition("RIGHT", 96, 0.5, 0.5),
            new PhysicalWorkArea(1920, 0, 2160, 1200, 144),
            panelWidthDip: 64,
            panelHeightDip: 64);

        Assert.Equal(2952, restored.X, 3);
        Assert.Equal(552, restored.Y, 3);
    }

    [Fact]
    public void Left_monitor_negative_physical_origin_is_preserved()
    {
        var restored = PanelPlacement.Restore(
            new SavedPanelPosition("LEFT", 96, 0.5, 0.5),
            new PhysicalWorkArea(-2560, -200, 2560, 1440, 144),
            panelWidthDip: 64,
            panelHeightDip: 64);

        Assert.Equal(-1328, restored.X, 3);
        Assert.Equal(472, restored.Y, 3);
    }

    [Fact]
    public void Dpi_change_preserves_relative_position_using_new_pixel_size()
    {
        var saved = PanelPlacement.Save(
            "DISPLAY1",
            96,
            new PhysicalPoint(928, 508),
            new PhysicalWorkArea(0, 0, 1920, 1080, 96),
            panelWidthDip: 64,
            panelHeightDip: 64);

        var restored = PanelPlacement.Restore(
            saved,
            new PhysicalWorkArea(0, 0, 2560, 1440, 144),
            panelWidthDip: 64,
            panelHeightDip: 64);

        Assert.Equal(1232, restored.X, 3);
        Assert.Equal(672, restored.Y, 3);
    }

    [Fact]
    public void Restored_position_is_clamped_inside_physical_work_area()
    {
        var result = PanelPlacement.Restore(
            new SavedPanelPosition("DISPLAY1", 96, 1.4, -0.5),
            new PhysicalWorkArea(100, 100, 1200, 800, 144),
            panelWidthDip: 64,
            panelHeightDip: 64);

        Assert.Equal(1204, result.X, 3);
        Assert.Equal(100, result.Y, 3);
    }

    [Theory]
    [InlineData(double.NaN, 0.5)]
    [InlineData(double.PositiveInfinity, 0.5)]
    [InlineData(0.5, double.NegativeInfinity)]
    public void Invalid_saved_coordinates_use_scaled_bottom_right_default(double relativeX, double relativeY)
    {
        var result = PanelPlacement.Restore(
            new SavedPanelPosition("DISPLAY1", 96, relativeX, relativeY),
            new PhysicalWorkArea(100, 100, 1200, 800, 144),
            panelWidthDip: 64,
            panelHeightDip: 64);

        Assert.Equal(1168, result.X, 3);
        Assert.Equal(768, result.Y, 3);
    }

    [Fact]
    public void Missing_saved_position_uses_bottom_right_default()
    {
        var result = PanelPlacement.Restore(
            saved: null,
            new PhysicalWorkArea(-1920, 0, 1920, 1080, 96),
            panelWidthDip: 64,
            panelHeightDip: 64);

        Assert.Equal(-88, result.X, 3);
        Assert.Equal(992, result.Y, 3);
    }

    [Theory]
    [InlineData(0, 0)]
    [InlineData(-100, 200)]
    [InlineData(200, -100)]
    public void Non_positive_work_area_keeps_panel_at_finite_physical_origin(double width, double height)
    {
        var result = PanelPlacement.Restore(
            new SavedPanelPosition("DISPLAY1", 96, 0.5, 0.5),
            new PhysicalWorkArea(20, 30, width, height, 96),
            panelWidthDip: 64,
            panelHeightDip: 64);

        Assert.Equal(20, result.X);
        Assert.Equal(30, result.Y);
    }
}
