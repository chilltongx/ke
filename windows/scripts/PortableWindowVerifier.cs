using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class PortableWindowVerifier
{
    private const int MaximumTopLevelWindows = 4096;
    private const uint WmClose = 0x0010;

    public static IntPtr FindClosableTopLevelWindow(int processId)
    {
        if (processId <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(processId));
        }

        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Windows is required");
        }

        var candidates = new List<WindowCandidate>();
        var exceededLimit = false;
        EnumWindowsProc callback = (window, parameter) =>
        {
            if (candidates.Count == MaximumTopLevelWindows)
            {
                exceededLimit = true;
                return false;
            }

            GetWindowThreadProcessId(window, out var ownerProcessId);
            candidates.Add(new WindowCandidate(
                window,
                ownerProcessId,
                IsWindowNative(window),
                IsWindowVisible(window)));
            return true;
        };

        Marshal.SetLastPInvokeError(0);
        var completed = EnumWindows(callback, IntPtr.Zero);
        if (exceededLimit)
        {
            throw new InvalidOperationException("Top-level window enumeration exceeded bounds");
        }

        if (!completed)
        {
            throw new Win32Exception(
                Marshal.GetLastPInvokeError(),
                "Unable to enumerate top-level windows");
        }

        var selected = SelectExactProcessWindow(candidates, checked((uint)processId));
        return IsExactProcessWindow(selected, processId) ? selected : IntPtr.Zero;
    }

    public static bool IsExactProcessWindow(IntPtr window, int processId)
    {
        if (window == IntPtr.Zero || processId <= 0 ||
            !OperatingSystem.IsWindows() ||
            !IsWindowNative(window) || !IsWindowVisible(window))
        {
            return false;
        }

        return GetWindowThreadProcessId(window, out var ownerProcessId) != 0 &&
            ownerProcessId == checked((uint)processId);
    }

    public static void PostClose(IntPtr window, int processId)
    {
        if (!IsExactProcessWindow(window, processId))
        {
            throw new InvalidOperationException(
                "Refusing to close a window not owned by the exact process");
        }

        Marshal.SetLastPInvokeError(0);
        if (!PostMessage(window, WmClose, IntPtr.Zero, IntPtr.Zero))
        {
            throw new Win32Exception(
                Marshal.GetLastPInvokeError(),
                "Unable to post WM_CLOSE to the exact process window");
        }
    }

    public static void RunSelfTests()
    {
        var expected = new IntPtr(0x44);
        var candidates = new[]
        {
            new WindowCandidate(new IntPtr(0x11), 99, true, true),
            new WindowCandidate(new IntPtr(0x22), 42, false, true),
            new WindowCandidate(new IntPtr(0x33), 42, true, false),
            new WindowCandidate(expected, 42, true, true)
        };
        if (SelectExactProcessWindow(candidates, 42) != expected)
        {
            throw new InvalidOperationException(
                "Exact-process top-level window selection failed");
        }

        if (SelectExactProcessWindow(candidates, 7) != IntPtr.Zero)
        {
            throw new InvalidOperationException(
                "Window selection accepted another process ID");
        }
    }

    private static IntPtr SelectExactProcessWindow(
        IReadOnlyList<WindowCandidate> candidates,
        uint processId)
    {
        foreach (var candidate in candidates)
        {
            if (candidate.Handle != IntPtr.Zero &&
                candidate.ProcessId == processId &&
                candidate.IsWindow && candidate.IsVisible)
            {
                return candidate.Handle;
            }
        }

        return IntPtr.Zero;
    }

    private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(
        IntPtr window,
        out uint processId);

    [DllImport("user32.dll", EntryPoint = "IsWindow")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindowNative(IntPtr window);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll", EntryPoint = "PostMessageW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostMessage(
        IntPtr window,
        uint message,
        IntPtr wParam,
        IntPtr lParam);

    private readonly record struct WindowCandidate(
        IntPtr Handle,
        uint ProcessId,
        bool IsWindow,
        bool IsVisible);
}
