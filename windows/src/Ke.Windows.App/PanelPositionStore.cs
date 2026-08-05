using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using Ke.Windows.Core;

namespace Ke.Windows.App;

public sealed class PanelPositionStore
{
    private const int MonitorDefaultToNearest = 2;
    private const int EffectiveDpi = 0;
    private const double DefaultDpi = 96;

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

    public DipPoint Load(double panelWidth, double panelHeight)
    {
        var saved = ReadSavedPosition();
        var monitor = FindMonitor(saved?.DeviceName) ?? MonitorUnderCursor();
        return PanelPlacement.Restore(saved, monitor.WorkArea, panelWidth, panelHeight);
    }

    public void Save(IntPtr windowHandle, DipPoint position)
    {
        var monitorHandle = MonitorFromWindow(windowHandle, MonitorDefaultToNearest);
        var monitor = ReadMonitor(monitorHandle) ?? MonitorUnderCursor();
        var saved = PanelPlacement.Save(
            monitor.DeviceName,
            monitor.WorkArea.Dpi,
            position,
            monitor.WorkArea);

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
        if (!GetCursorPos(out var cursor))
        {
            cursor = new NativePoint(0, 0);
        }

        var monitor = MonitorFromPoint(cursor, MonitorDefaultToNearest);
        return ReadMonitor(monitor)
            ?? new MonitorSnapshot(string.Empty, new WorkArea(0, 0, 0, 0, DefaultDpi));
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
        if (!GetMonitorInfo(monitor, ref info))
        {
            return null;
        }

        var dpi = ReadDpi(monitor);
        var scale = dpi / DefaultDpi;
        var workArea = new WorkArea(
            info.WorkArea.Left / scale,
            info.WorkArea.Top / scale,
            (info.WorkArea.Right - info.WorkArea.Left) / scale,
            (info.WorkArea.Bottom - info.WorkArea.Top) / scale,
            dpi);
        return new MonitorSnapshot(info.DeviceName, workArea);
    }

    private static double ReadDpi(IntPtr monitor)
    {
        var result = GetDpiForMonitor(monitor, EffectiveDpi, out var dpiX, out _);
        return result == 0 && dpiX > 0 ? dpiX : DefaultDpi;
    }

    private sealed record MonitorSnapshot(string DeviceName, WorkArea WorkArea);

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
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out NativePoint point);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromPoint(NativePoint point, int flags);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromWindow(IntPtr window, int flags);

    [DllImport("shcore.dll")]
    private static extern int GetDpiForMonitor(
        IntPtr monitor,
        int dpiType,
        out uint dpiX,
        out uint dpiY);

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint
    {
        public NativePoint(int x, int y)
        {
            X = x;
            Y = y;
        }

        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRectangle
    {
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
