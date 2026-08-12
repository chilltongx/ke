using System.Reflection;
using Ke.Windows.App;
using Ke.Windows.Core;
using Xunit;

namespace Ke.Windows.Automation.Tests;

public sealed class PanelPositionStoreTests
{
    [Fact]
    public void Persistence_io_failure_does_not_escape_save_path()
    {
        using var directory = new TemporaryDirectory();
        var blockedDirectory = Path.Combine(directory.Path, "blocked");
        File.WriteAllText(blockedDirectory, "not a directory");
        var store = CreateStore(Path.Combine(blockedDirectory, "settings.json"));

        var exception = Record.Exception(
            () => WritePosition(
                store,
                new SavedPanelPosition("display", 96, 0.25, 0.75)));

        Assert.Null(exception);
    }

    private static PanelPositionStore CreateStore(string settingsPath)
    {
        var constructor = typeof(PanelPositionStore).GetConstructor(
            BindingFlags.Instance | BindingFlags.NonPublic,
            binder: null,
            [typeof(string)],
            modifiers: null);
        Assert.NotNull(constructor);
        return (PanelPositionStore)constructor.Invoke([settingsPath]);
    }

    private static void WritePosition(
        PanelPositionStore store,
        SavedPanelPosition saved)
    {
        var method = typeof(PanelPositionStore).GetMethod(
            "WriteAtomically",
            BindingFlags.Instance | BindingFlags.NonPublic);
        Assert.NotNull(method);
        method.Invoke(store, [saved]);
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        public TemporaryDirectory()
        {
            Path = System.IO.Path.Combine(
                System.IO.Path.GetTempPath(),
                $"ke-panel-position-{Guid.NewGuid():N}");
            Directory.CreateDirectory(Path);
        }

        public string Path { get; }

        public void Dispose() => Directory.Delete(Path, recursive: true);
    }
}
