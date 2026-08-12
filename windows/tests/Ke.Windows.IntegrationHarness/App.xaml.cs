using System.Windows;

namespace Ke.Windows.IntegrationHarness;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        var window = new MainWindow();
        MainWindow = window;
        window.ContentRendered += (_, _) => SignalReady(e.Args);
        window.Show();
    }

    private static void SignalReady(IReadOnlyList<string> arguments)
    {
        if (arguments.Count != 2 ||
            !string.Equals(arguments[0], "--ready-event", StringComparison.Ordinal) ||
            string.IsNullOrWhiteSpace(arguments[1]))
        {
            return;
        }

        try
        {
            using var ready = EventWaitHandle.OpenExisting(arguments[1]);
            ready.Set();
        }
        catch (WaitHandleCannotBeOpenedException)
        {
            ShutdownWithFailure();
        }
    }

    private static void ShutdownWithFailure()
    {
        Current?.Shutdown(-1);
    }
}
