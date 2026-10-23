using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Nearclip.App.Model;
using Nearclip.App.Platform;
using Nearclip.Core;

namespace Nearclip.App.Views;

/// <summary>Add device (DESIGN.md §4.2): QR code for phones on the left, nearby computers on the right,
/// connect by address / pasted link, and the numeric-comparison dialogs for both roles.</summary>
public sealed partial class AddDeviceView : UserControl
{
    Microsoft.UI.Dispatching.DispatcherQueueTimer? _tick;
    PairingDialogs? _dialogs;
    string? _renderedUri;
    bool _compact;

    static AppModel Model => AppHost.Current.Model;

    public AddDeviceView()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
        AutomationProperties.SetName(QrImage, Loc.S("Add_QrAccessible"));
    }

    public bool Compact
    {
        get => _compact;
        set
        {
            _compact = value;
            QrColumn.Width = new GridLength(value ? 270 : 300);
            QrHost.Width = QrHost.Height = value ? 190 : 210;
        }
    }

    void OnLoaded(object sender, RoutedEventArgs e)
    {
        _dialogs = new PairingDialogs(this);
        Model.Changed += OnChanged;
        Model.BeginAddDevice();
        _tick = DispatcherQueue.CreateTimer();
        _tick.Interval = TimeSpan.FromSeconds(1);
        _tick.Tick += (_, _) => UpdateCountdown();
        _tick.Start();
        Refresh(ModelChange.All);
        _ = CheckFirewall();
        if (Model.PairPrompt is { } p) _dialogs.ShowPrompt(p);
        if (Model.Join.Phase != JoinPhase.Idle) _dialogs.UpdateJoin();
    }

    void OnUnloaded(object sender, RoutedEventArgs e)
    {
        Model.Changed -= OnChanged;
        _tick?.Stop();
        Model.EndAddDevice();
        if (Model.Join.IsBusy) Model.CancelJoin();
        else if (Model.Join.Phase != JoinPhase.Idle) Model.DismissJoin(); // a finished result is not shown again later
    }

    void OnChanged(ModelChange change) => Refresh(change);

    void Refresh(ModelChange change)
    {
        if (change.HasFlag(ModelChange.Ticket) || change.HasFlag(ModelChange.Network)) RenderQr();
        if (change.HasFlag(ModelChange.Nearby)) RenderNearby();
        if (change.HasFlag(ModelChange.Network) || change == ModelChange.All)
        {
            var addr = Model.Addresses.FirstOrDefault();
            AddressLine.Text = addr is not null && Model.Port > 0 ? Loc.F("Add_Address", addr, Model.Port) : "";
            AddressLine.Visibility = AddressLine.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        if (change.HasFlag(ModelChange.Notice))
        {
            var success = Model.Notice is { Tone: NoticeTone.Success } n ? n.Text : null;
            SuccessText.Text = success ?? "";
            SuccessLine.Visibility = success is null ? Visibility.Collapsed : Visibility.Visible;
        }
        if (change.HasFlag(ModelChange.Join)) _dialogs?.UpdateJoin();
        if (change.HasFlag(ModelChange.Prompt))
        {
            if (Model.PairPrompt is { } p) _dialogs?.ShowPrompt(p);
            else _dialogs?.HidePrompt();
        }
        UpdateCountdown();
    }

    void RenderQr()
    {
        var uri = Model.Ticket?.Uri;
        QrProgress.IsActive = uri is null;
        QrProgress.Visibility = uri is null ? Visibility.Visible : Visibility.Collapsed;
        QrGlyph.Visibility = uri is null ? Visibility.Collapsed : Visibility.Visible;
        if (uri is null) { QrImage.Source = null; _renderedUri = null; return; }
        if (uri == _renderedUri) return;
        _renderedUri = uri;
        var scale = XamlRoot?.RasterizationScale ?? 1.0;
        var inner = (QrHost.Width - 22) * scale;
        var bmp = Controls.QrCode.Render(uri, (int)inner);
        QrImage.Source = bmp;
        QrImage.Width = bmp.PixelWidth / scale;
        QrImage.Height = bmp.PixelHeight / scale;
    }

    void UpdateCountdown()
    {
        if (Model.Ticket is not { } t) { Countdown.Text = ""; return; }
        var left = t.ExpiresAt - DateTimeOffset.UtcNow;
        if (left < TimeSpan.Zero) left = TimeSpan.Zero;
        Countdown.Text = Loc.F("Add_NewCode", $"{(int)left.TotalMinutes}:{left.Seconds:00}");
    }

    void RenderNearby()
    {
        NearbyList.Children.Clear();
        foreach (var d in Model.Nearby)
        {
            var row = new Grid { Padding = new Thickness(10, 8, 10, 8), ColumnSpacing = 10, CornerRadius = new CornerRadius(8), Style = Controls.Themed.Style("CardGrid") };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var tile = new Border { Width = 34, Height = 34, CornerRadius = new CornerRadius(8), Style = Controls.Themed.Style("TileIris") };
            tile.Child = new FontIcon { Glyph = Format.PlatformGlyph(d.Platform), FontFamily = (FontFamily)Application.Current.Resources["Icons"], FontSize = 16, Style = Controls.Themed.Style("IconIris") };
            row.Children.Add(tile);
            var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Spacing = 1 };
            var name = d.Name.Length > 0 ? d.Name : Format.PlatformName(d.Platform);
            text.Children.Add(new TextBlock { Text = name, FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
            text.Children.Add(new TextBlock
            {
                Text = d.PairingMode ? Loc.S("Add_ReadyToPair") : Format.PlatformName(d.Platform),
                FontSize = 12,
                Style = Controls.Themed.Style(d.PairingMode ? "TextOnline" : "TextSecondary"),
            });
            Grid.SetColumn(text, 1);
            row.Children.Add(text);
            var pair = new Button { Content = Loc.S("Pair"), VerticalAlignment = VerticalAlignment.Center };
            AutomationProperties.SetName(pair, Loc.S("Pair") + " " + name);
            var device = d;
            pair.Click += (_, _) => Model.PairWith(device);
            Grid.SetColumn(pair, 2);
            row.Children.Add(pair);
            NearbyList.Children.Add(row);
        }
        NearbyEmpty.Visibility = Model.Nearby.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        NearbyScroll.Visibility = Model.Nearby.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    async Task CheckFirewall()
    {
        var status = await Task.Run(() => Firewall.Check(Startup.ExePath));
        var problem = status.State is Firewall.State.Blocked or Firewall.State.NotAllowedYet;
        FirewallLinkText.Text = Loc.S("Firewall_AllowLink");
        AutomationProperties.SetName(FirewallLink, Loc.Plain(FirewallLinkText.Text));
        FirewallLink.Visibility = problem ? Visibility.Visible : Visibility.Collapsed;
    }

    async void FirewallLink_Click(object sender, RoutedEventArgs e)
    {
        await Task.Run(() => Firewall.RequestAllow(Startup.ExePath));
        await CheckFirewall();
    }

    void Address_TextChanged(object sender, TextChangedEventArgs e) =>
        PairAddressButton.IsEnabled = HostBox.Text.Trim().Length > 0 && int.TryParse(PortBox.Text.Trim(), out var p) && p is > 0 and < 65536;

    void Link_TextChanged(object sender, TextChangedEventArgs e) => JoinButton.IsEnabled = LinkBox.Text.Trim().Length > 0;

    /// <summary>Opens "Connect by address" and puts the cursor in the address box (tray menu / deep link).</summary>
    public void FocusAddress()
    {
        AddressExpander.IsExpanded = true;
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => HostBox.Focus(FocusState.Keyboard));
    }

    void Address_KeyDown(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs e)
    {
        if (e.Key != Windows.System.VirtualKey.Enter || !PairAddressButton.IsEnabled) return;
        e.Handled = true;
        PairAddress_Click(sender, e);
    }

    void Link_KeyDown(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs e)
    {
        if (e.Key != Windows.System.VirtualKey.Enter || !JoinButton.IsEnabled) return;
        e.Handled = true;
        Join_Click(sender, e);
    }

    void PairAddress_Click(object sender, RoutedEventArgs e)
    {
        if (int.TryParse(PortBox.Text.Trim(), out var port)) Model.PairWithAddress(HostBox.Text.Trim(), port);
    }

    void Join_Click(object sender, RoutedEventArgs e)
    {
        if (!Model.JoinLink(LinkBox.Text.Trim())) Model.FailJoin("bad_uri");
        else LinkBox.Text = "";
    }
}
