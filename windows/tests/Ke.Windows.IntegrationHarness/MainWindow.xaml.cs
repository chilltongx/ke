using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;

namespace Ke.Windows.IntegrationHarness;

public partial class MainWindow : Window
{
    private bool _focusChangeObserved;
    private int _enterCount;

    public MainWindow()
    {
        InitializeComponent();
        FocusChanges.TextChanged += OnFocusChangesTextChanged;
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter ||
            !ChatEmpty.IsKeyboardFocusWithin &&
            !DocumentEmpty.IsKeyboardFocusWithin)
        {
            return;
        }

        _enterCount++;
        EnterCount.Text = _enterCount.ToString(System.Globalization.CultureInfo.InvariantCulture);
        AutomationProperties.SetName(EnterCount, EnterCount.Text);
        e.Handled = true;
    }

    private void OnFocusChangesTextChanged(
        object sender,
        System.Windows.Controls.TextChangedEventArgs e)
    {
        if (_focusChangeObserved || string.IsNullOrEmpty(FocusChanges.Text))
        {
            return;
        }

        _focusChangeObserved = true;
        Search.Focus();
        Keyboard.Focus(Search);
    }
}

public sealed class HarnessDocumentBox : RichTextBox
{
    internal string PlainText
    {
        get => new TextRange(Document.ContentStart, Document.ContentEnd)
            .Text
            .TrimEnd('\r', '\n');
        set
        {
            Document.Blocks.Clear();
            Document.Blocks.Add(new Paragraph(new Run(value)));
        }
    }

    protected override AutomationPeer OnCreateAutomationPeer() =>
        new HarnessDocumentBoxAutomationPeer(this);
}

internal sealed class HarnessDocumentBoxAutomationPeer(HarnessDocumentBox owner)
    : RichTextBoxAutomationPeer(owner), IValueProvider
{
    bool IValueProvider.IsReadOnly => owner.IsReadOnly || !owner.IsEnabled;

    string IValueProvider.Value => owner.PlainText;

    public override object? GetPattern(PatternInterface patternInterface) =>
        patternInterface == PatternInterface.Value
            ? this
            : base.GetPattern(patternInterface);

    void IValueProvider.SetValue(string value)
    {
        if (((IValueProvider)this).IsReadOnly)
        {
            throw new InvalidOperationException("The document composer is read-only.");
        }

        owner.PlainText = value;
    }

    protected override string GetClassNameCore() => "RichTextBox";
}
