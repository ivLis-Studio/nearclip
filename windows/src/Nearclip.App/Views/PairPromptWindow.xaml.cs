using Microsoft.UI.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Nearclip.App.Controls;
using Nearclip.App.Model;
using Nearclip.App.Platform;
using Nearclip.Core;

namespace Nearclip.App.Views;

/// <summary>Inviter side of code pairing when no Add-device window is open: a small always-on-top window
/// "Add ‘Pixel 9’?" with the code and Decline / Add (DESIGN.md §4.2).</summary>
public sealed partial class PairPromptWindow : Window
{
    readonly PairPrompt _prompt;
    readonly bool _preview;
    bool _answered;
    bool _focused;

    internal PairPromptWindow(PairPrompt prompt, bool preview)
    {
        _prompt = prompt;
        _preview = preview;
        InitializeComponent();
        Title = Loc.Plain(Loc.F("Prompt_Title", prompt.Name)) + " — Nearclip";
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);
        var presenter = OverlappedPresenter.CreateForDialog();
        presenter.IsAlwaysOnTop = true;
        AppWindow.SetPresenter(presenter);
        WindowHelper.SetIcon(this);
        SystemBackdrop = new ActiveMicaBackdrop();
        Body.Children.Add(PairingDialogs.DeviceBadge(prompt.Platform));
        Body.Children.Add(new TextBlock
        {
            Text = Loc.F("Prompt_Title", prompt.Name), FontSize = 20, FontWeight = FontWeights.SemiBold,
            HorizontalAlignment = HorizontalAlignment.Center, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.WrapWholeWords,
        });
        Body.Children.Add(new TextBlock
        {
            Text = Loc.F("Prompt_Body", prompt.Name), FontSize = 14, Style = Themed.Style("TextSecondary"),
            HorizontalAlignment = HorizontalAlignment.Center, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.WrapWholeWords,
        });
        Body.Children.Add(PairingDialogs.CodeDigits(prompt.Code));
        DeclineButton.Content = Loc.S("Decline");
        AddButton.Content = Loc.S("Add");
        AppHost.Current.Model.OnPaired += OnPaired;
        Closed += (_, _) =>
        {
            AppHost.Current.Model.OnPaired -= OnPaired;
            if (!_answered && !_preview) AppHost.Current.Model.AnswerPrompt(false);
        };
        // Enter = Add (the accent button), Esc = Decline. The window's initial focus would otherwise land on the first
        // tab stop (Decline), so redirect it.
        Root.GettingFocus += (_, e) =>
        {
            if (_focused) return;
            _focused = true;
            if (!ReferenceEquals(e.NewFocusedElement, AddButton)) e.TrySetNewFocusedElement(AddButton);
        };
        Root.KeyDown += (_, e) =>
        {
            if (e.Key != Windows.System.VirtualKey.Escape || _answered) return;
            e.Handled = true;
            Decline_Click(DeclineButton, new RoutedEventArgs());
        };
    }

    public void Present()
    {
        WindowHelper.CenterOnScreen(this, 380, 392);
        WindowHelper.BringToFront(this);
        AddButton.Focus(FocusState.Keyboard);
    }

    /// <summary>The joiner gave up or the request timed out.</summary>
    public void Dismissed()
    {
        if (!_answered) { _answered = true; Close(); }
    }

    void OnPaired(string name, bool joined)
    {
        if (joined) return;
        Body.Children.Clear();
        Body.Children.Add(new FontIcon
        {
            Glyph = "\uEC61", FontSize = 52, FontFamily = (FontFamily)Application.Current.Resources["Icons"],
            Style = Themed.Style("IconOnline"), HorizontalAlignment = HorizontalAlignment.Center,
        });
        Body.Children.Add(new TextBlock
        {
            Text = Loc.F("Pair_Joined", name), FontSize = 16, FontWeight = FontWeights.SemiBold, TextAlignment = TextAlignment.Center,
            TextWrapping = TextWrapping.WrapWholeWords, HorizontalAlignment = HorizontalAlignment.Center,
        });
        Buttons.Visibility = Visibility.Collapsed;
        _ = Task.Delay(1800).ContinueWith(_ => DispatcherQueue.TryEnqueue(Close));
    }

    void Decline_Click(object sender, RoutedEventArgs e)
    {
        _answered = true;
        if (!_preview) AppHost.Current.Model.AnswerPrompt(false);
        Close();
    }

    void Add_Click(object sender, RoutedEventArgs e)
    {
        _answered = true;
        if (_preview) { OnPaired(_prompt.Name, false); return; }
        AddButton.IsEnabled = DeclineButton.IsEnabled = false;
        AppHost.Current.Model.AnswerPrompt(true);
    }
}
