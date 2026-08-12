using System.Runtime.InteropServices;
using Ke.Windows.Core;

namespace Ke.Windows.App;

internal static class PhysicalWindowApi
{
    private const uint DefaultDpi = 96;
    private const uint SwpNoSize = 0x0001;
    private const uint SwpNoZOrder = 0x0004;
    private const uint SwpNoActivate = 0x0010;

    public static bool TryGetCursor(out PhysicalPoint point)
    {
        if (GetCursorPos(out var native))
        {
            point = new PhysicalPoint(native.X, native.Y);
            return true;
        }

        point = default;
        return false;
    }

    public static bool TryGetTopLeft(IntPtr windowHandle, out PhysicalPoint point)
    {
        if (GetWindowRect(windowHandle, out var rectangle))
        {
            point = new PhysicalPoint(rectangle.Left, rectangle.Top);
            return true;
        }

        point = default;
        return false;
    }

    public static double GetDpi(IntPtr windowHandle)
    {
        var dpi = GetDpiForWindow(windowHandle);
        return dpi > 0 ? dpi : DefaultDpi;
    }

    public static void MoveWithoutActivation(IntPtr windowHandle, PhysicalPoint topLeft)
    {
        SetWindowPos(
            windowHandle,
            IntPtr.Zero,
            ToNative(topLeft.X),
            ToNative(topLeft.Y),
            0,
            0,
            SwpNoSize | SwpNoZOrder | SwpNoActivate);
    }

    public static void MoveAndSizeWithoutActivation(
        IntPtr windowHandle,
        PhysicalPoint topLeft,
        double width,
        double height)
    {
        SetWindowPos(
            windowHandle,
            IntPtr.Zero,
            ToNative(topLeft.X),
            ToNative(topLeft.Y),
            Math.Max(1, ToNative(width)),
            Math.Max(1, ToNative(height)),
            SwpNoZOrder | SwpNoActivate);
    }

    private static int ToNative(double value) => checked((int)Math.Round(value));

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out NativePoint point);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetWindowRect(IntPtr windowHandle, out NativeRectangle rectangle);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr windowHandle);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(
        IntPtr windowHandle,
        IntPtr insertAfter,
        int x,
        int y,
        int width,
        int height,
        uint flags);

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint
    {
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
}
