using System.Numerics;
using Microsoft.UI.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Nearclip.App.Controls;
using Nearclip.App.Model;
using Nearclip.App.Platform;

namespace Nearclip.App.Views;

/// <summary>First launch (DESIGN.md §4.1): welcome, quick setup (Windows Firewall, shortcut, start at sign-in), add devices.</summary>
public sealed partial class OnboardingWindow : Window
{
    int _step;
    AddDeviceView? _add;
    Button? _firewallButton;
    TextBlock? _firewallStatus;
    TextBlock? _firewallDetail;

    static AppModel Model => AppHost.Current.Model;

    public OnboardingWindow()
    {
        InitializeComponent();
        Title = "Nearclip";
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);
        var presenter = OverlappedPresenter.CreateForDialog();
        AppWindow.SetPresenter(presenter);
        WindowHelper.SetIcon(this);
        WindowHelper.UseBackdrop(this);
        WindowHelper.CenterOnScreen(this, 640, 660);
        BuildFeatures();
        BuildChecks();
        Model.Changed += OnChanged;
        Closed += (_, _) =>
        {
            Model.Changed -= OnChanged;
            if (!Model.Settings.OnboardingDone)
            {
                Model.Settings.OnboardingDone = true;
                Model.SaveSettings();
            }
        };
        foreach (var s in new UIElement[] { Step0, Step1, Step2 }) ElementCompositionPreview.SetIsTranslationEnabled(s, true);
        Show(0, animate: false);
    }

    void OnChanged(ModelChange change)
    {
        if (_step == 2 && (change.HasFlag(ModelChange.Members) || change == ModelChange.All)) UpdateFooter();
    }

    static Style St(string key) => Nearclip.App.Controls.Themed.Style(key);

    static Grid Row(string glyph, string title, string detail, out TextBlock detailBlock, FrameworkElement? trailing = null)
    {
        var g = new Grid { ColumnSpacing = 14 };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var tile = new Border { Width = 38, Height = 38, CornerRadius = new CornerRadius(10), Style = St("TileIris"), VerticalAlignment = VerticalAlignment.Top };
        tile.Child = new FontIcon { Glyph = glyph, FontSize = 17, FontFamily = (FontFamily)Application.Current.Resources["Icons"], Style = St("IconIris") };
        g.Children.Add(tile);
        var text = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = title, FontSize = 14, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.WrapWholeWords });
        detailBlock = new TextBlock { Text = detail, FontSize = 13, Style = St("TextSecondary"), TextWrapping = TextWrapping.WrapWholeWords };
        text.Children.Add(detailBlock);
        Grid.SetColumn(text, 1);
        g.Children.Add(text);
        if (trailing is not null)
        {
            trailing.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(trailing, 2);
            g.Children.Add(trailing);
        }
        return g;
    }

    void BuildFeatures()
    {
        Features.Children.Add(Row("\uE701", Loc.S("Onb_LocalTitle"), Loc.S("Onb_LocalBody"), out _));
        Features.Children.Add(Row("\uE72E", Loc.S("Onb_E2eTitle"), Loc.S("Onb_E2eBody"), out _));
        Features.Children.Add(Row("\uE8B9", Loc.S("Onb_PlatformsTitle"), Loc.S("Onb_PlatformsBody"), out _));
    }

    Border Card(Grid content) => new()
    {
        Child = content, Padding = new Thickness(16, 14, 16, 14), CornerRadius = new CornerRadius(8),
        Style = St("CardBorder"),
    };

    void BuildChecks()
    {
        var fwTrailing = new StackPanel { Spacing = 6, HorizontalAlignment = HorizontalAlignment.Right };
        _firewallStatus = new TextBlock { FontSize = 13, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Right };
        _firewallButton = new Button { Content = Loc.S("Firewall_Allow"), Style = (Style)Application.Current.Resources["AccentButtonStyle"], Visibility = Visibility.Collapsed };
        _firewallButton.Click += async (_, _) =>
        {
            _firewallButton.IsEnabled = false;
            await Task.Run(() => Firewall.RequestAllow(Startup.ExePath));
            _firewallButton.IsEnabled = true;
            await RefreshFirewall();
        };
        fwTrailing.Children.Add(_firewallStatus);
        fwTrailing.Children.Add(_firewallButton);
        Checks.Children.Add(Card(Row("\uEA18", Loc.S("Firewall_Title"), Loc.S("Firewall_Body"), out _firewallDetail, fwTrailing)));
        Checks.Children.Add(Card(Row("\uE765", Loc.S("Gen_Shortcut"), Loc.F("Onb_ShortcutBody", AppHost.Current.HotKeyText), out _)));
        var login = new ToggleSwitch { IsOn = Startup.IsEnabled, OnContent = "", OffContent = "", MinWidth = 0 };
        login.Toggled += (_, _) => Startup.Set(login.IsOn);
        Checks.Children.Add(Card(Row("\uE7E8", Loc.S("Gen_OpenAtLogin"), Loc.S("Gen_OpenAtLoginBody"), out _, login)));
        _ = RefreshFirewall();
    }

    async Task RefreshFirewall()
    {
        var status = await Task.Run(() => Firewall.Check(Startup.ExePath));
        if (_firewallStatus is null || _firewallButton is null || _firewallDetail is null) return;
        switch (status.State)
        {
            case Firewall.State.Allowed:
            case Firewall.State.Off:
                _firewallStatus.Text = "✓ " + Loc.S("Allowed");
                _firewallStatus.Style = St("TextOnline");
                _firewallButton.Visibility = Visibility.Collapsed;
                break;
            case Firewall.State.Blocked:
                _firewallStatus.Text = Loc.S("Firewall_Blocked");
                _firewallStatus.Style = St("TextWarning");
                _firewallButton.Visibility = Visibility.Visible;
                break;
            case Firewall.State.NotAllowedYet:
                _firewallStatus.Text = "";
                _firewallButton.Visibility = Visibility.Visible;
                break;
            default:
                _firewallStatus.Text = Loc.S("Firewall_AskedWhenNeeded");
                _firewallStatus.Style = St("TextSecondary");
                _firewallButton.Visibility = Visibility.Collapsed;
                break;
        }
        _firewallDetail.Text = Firewall.Describe(status);
    }

    public void GoTo(int step) => Show(Math.Clamp(step, 0, 2), animate: true);

    void Show(int step, bool animate)
    {
        var forward = step >= _step;
        _step = step;
        Step0.Visibility = step == 0 ? Visibility.Visible : Visibility.Collapsed;
        Step1.Visibility = step == 1 ? Visibility.Visible : Visibility.Collapsed;
        Step2.Visibility = step == 2 ? Visibility.Visible : Visibility.Collapsed;
        if (step == 2 && _add is null)
        {
            _add = new AddDeviceView { Compact = true };
            AddHost.Children.Add(_add);
        }
        if (step == 1) _ = RefreshFirewall();
        UpdateFooter();
        if (animate && new Windows.UI.ViewManagement.UISettings().AnimationsEnabled)
        {
            var target = step switch { 0 => (UIElement)Step0, 1 => Step1, _ => Step2 };
            var v = ElementCompositionPreview.GetElementVisual(target);
            var comp = v.Compositor;
            var ease = comp.CreateCubicBezierEasingFunction(new Vector2(0.1f, 0.9f), new Vector2(0.2f, 1f));
            var slide = comp.CreateVector3KeyFrameAnimation();
            slide.InsertKeyFrame(0, new Vector3(forward ? 40 : -40, 0, 0));
            slide.InsertKeyFrame(1, Vector3.Zero, ease);
            slide.Duration = TimeSpan.FromMilliseconds(240);
            var fade = comp.CreateScalarKeyFrameAnimation();
            fade.InsertKeyFrame(0, 0);
            fade.InsertKeyFrame(1, 1, ease);
            fade.Duration = TimeSpan.FromMilliseconds(200);
            v.StartAnimation("Translation", slide);
            v.StartAnimation("Opacity", fade);
        }
    }

    void UpdateFooter()
    {
        BackButton.Visibility = _step > 0 ? Visibility.Visible : Visibility.Collapsed;
        NextButton.Content = _step switch
        {
            0 => Loc.S("GetStarted"),
            1 => Loc.S("Continue"),
            _ => Model.OtherMembers.Any() ? Loc.S("Done") : Loc.S("SkipForNow"),
        };
        Dots.Children.Clear();
        for (var i = 0; i < 3; i++)
        {
            Dots.Children.Add(new Rectangle
            {
                Width = i == _step ? 18 : 7, Height = 7, RadiusX = 3.5, RadiusY = 3.5,
                Style = St(i == _step ? "PagerActive" : "PagerInactive"),
            });
        }
    }

    void Back_Click(object sender, RoutedEventArgs e) => Show(Math.Max(0, _step - 1), animate: true);

    void Next_Click(object sender, RoutedEventArgs e)
    {
        if (_step < 2) { Show(_step + 1, animate: true); return; }
        Model.Settings.OnboardingDone = true;
        Model.SaveSettings();
        Close();
    }
}
