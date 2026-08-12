using System.IO;
using System.Runtime.InteropServices;
using System.Security;
using System.Text.Json;
using Ke.Windows.Core;

namespace Ke.Windows.App;

public sealed class PanelPositionStore
{
    private const int MonitorDefaultToNearest = 2;

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.General);

    private readonly string _settingsPath;

    public PanelPositionStore()
        : this(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Ke",
            "settings.json"))
    {
    }

    internal PanelPositionStore(string settingsPath)
    {
        _settingsPath = settingsPath;
    }

    public void RestoreWindow(IntPtr windowHandle, double panelWidthDip, double panelHeightDip)
    {
        var saved = ReadSavedPosition();
        var monitor = FindMonitor(saved?.DeviceName) ?? MonitorUnderCursor();

        PhysicalWindowApi.MoveWithoutActivation(
            windowHandle,
            new PhysicalPoint(monitor.WorkArea.Left, monitor.WorkArea.Top));

        var targetDpi = PhysicalWindowApi.GetDpi(windowHandle);
        var workArea = monitor.ToPhysicalWorkArea(targetDpi);
        var target = PanelPlacement.Restore(saved, workArea, panelWidthDip, panelHeightDip);
        var panelWidth = PanelPlacement.DipToPhysicalLength(panelWidthDip, targetDpi);
        var panelHeight = PanelPlacement.DipToPhysicalLength(panelHeightDip, targetDpi);
        PhysicalWindowApi.MoveAndSizeWithoutActivation(
            windowHandle,
            target,
            panelWidth,
            panelHeight);
    }

    public void Save(IntPtr windowHandle, double panelWidthDip, double panelHeightDip)
    {
        if (!PhysicalWindowApi.TryGetTopLeft(windowHandle, out var position))
        {
            return;
        }

        var monitorHandle = MonitorFromWindow(windowHandle, MonitorDefaultToNearest);
        var monitor = ReadMonitor(monitorHandle) ?? MonitorUnderCursor();
        var dpi = PhysicalWindowApi.GetDpi(windowHandle);
        var saved = PanelPlacement.Save(
            monitor.DeviceName,
            dpi,
            position,
            monitor.ToPhysicalWorkArea(dpi),
            panelWidthDip,
            panelHeightDip);

        WriteAtomically(saved);
    }

    private SavedPanelPosition? ReadSavedPosition()
    {
        try
        {
            using var stream = new FileStream(
                _settingsPath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read);
            return JsonSerializer.Deserialize<SavedPanelPosition>(stream, JsonOptions);
        }
        catch (Exception exception) when (exception is IOException
            or UnauthorizedAccessException
            or JsonException
            or NotSupportedException)
        {
            return null;
        }
    }

    private void WriteAtomically(SavedPanelPosition saved)
    {
        try
        {
            WriteAtomicallyCore(saved);
        }
        catch (Exception exception) when (exception is IOException
            or UnauthorizedAccessException
            or SecurityException
            or ArgumentException
            or NotSupportedException)
        {
            // Keep the current in-memory window position when persistence is unavailable.
        }
    }

    private void WriteAtomicallyCore(SavedPanelPosition saved)
    {
        var directory = Path.GetDirectoryName(_settingsPath)
            ?? throw new InvalidOperationException("Settings path must have a parent directory.");
        Directory.CreateDirectory(directory);

        var temporaryPath = Path.Combine(directory, $".{Path.GetFileName(_settingsPath)}.{Guid.NewGuid():N}.tmp");
        try
        {
            using (var stream = new FileStream(
                temporaryPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                bufferSize: 4096,
                FileOptions.WriteThrough))
            {
                JsonSerializer.Serialize(stream, saved, JsonOptions);
                stream.Flush(flushToDisk: true);
            }

            File.Move(temporaryPath, _settingsPath, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private static MonitorSnapshot? FindMonitor(string? deviceName)
    {
        if (string.IsNullOrWhiteSpace(deviceName))
        {
            return null;
        }

        MonitorSnapshot? match = null;
        EnumDisplayMonitors(
            IntPtr.Zero,
            IntPtr.Zero,
            (monitor, _, _, _) =>
            {
                var candidate = ReadMonitor(monitor);
                if (candidate is not null
                    && string.Equals(candidate.DeviceName, deviceName, StringComparison.OrdinalIgnoreCase))
                {
                    match = candidate;
                    return false;
                }

                return true;
            },
            IntPtr.Zero);
        return match;
    }

    private static MonitorSnapshot MonitorUnderCursor()
    {
        var cursor = PhysicalWindowApi.TryGetCursor(out var physicalCursor)
            ? new NativePoint(physicalCursor.X, physicalCursor.Y)
            : new NativePoint(0, 0);
        var monitor = MonitorFromPoint(cursor, MonitorDefaultToNearest);
        return ReadMonitor(monitor)
            ?? new MonitorSnapshot(string.Empty, new NativeRectangle(0, 0, 0, 0));
    }

    private static MonitorSnapshot? ReadMonitor(IntPtr monitor)
    {
        if (monitor == IntPtr.Zero)
        {
            return null;
        }

        var info = new MonitorInfoEx
        {
            Size = Marshal.SizeOf<MonitorInfoEx>()
        };
        return GetMonitorInfo(monitor, ref info)
            ? new MonitorSnapshot(info.DeviceName, info.WorkArea)
            : null;
    }

    private sealed record MonitorSnapshot(string DeviceName, NativeRectangle WorkArea)
    {
        public PhysicalWorkArea ToPhysicalWorkArea(double dpi) => new(
            WorkArea.Left,
            WorkArea.Top,
            WorkArea.Right - WorkArea.Left,
            WorkArea.Bottom - WorkArea.Top,
            dpi);
    }

    private delegate bool MonitorEnumProcedure(
        IntPtr monitor,
        IntPtr deviceContext,
        IntPtr monitorRectangle,
        IntPtr data);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumDisplayMonitors(
        IntPtr deviceContext,
        IntPtr clipRectangle,
        MonitorEnumProcedure callback,
        IntPtr data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfoEx monitorInfo);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromPoint(NativePoint point, int flags);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromWindow(IntPtr window, int flags);

    [StructLayout(LayoutKind.Sequential)]
    private readonly struct NativePoint
    {
        public NativePoint(double x, double y)
        {
            X = checked((int)Math.Round(x));
            Y = checked((int)Math.Round(y));
        }

        public readonly int X;
        public readonly int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRectangle
    {
        public NativeRectangle(int left, int top, int right, int bottom)
        {
            Left = left;
            Top = top;
            Right = right;
            Bottom = bottom;
        }

        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MonitorInfoEx
    {
        public int Size;
        public NativeRectangle Monitor;
        public NativeRectangle WorkArea;
        public uint Flags;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string DeviceName;
    }
}
