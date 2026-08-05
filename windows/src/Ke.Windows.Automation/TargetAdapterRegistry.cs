using Ke.Windows.Core;

namespace Ke.Windows.Automation;

public sealed class TargetAdapterRegistry
{
    private readonly IReadOnlyDictionary<string, ITargetAdapter> _adapters;

    internal TargetAdapterRegistry(IEnumerable<ITargetAdapter> adapters)
    {
        _adapters = adapters.ToDictionary(
            adapter => adapter.ProcessImageName,
            StringComparer.OrdinalIgnoreCase);
    }

    public static TargetAdapterRegistry CreateDefault() => new(
    [
        new ProfileTargetAdapter(AdapterProfiles.Codex),
        new ProfileTargetAdapter(AdapterProfiles.VisualStudioCode)
    ]);

    public TargetClassification Classify(FocusSnapshot snapshot) =>
        Validate(snapshot, ComposerExpectation.Empty);

    public TargetClassification Validate(
        FocusSnapshot snapshot,
        ComposerExpectation expectation)
    {
        if (!_adapters.TryGetValue(snapshot.ProcessImageName, out var adapter))
        {
            return new(null, SendErrorCode.UnsupportedApplication);
        }

        return adapter.Classify(snapshot, expectation);
    }
}
