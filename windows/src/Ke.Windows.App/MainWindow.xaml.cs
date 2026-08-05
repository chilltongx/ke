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
    private PanelGestureController? _gesture;
    private HwndSource? _source;

    public MainWindow(PanelPositionStore positionStore)
    {
        ArgumentNullException.ThrowIfNull(positionStore);

        _positionStore = positionStore;
        InitializeComponent();

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
        _positionStore.RestoreWindow(handle, Width, Height);
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
        var handle = new WindowInteropHelper(this).Handle;
        if (!PhysicalWindowApi.TryGetCursor(out var cursor)
            || !PhysicalWindowApi.TryGetTopLeft(handle, out var panelTopLeft))
        {
            return;
        }

        _gesture = new PanelGestureController(
            cursor,
            panelTopLeft,
            PhysicalWindowApi.GetDpi(handle),
            DragThreshold);
        Mouse.Capture(this, CaptureMode.Element);
        e.Handled = true;
    }

    private void OnMouseMove(object sender, MouseEventArgs e)
    {
        if (_gesture is null || e.LeftButton != MouseButtonState.Pressed)
        {
            return;
        }

        if (!PhysicalWindowApi.TryGetCursor(out var cursor))
        {
            return;
        }

        var update = _gesture.MoveTo(cursor);
        if (update.Decision != GestureDecision.Drag)
        {
            return;
        }

        var handle = new WindowInteropHelper(this).Handle;
        PhysicalWindowApi.MoveWithoutActivation(handle, update.PanelTopLeft);
        e.Handled = true;
    }

    private void OnMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (_gesture is null)
        {
            return;
        }

        if (!PhysicalWindowApi.TryGetCursor(out var cursor))
        {
            _gesture = null;
            Mouse.Capture(null);
            e.Handled = true;
            return;
        }

        var release = _gesture.ReleaseAt(cursor);
        _gesture = null;
        Mouse.Capture(null);
        e.Handled = true;

        if (release.ShouldPersist)
        {
            var handle = new WindowInteropHelper(this).Handle;
            PhysicalWindowApi.MoveWithoutActivation(handle, release.PanelTopLeft);
            _positionStore.Save(handle, Width, Height);
            return;
        }

        if (release.ShouldSend)
        {
            SendRequested?.Invoke(this, EventArgs.Empty);
        }
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

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW", SetLastError = true)]
    private static extern IntPtr GetWindowLongPtr(IntPtr window, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)]
    private static extern IntPtr SetWindowLongPtr(IntPtr window, int index, IntPtr newLong);

}
