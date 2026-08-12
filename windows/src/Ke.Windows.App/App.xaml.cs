using System.Windows;
using Ke.Windows.Automation;

namespace Ke.Windows.App;

public partial class App : Application
{
    private SingleInstanceGuard? _singleInstance;
    private AutomationDispatcher? _automationDispatcher;
    private SendCoordinator? _coordinator;
    private MainWindow? _window;
    private int _cleanedUp;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _singleInstance = SingleInstanceGuard.TryAcquire();
        if (_singleInstance is null)
        {
            Shutdown(0);
            return;
        }

        try
        {
            _automationDispatcher = new AutomationDispatcher();
            var snapshotProvider = new FocusSnapshotProvider();
            var adapterRegistry = TargetAdapterRegistry.CreateDefault();
            var inputWriter = new WindowsInputWriter();
            var sender = new FocusedChatSender(
                snapshotProvider,
                adapterRegistry,
                inputWriter);
            _coordinator = new SendCoordinator(
                _automationDispatcher,
                sender,
                new SystemSendDeadline(),
                new WpfUiCallbackDispatcher(Dispatcher));
            _window = new MainWindow(new PanelPositionStore());
            _window.SendRequested += OnSendRequested;
            MainWindow = _window;
            _window.Show();
        }
        catch
        {
            Cleanup();
            Shutdown(-1);
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        Cleanup();
        base.OnExit(e);
    }

    private void OnSendRequested(object? sender, EventArgs e)
    {
        var coordinator = _coordinator;
        var window = _window;
        if (coordinator is null || window is null)
        {
            return;
        }

        _ = ObserveSendAsync(
            coordinator.TryStartAsync(
                result =>
                {
                    window.ShowSendResult(result);
                    return Task.CompletedTask;
                }));
    }

    private void Cleanup()
    {
        if (Interlocked.Exchange(ref _cleanedUp, 1) != 0)
        {
            return;
        }

        try
        {
            if (_window is not null)
            {
                _window.SendRequested -= OnSendRequested;
                if (_window.IsLoaded)
                {
                    _window.Close();
                }

                _window = null;
            }
        }
        finally
        {
            _coordinator?.Dispose();
            _coordinator = null;

            try
            {
                _automationDispatcher?.Dispose();
            }
            finally
            {
                _automationDispatcher = null;
                _singleInstance?.Dispose();
                _singleInstance = null;
            }
        }
    }

    private static async Task ObserveSendAsync(Task<bool> send)
    {
        try
        {
            _ = await send;
        }
        catch (OperationCanceledException)
        {
        }
    }
}
