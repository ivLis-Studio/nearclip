using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Nearclip.App.Model;
using Nearclip.Core;

namespace Nearclip.App.Views;

/// <summary>The numeric-comparison ContentDialogs: joiner ("Confirm on ‘Mac’", progress, success / failure) and
/// inviter ("Add ‘Pixel 9’?" with Decline / Add).</summary>
internal sealed class PairingDialogs
{
    readonly FrameworkElement _host;
    ContentDialog? _join;
    ContentDialog? _prompt;
    PairPrompt? _promptShown;
    JoinPhase _joinShown = JoinPhase.Idle;

    static AppModel Model => AppHost.Current.Model;

    public PairingDialogs(FrameworkElement host) => _host = host;

    static Style St(string key) => Nearclip.App.Controls.Themed.Style(key);

    public static FrameworkElement CodeDigits(string code)
    {
        var text = new TextBlock { Text = Format.GroupedCode(code), Style = (Style)Application.Current.Resources["CodeDigitsStyle"] };
        AutomationProperties.SetName(text, Loc.F("Pair_CodeAccessible", string.Join(" ", code.ToCharArray())));
        return new Border
        {
            Child = text,
            Padding = new Thickness(24, 8, 24, 10),
            CornerRadius = new CornerRadius(12),
            Style = St("TileIris"),
            HorizontalAlignment = HorizontalAlignment.Center,
        };
    }

    static StackPanel Centered(params UIElement[] children)
    {
        var s = new StackPanel { Spacing = 12, HorizontalAlignment = HorizontalAlignment.Stretch, MinWidth = 300 };
        foreach (var c in children) s.Children.Add(c);
        return s;
    }

    static TextBlock Heading(string text) => new()
    {
        Text = text, FontSize = 20, FontWeight = FontWeights.SemiBold, TextAlignment = TextAlignment.Center,
        HorizontalAlignment = HorizontalAlignment.Center, TextWrapping = TextWrapping.WrapWholeWords,
    };

    static TextBlock Body(string text) => new()
    {
        Text = text, FontSize = 14, Style = St("TextSecondary"), TextAlignment = TextAlignment.Center,
        HorizontalAlignment = HorizontalAlignment.Center, TextWrapping = TextWrapping.WrapWholeWords, MaxWidth = 340,
    };

    static FrameworkElement BigIcon(string glyph, string style, double size = 52) => new FontIcon
    {
        Glyph = glyph, FontSize = size, FontFamily = (FontFamily)Application.Current.Resources["Icons"], Style = St(style),
        HorizontalAlignment = HorizontalAlignment.Center,
    };

    public static FrameworkElement DeviceBadge(string platform)
    {
        var g = new Grid { Width = 60, Height = 60, HorizontalAlignment = HorizontalAlignment.Center };
        g.Children.Add(new Microsoft.UI.Xaml.Shapes.Ellipse { Style = St("BadgeIris") });
        g.Children.Add(new FontIcon { Glyph = Format.PlatformGlyph(platform), FontSize = 26, FontFamily = (FontFamily)Application.Current.Resources["Icons"], Style = St("IconIris") });
        return g;
    }

    ContentDialog NewDialog()
    {
        var d = new ContentDialog { XamlRoot = _host.XamlRoot, RequestedTheme = _host.ActualTheme };
        return d;
    }

    // ------------------------------------------------------------------ joiner

    public void UpdateJoin()
    {
        var state = Model.Join;
        if (state.Phase == JoinPhase.Idle)
        {
            _joinShown = JoinPhase.Idle;
            _join?.Hide();
            _join = null;
            return;
        }
        if (_host.XamlRoot is null) return;
        var fresh = _join is null;
        _join ??= NewDialog();
        var d = _join;
        d.Title = null;
        d.PrimaryButtonText = "";
        d.CloseButtonText = "";
        d.DefaultButton = ContentDialogButton.None;
        switch (state.Phase)
        {
            case JoinPhase.Connecting:
                d.Content = Centered(new ProgressRing { IsActive = true, Width = 40, Height = 40, Margin = new Thickness(0, 8, 0, 4) },
                    Heading(Loc.F("Join_Connecting", state.Name)));
                d.CloseButtonText = Loc.S("Cancel");
                break;
            case JoinPhase.Confirm:
                var waiting = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center };
                waiting.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
                waiting.Children.Add(new TextBlock { Text = Loc.S("Join_Waiting"), FontSize = 13, Style = St("TextSecondary") });
                d.Content = Centered(Heading(Loc.F("Join_ConfirmTitle", state.Name)), Body(Loc.F("Join_ConfirmBody", state.Name)),
                    CodeDigits(state.Code), waiting);
                d.CloseButtonText = Loc.S("Cancel");
                break;
            case JoinPhase.Success:
                d.Content = Centered(BigIcon("\uEC61", "IconOnline"), Heading(Loc.S("Join_SuccessTitle")), Body(Loc.F("Join_SuccessBody", state.Name)));
                d.PrimaryButtonText = Loc.S("Done");
                d.DefaultButton = ContentDialogButton.Primary;
                break;
            case JoinPhase.Failed:
                d.Content = Centered(BigIcon("\uE7BA", "IconWarning", 40), Heading(Loc.S("Join_FailedTitle")), Body(AppModel.FailureText(state.Reason)));
                d.PrimaryButtonText = Loc.S("OK");
                d.DefaultButton = ContentDialogButton.Primary;
                break;
        }
        _joinShown = state.Phase;
        if (fresh)
        {
            d.Closed += (_, _) =>
            {
                if (_join != d) return;
                _join = null;
                if (Model.Join.IsBusy) Model.CancelJoin();
                else if (Model.Join.Phase != JoinPhase.Idle) Model.DismissJoin();
            };
            _prompt?.Hide();
            _ = ShowSafe(d);
        }
    }

    // ------------------------------------------------------------------ inviter

    public void ShowPrompt(PairPrompt p)
    {
        if (_host.XamlRoot is null || _promptShown == p) return;
        _prompt?.Hide();
        _promptShown = p;
        var d = NewDialog();
        _prompt = d;
        d.Content = Centered(DeviceBadge(p.Platform), Heading(Loc.F("Prompt_Title", p.Name)), Body(Loc.F("Prompt_Body", p.Name)), CodeDigits(p.Code));
        d.PrimaryButtonText = Loc.S("Add");
        d.CloseButtonText = Loc.S("Decline");
        d.DefaultButton = ContentDialogButton.Primary;
        d.PrimaryButtonClick += (_, _) => Model.AnswerPrompt(true);
        d.CloseButtonClick += (_, _) => Model.AnswerPrompt(false);
        d.Closed += (_, _) =>
        {
            if (_prompt == d) { _prompt = null; _promptShown = null; }
        };
        _ = ShowSafe(d);
    }

    public void HidePrompt()
    {
        _prompt?.Hide();
        _prompt = null;
        _promptShown = null;
    }

    static async Task ShowSafe(ContentDialog d)
    {
        try { await d.ShowAsync(); }
        catch (Exception e) { Platform.Log.Write("dialog: " + e.Message); }
    }
}
