using System.Runtime.InteropServices;
using System.Windows.Automation;
using Ke.Windows.Core;

namespace Ke.Windows.Automation;

internal interface IUiAutomationTreeReader
{
    UiAutomationSnapshot Read(CancellationToken cancellationToken);
}

internal interface IUiAutomationBackend
{
    IUiAutomationElement GetFocusedElement(CancellationToken cancellationToken);
}

internal interface IUiAutomationElement
{
    ElementSummary ReadSummary(bool includeText, CancellationToken cancellationToken);

    IUiAutomationElement? GetParent(CancellationToken cancellationToken);

    IUiAutomationElement? GetFirstChild(CancellationToken cancellationToken);

    IUiAutomationElement? GetNextSibling(CancellationToken cancellationToken);
}

internal sealed record UiAutomationSnapshot(
    ElementSummary Focused,
    IReadOnlyList<ElementSummary> Ancestors,
    IReadOnlyList<ElementSummary> Nearby);

internal sealed class UiAutomationTreeReader : IUiAutomationTreeReader
{
    private const int MaximumAncestorDepth = 30;
    private const int MaximumElementCount = 512;
    private const int TextProbeLength = 4097;

    private readonly IUiAutomationBackend _backend;

    public UiAutomationTreeReader()
        : this(new WindowsUiAutomationBackend())
    {
    }

    internal UiAutomationTreeReader(IUiAutomationBackend backend)
    {
        _backend = backend;
    }

    public UiAutomationSnapshot Read(CancellationToken cancellationToken)
    {
        try
        {
            var focusedElement = Call(
                cancellationToken,
                () => _backend.GetFocusedElement(cancellationToken));
            var focused = ReadSummary(focusedElement, includeText: true, cancellationToken);

            var pathElements = new List<IUiAutomationElement> { focusedElement };
            var ancestors = new List<ElementSummary>();
            var pathRuntimeIds = new HashSet<string>(StringComparer.Ordinal)
            {
                focused.RuntimeId
            };
            var current = focusedElement;

            while (true)
            {
                var parent = Call(
                    cancellationToken,
                    () => current.GetParent(cancellationToken));
                if (parent is null)
                {
                    break;
                }

                if (ancestors.Count == MaximumAncestorDepth)
                {
                    throw Unavailable();
                }

                EnsureCapacity(1 + ancestors.Count);
                var summary = ReadSummary(parent, includeText: false, cancellationToken);
                if (!pathRuntimeIds.Add(summary.RuntimeId))
                {
                    throw Unavailable();
                }

                pathElements.Add(parent);
                ancestors.Add(summary);
                current = parent;
            }

            var nearby = new List<ElementSummary>();
            foreach (var pathElement in pathElements)
            {
                var child = Call(
                    cancellationToken,
                    () => pathElement.GetFirstChild(cancellationToken));
                while (child is not null)
                {
                    var summary = ReadSummary(child, includeText: false, cancellationToken);
                    if (!pathRuntimeIds.Contains(summary.RuntimeId))
                    {
                        EnsureCapacity(1 + ancestors.Count + nearby.Count);
                        nearby.Add(summary);
                    }

                    var previous = child;
                    child = Call(
                        cancellationToken,
                        () => previous.GetNextSibling(cancellationToken));
                }
            }

            return new(focused, ancestors, nearby);
        }
        catch (OperationCanceledException exception)
        {
            throw new AutomationCaptureException(
                SendErrorCode.AutomationTimeout,
                exception);
        }
        catch (AutomationCaptureException)
        {
            throw;
        }
        catch (Exception exception) when (
            exception is ElementNotAvailableException or
            COMException or
            InvalidOperationException or
            NotSupportedException)
        {
            throw new AutomationCaptureException(
                SendErrorCode.AutomationUnavailable,
                exception);
        }
    }

    private static ElementSummary ReadSummary(
        IUiAutomationElement element,
        bool includeText,
        CancellationToken cancellationToken)
    {
        var summary = Call(
            cancellationToken,
            () => element.ReadSummary(includeText, cancellationToken));
        if (string.IsNullOrWhiteSpace(summary.RuntimeId) ||
            includeText && summary.Text?.Length >= TextProbeLength)
        {
            throw Unavailable();
        }

        return summary;
    }

    private static T Call<T>(CancellationToken cancellationToken, Func<T> call)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var result = call();
        cancellationToken.ThrowIfCancellationRequested();
        return result;
    }

    private static void EnsureCapacity(int currentCount)
    {
        if (currentCount >= MaximumElementCount)
        {
            throw Unavailable();
        }
    }

    private static AutomationCaptureException Unavailable() =>
        new(SendErrorCode.AutomationUnavailable);

    private sealed class WindowsUiAutomationBackend : IUiAutomationBackend
    {
        public IUiAutomationElement GetFocusedElement(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var element = AutomationElement.FocusedElement;
            cancellationToken.ThrowIfCancellationRequested();
            return element is null
                ? throw Unavailable()
                : new WindowsUiAutomationElement(element);
        }
    }

    private sealed class WindowsUiAutomationElement(AutomationElement element) : IUiAutomationElement
    {
        public ElementSummary ReadSummary(
            bool includeText,
            CancellationToken cancellationToken)
        {
            var runtimeId = Invoke(cancellationToken, element.GetRuntimeId);
            if (runtimeId is null || runtimeId.Length == 0)
            {
                throw Unavailable();
            }

            var text = includeText ? ReadText(cancellationToken) : null;
            return new(
                string.Join('.', runtimeId),
                ReadControlType(cancellationToken),
                ReadString(AutomationElement.ClassNameProperty, cancellationToken),
                ReadString(AutomationElement.AutomationIdProperty, cancellationToken),
                ReadString(AutomationElement.NameProperty, cancellationToken),
                ReadBoolean(AutomationElement.IsEnabledProperty, cancellationToken),
                ReadBoolean(AutomationElement.IsKeyboardFocusableProperty, cancellationToken),
                ReadBoolean(AutomationElement.IsPasswordProperty, cancellationToken),
                ReadBoolean(ValuePattern.IsReadOnlyProperty, cancellationToken),
                text);
        }

        public IUiAutomationElement? GetParent(CancellationToken cancellationToken) =>
            Wrap(Invoke(
                cancellationToken,
                () => TreeWalker.ControlViewWalker.GetParent(element)));

        public IUiAutomationElement? GetFirstChild(CancellationToken cancellationToken) =>
            Wrap(Invoke(
                cancellationToken,
                () => TreeWalker.ControlViewWalker.GetFirstChild(element)));

        public IUiAutomationElement? GetNextSibling(CancellationToken cancellationToken) =>
            Wrap(Invoke(
                cancellationToken,
                () => TreeWalker.ControlViewWalker.GetNextSibling(element)));

        private string? ReadText(CancellationToken cancellationToken)
        {
            if (Invoke(
                    cancellationToken,
                    () => element.TryGetCurrentPattern(ValuePattern.Pattern, out var valuePattern)
                        ? valuePattern
                        : null) is ValuePattern value)
            {
                return Invoke(cancellationToken, () => value.Current.Value);
            }

            if (Invoke(
                    cancellationToken,
                    () => element.TryGetCurrentPattern(TextPattern.Pattern, out var textPattern)
                        ? textPattern
                        : null) is TextPattern text)
            {
                return Invoke(
                    cancellationToken,
                    () => text.DocumentRange.GetText(TextProbeLength));
            }

            return null;
        }

        private string ReadControlType(CancellationToken cancellationToken)
        {
            var value = ReadProperty(
                AutomationElement.ControlTypeProperty,
                cancellationToken);
            return value is ControlType controlType
                ? controlType.ProgrammaticName
                : throw Unavailable();
        }

        private string ReadString(
            AutomationProperty property,
            CancellationToken cancellationToken) =>
            ReadProperty(property, cancellationToken) as string ?? throw Unavailable();

        private bool ReadBoolean(
            AutomationProperty property,
            CancellationToken cancellationToken) =>
            ReadProperty(property, cancellationToken) is bool value
                ? value
                : throw Unavailable();

        private object ReadProperty(
            AutomationProperty property,
            CancellationToken cancellationToken)
        {
            var value = Invoke(
                cancellationToken,
                () => element.GetCurrentPropertyValue(property, ignoreDefaultValue: true));
            return ReferenceEquals(value, AutomationElement.NotSupported)
                ? throw Unavailable()
                : value;
        }

        private static IUiAutomationElement? Wrap(AutomationElement? value) =>
            value is null ? null : new WindowsUiAutomationElement(value);

        private static T Invoke<T>(CancellationToken cancellationToken, Func<T> call)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var result = call();
            cancellationToken.ThrowIfCancellationRequested();
            return result;
        }
    }
}
