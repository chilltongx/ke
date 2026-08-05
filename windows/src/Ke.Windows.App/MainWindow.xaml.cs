using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using Ke.Windows.Core;

namespace Ke.Windows.App;

public partial class MainWindow : Window
{
    private const int GwlExStyle = -20;
    private const long WsExNoActivate = 0x08000000L;
    private const long WsExToolWindow = 0x00000080L;
    private const int WmMouseActivate = 0x0021;
    private const int MaNoActivate = 3;
    private const double DragThreshold = 6;

    private readonly PanelPositionStore _positionStore;
    private GestureTracker? _gesture;
    private DipPoint _grabOffset;
    private HwndSource? _source;

    public MainWindow(PanelPositionStore positionStore)
    {
        ArgumentNullException.ThrowIfNull(positionStore);

        _positionStore = positionStore;
        InitializeComponent();

        var initialPosition = _positionStore.Load(Width, Height);
        Left = initialPosition.X;
        Top = initialPosition.Y;
        SourceInitialized += OnSourceInitialized;
    }

    public event EventHandler? SendRequested;

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        var handle = new WindowInteropHelper(this).Handle;
        var extendedStyle = GetWindowLongPtr(handle, GwlExStyle).ToInt64();
        SetWindowLongPtr(handle, GwlExStyle, new IntPtr(extendedStyle | WsExNoActivate | WsExToolWindow));

        _source = HwndSource.FromHwnd(handle);
        _source?.AddHook(WindowMessageHook);
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (_source is not null)
        {
            _source.RemoveHook(WindowMessageHook);
            _source = null;
        }

        base.OnClosing(e);
    }

    private IntPtr WindowMessageHook(
        IntPtr hwnd,
        int message,
        IntPtr wParam,
        IntPtr lParam,
        ref bool handled)
    {
        if (message != WmMouseActivate)
        {
            return IntPtr.Zero;
        }

        handled = true;
        return new IntPtr(MaNoActivate);
    }

    private void OnMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        var cursor = GetCursorPositionInDip();
        _gesture = new GestureTracker(cursor, DragThreshold);
        _grabOffset = new DipPoint(cursor.X - Left, cursor.Y - Top);
        Mouse.Capture(this, CaptureMode.Element);
        e.Handled = true;
    }

    private void OnMouseMove(object sender, MouseEventArgs e)
    {
        if (_gesture is null || e.LeftButton != MouseButtonState.Pressed)
        {
            return;
        }

        var cursor = GetCursorPositionInDip();
        if (_gesture.MoveTo(cursor) != GestureDecision.Drag)
        {
            return;
        }

        Left = cursor.X - _grabOffset.X;
        Top = cursor.Y - _grabOffset.Y;
        e.Handled = true;
    }

    private void OnMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (_gesture is null)
        {
            return;
        }

        var decision = _gesture.Release();
        _gesture = null;
        Mouse.Capture(null);
        e.Handled = true;

        if (decision == GestureDecision.Drag)
        {
            var handle = new WindowInteropHelper(this).Handle;
            _positionStore.Save(handle, new DipPoint(Left, Top));
            return;
        }

        SendRequested?.Invoke(this, EventArgs.Empty);
    }

    private void OnAboutClick(object sender, RoutedEventArgs e)
    {
        MessageBox.Show(
            "可 · Windows",
            "关于",
            MessageBoxButton.OK,
            MessageBoxImage.Information,
            MessageBoxResult.OK,
            MessageBoxOptions.DefaultDesktopOnly);
    }

    private void OnExitClick(object sender, RoutedEventArgs e)
    {
        Application.Current.Shutdown();
    }

    private DipPoint GetCursorPositionInDip()
    {
        if (!GetCursorPos(out var cursor))
        {
            return new DipPoint(Left + _grabOffset.X, Top + _grabOffset.Y);
        }

        var transform = _source?.CompositionTarget?.TransformFromDevice ?? System.Windows.Media.Matrix.Identity;
        var dip = transform.Transform(new Point(cursor.X, cursor.Y));
        return new DipPoint(dip.X, dip.Y);
    }

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW", SetLastError = true)]
    private static extern IntPtr GetWindowLongPtr(IntPtr window, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)]
    private static extern IntPtr SetWindowLongPtr(IntPtr window, int index, IntPtr newLong);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out NativePoint point);

    [StructLayout(LayoutKind.Sequential)]
    private readonly struct NativePoint
    {
        public readonly int X;
        public readonly int Y;
    }
}
