using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Nearclip.App.Controls;
using Nearclip.App.Model;
using Nearclip.App.Platform;
using Nearclip.Core;
using Windows.System;
using Windows.UI.Core;

namespace Nearclip.App.Views;

/// <summary>Builds the five settings pages (General, Devices, Privacy, History, About) from Windows 11 setting cards.</summary>
internal sealed class SettingsPages
{
    readonly SettingsWindow _window;
    StackPanel? _members;
    StackPanel? _remote;
    TextBlock? _address, _firewallState, _clipCount, _pinCount;
    Button? _firewallButton, _leaveButton, _clearButton;
    SettingsCard? _firewallCard, _selfCard;
    InfoBar? _restartBar;

    static AppHost Host => AppHost.Current;
    static AppModel Model => AppHost.Current.Model;
    static AppSettings S => AppHost.Current.Settings;

    public SettingsPages(SettingsWindow window) => _window = window;

    public void Detach() { }

    static Style St(string key) => Themed.Style(key);

    public FrameworkElement Build(string page) => page switch
    {
        "devices" => Devices(),
        "privacy" => Privacy(),
        "history" => History(),
        "about" => About(),
        _ => General(),
    };

    public void OnModelChanged(string page, ModelChange change)
    {
        if (page == "devices" && (change & (ModelChange.Members | ModelChange.Online | ModelChange.Network | ModelChange.Identity | ModelChange.Settings)) != 0)
            RefreshDevices();
        if (page == "general" && (change & (ModelChange.Remote | ModelChange.Settings)) != 0) RefreshRemote();
        if (page == "history" && change.HasFlag(ModelChange.History)) RefreshCounts();
    }

    // ------------------------------------------------------------------ building blocks

    static StackPanel Page(string title)
    {
        var p = new StackPanel { Spacing = 4 };
        p.Children.Add(new TextBlock { Text = title, Style = (Style)Application.Current.Resources["PageTitleStyle"] });
        return p;
    }

    static TextBlock Section(string title) => new() { Text = title, Style = (Style)Application.Current.Resources["SectionHeaderStyle"] };

    static SettingsCard Card(string glyph, string header, string description = "", object? content = null) =>
        new() { Glyph = glyph, Header = header, Description = description, Content = content };

    /// <summary>"On ◯" toggle like Windows Settings (label left of the switch).</summary>
    static FrameworkElement Toggle(bool value, Action<bool> changed, string name, bool enabled = true)
    {
        var label = new TextBlock { Text = Loc.S(value ? "On" : "Off"), VerticalAlignment = VerticalAlignment.Center, Style = St("TextSecondary") };
        var sw = new ToggleSwitch { IsOn = value, OnContent = "", OffContent = "", MinWidth = 0, IsEnabled = enabled };
        AutomationProperties.SetName(sw, name);
        sw.Toggled += (_, _) =>
        {
            label.Text = Loc.S(sw.IsOn ? "On" : "Off");
            changed(sw.IsOn);
        };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        row.Children.Add(label);
        row.Children.Add(sw);
        return row;
    }

    ContentDialog Dialog(string title, string body, string primary)
    {
        return new ContentDialog
        {
            XamlRoot = _window.DialogRoot,
            RequestedTheme = ((FrameworkElement)_window.Content).ActualTheme,
            Title = title,
            Content = new TextBlock { Text = body, TextWrapping = TextWrapping.WrapWholeWords },
            PrimaryButtonText = primary,
            CloseButtonText = Loc.S("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
    }

    // ------------------------------------------------------------------ General

    FrameworkElement General()
    {
        var p = Page(Loc.S("Page_General"));
        p.Children.Add(Section(Loc.S("ThisPC")));
        var name = new TextBox { Text = Model.DeviceName, Width = 260, MaxLength = 64 };
        AutomationProperties.SetName(name, Loc.S("Gen_Name"));
        name.LostFocus += (_, _) => Model.Rename(name.Text);
        name.KeyDown += (_, e) => { if (e.Key == VirtualKey.Enter) Model.Rename(name.Text); };
        p.Children.Add(Card("\uE7F4", Loc.S("Gen_Name"), Loc.S("Gen_NameBody"), name));

        p.Children.Add(Section(Loc.S("Gen_Sync")));
        p.Children.Add(Card("\uE769", Loc.S("PauseSyncing"), Loc.S("Gen_PauseBody"), Toggle(S.Paused, Model.SetPaused, Loc.S("PauseSyncing"))));
        p.Children.Add(Card("\uE8C8", Loc.S("Gen_AutoApply"), Loc.S("Gen_AutoApplyBody"),
            Toggle(S.AutoApply, v => { S.AutoApply = v; Model.SaveSettings(); }, Loc.S("Gen_AutoApply"))));
        p.Children.Add(Card("\uE91B", Loc.S("Gen_SyncImages"), Loc.S("Gen_SyncImagesBody"), Toggle(S.SyncImages, Model.SetSyncImages, Loc.S("Gen_SyncImages"))));

        if (Model.RemoteAvailable)
        {
            p.Children.Add(Section(Loc.S("Remote_Section")));
            p.Children.Add(Card("\uE774", Loc.S("Remote_Toggle"), Loc.S("Remote_Body"),
                Toggle(S.RemoteEnabled, v => Model.SetRemoteEnabled(v), Loc.S("Remote_Toggle"))));
            _remote = new StackPanel { Spacing = 4 };
            p.Children.Add(_remote);
            RefreshRemote();
        }

        p.Children.Add(Section("Windows"));
        p.Children.Add(Card("\uE7E8", Loc.S("Gen_OpenAtLogin"), Loc.S("Gen_OpenAtLoginBody"), Toggle(Startup.IsEnabled, v => Startup.Set(v), Loc.S("Gen_OpenAtLogin"))));
        p.Children.Add(ShortcutCard());
        p.Children.Add(Card("\uEA8F", Loc.S("Gen_Toasts"), Loc.S("Gen_ToastsBody"),
            Toggle(S.ShowToasts, v => { S.ShowToasts = v; Model.SaveSettings(); }, Loc.S("Gen_Toasts"))));
        p.Children.Add(Card("\uE77F", Loc.S("Gen_Paste"), Loc.S("Gen_PasteBody"),
            Toggle(S.PasteAfterChoosing, v => { S.PasteAfterChoosing = v; Model.SaveSettings(); }, Loc.S("Gen_Paste"))));

        p.Children.Add(Section(Loc.S("Gen_Appearance")));
        var theme = new ComboBox { MinWidth = 220 };
        theme.Items.Add(Loc.S("Gen_ThemeSystem"));
        theme.Items.Add(Loc.S("Gen_ThemeLight"));
        theme.Items.Add(Loc.S("Gen_ThemeDark"));
        theme.SelectedIndex = S.Theme switch { "light" => 1, "dark" => 2, _ => 0 };
        AutomationProperties.SetName(theme, Loc.S("Gen_Theme"));
        theme.SelectionChanged += (_, _) =>
        {
            S.Theme = theme.SelectedIndex switch { 1 => "light", 2 => "dark", _ => "system" };
            Model.SaveSettings();
            Host.ApplyTheme();
        };
        p.Children.Add(Card("\uE790", Loc.S("Gen_Theme"), "", theme));
        var lang = new ComboBox { MinWidth = 220 };
        lang.Items.Add(Loc.S("Gen_LangSystem"));
        lang.Items.Add("English");
        lang.Items.Add("한국어");
        lang.SelectedIndex = S.Language switch { "en-US" => 1, "ko-KR" => 2, _ => 0 };
        AutomationProperties.SetName(lang, Loc.S("Gen_Language"));
        _restartBar = new InfoBar { IsClosable = false, IsOpen = false, Severity = InfoBarSeverity.Informational, Message = Loc.S("Gen_RestartNeeded"), Margin = new Thickness(0, 4, 0, 0) };
        var restart = new Button { Content = Loc.S("Gen_RestartNow") };
        restart.Click += (_, _) => Host.Restart("--show settings:general");
        _restartBar.ActionButton = restart;
        lang.SelectionChanged += (_, _) =>
        {
            S.Language = lang.SelectedIndex switch { 1 => "en-US", 2 => "ko-KR", _ => "" };
            Model.SaveSettings();
            _restartBar.IsOpen = true;
        };
        p.Children.Add(Card("\uF2B7", Loc.S("Gen_Language"), "", lang));
        p.Children.Add(_restartBar);
        return p;
    }

    SettingsCard ShortcutCard()
    {
        var button = new Button { MinWidth = 160, Content = Host.HotKeyText };
        var card = Card("\uE765", Loc.S("Gen_Shortcut"), Host.HotKeyRegistered ? Loc.S("Gen_ShortcutBody") : Loc.S("Gen_ShortcutTaken"), button);
        var recording = false;
        button.Click += (_, _) =>
        {
            recording = true;
            Host.SuspendHotKey();
            button.Content = Loc.S("Gen_TypeShortcut");
        };
        void Stop()
        {
            if (!recording) return;
            recording = false;
            Host.ResumeHotKey();
            button.Content = Host.HotKeyText;
        }
        button.LostFocus += (_, _) => Stop();
        button.PreviewKeyDown += (_, e) =>
        {
            if (!recording) return;
            e.Handled = true;
            if (e.Key == VirtualKey.Escape) { Stop(); return; }
            bool Down(VirtualKey k) => (InputKeyboardSource.GetKeyStateForCurrentThread(k) & CoreVirtualKeyStates.Down) == CoreVirtualKeyStates.Down;
            uint mods = 0;
            if (Down(VirtualKey.Control)) mods |= Native.MOD_CONTROL;
            if (Down(VirtualKey.Menu)) mods |= Native.MOD_ALT;
            if (Down(VirtualKey.Shift)) mods |= Native.MOD_SHIFT;
            if (Down(VirtualKey.LeftWindows) || Down(VirtualKey.RightWindows)) mods |= Native.MOD_WIN;
            var key = e.Key;
            if (key is VirtualKey.Control or VirtualKey.Menu or VirtualKey.Shift or VirtualKey.LeftWindows or VirtualKey.RightWindows
                or VirtualKey.LeftControl or VirtualKey.RightControl or VirtualKey.LeftMenu or VirtualKey.RightMenu or VirtualKey.LeftShift or VirtualKey.RightShift)
            {
                button.Content = HotKeyService.Describe(mods, 0).Replace(" + " + HotKeyService.KeyName(0), " + …");
                return;
            }
            if (mods == 0 || mods == Native.MOD_SHIFT) return;
            recording = false;
            var ok = Host.SetHotKey(mods, (uint)key);
            button.Content = Host.HotKeyText;
            card.Description = ok ? Loc.S("Gen_ShortcutBody") : Loc.S("Gen_ShortcutTaken");
        };
        return card;
    }

    /// <summary>Remote-connection status and actions (DESIGN.md §4.7).</summary>
    void RefreshRemote()
    {
        if (_remote is null) return;
        _remote.Children.Clear();
        if (!S.RemoteEnabled) return;
        var st = Model.Tailnet;
        string title;
        var description = "";
        var tone = "IconSecondary";
        var busy = false;
        Button? action = null;
        var signOut = false;
        if (S.Paused)
        {
            // Pausing stops the remote connection with everything else; it starts again when syncing resumes.
            title = Loc.S("Remote_Paused");
            description = Loc.S("Remote_PausedHint");
        }
        else if (st.IsRunning)
        {
            title = st.Account is { Length: > 0 } acct ? Loc.F("Remote_OnAccount", acct) : Loc.S("Remote_On");
            description = (st.Ip is { } ip ? Loc.F("Remote_ThisDevice", ip) + "\n" : "") + Loc.S("Remote_Hint");
            tone = "IconOnline";
            signOut = true;
        }
        else if (st.State == "needsLogin")
        {
            title = Loc.S(Model.TailnetSigningIn ? "Remote_Waiting" : "Remote_NeedsLogin");
            tone = "IconWarning";
            busy = Model.TailnetSigningIn;
            action = new Button { Content = Loc.S("Remote_SignIn"), Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
            action.Click += async (_, _) => await Model.SignInToTailscaleAsync();
        }
        else if (st.State == "needsApproval")
        {
            title = Loc.S("Remote_NeedsApproval");
            tone = "IconWarning";
            signOut = true;
        }
        else if (st.State == "error")
        {
            title = Loc.F("Remote_Error", st.Error ?? "");
            tone = "IconError";
            action = new Button { Content = Loc.S("Remote_Retry") };
            action.Click += (_, _) => Model.RetryRemote();
        }
        else
        {
            title = Loc.S("Remote_Starting");
            busy = true;
        }
        if (signOut)
        {
            action = new Button { Content = Loc.S("Remote_SignOut") };
            action.Click += (_, _) => Model.SignOutOfTailscale();
        }
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, VerticalAlignment = VerticalAlignment.Center };
        if (busy) content.Children.Add(new ProgressRing { IsActive = true, Width = 18, Height = 18 });
        if (action is not null) content.Children.Add(action);
        var card = Card("\uE774", title, description, content);
        card.GlyphStyle = St(tone);
        AutomationProperties.SetAutomationId(card, "remote.status");
        _remote.Children.Add(card);
    }

    // ------------------------------------------------------------------ Devices

    FrameworkElement Devices()
    {
        var p = Page(Loc.S("Page_Devices"));
        p.Children.Add(Section(Loc.S("ThisPC")));
        var rename = new Button { Content = Loc.S("Rename_Ellipsis") };
        rename.Click += async (_, _) =>
        {
            var box = new TextBox { Text = Model.DeviceName, MaxLength = 64, SelectionStart = 0, SelectionLength = Model.DeviceName.Length };
            var d = Dialog(Loc.S("Rename_Title"), "", Loc.S("Rename"));
            d.Content = box;
            d.DefaultButton = ContentDialogButton.Primary;
            if (await d.ShowAsync() == ContentDialogResult.Primary) Model.Rename(box.Text);
        };
        _selfCard = Card("\uE7F4", Model.DeviceName, "", rename);
        p.Children.Add(_selfCard);
        _address = new TextBlock { IsTextSelectionEnabled = true, Style = St("TextSecondary"), VerticalAlignment = VerticalAlignment.Center };
        p.Children.Add(Card("\uE968", Loc.S("Dev_Address"), Loc.S("Dev_AddressBody"), _address));
        _firewallState = new TextBlock { VerticalAlignment = VerticalAlignment.Center, FontWeight = FontWeights.SemiBold };
        _firewallButton = new Button { Content = Loc.S("Firewall_Allow"), Visibility = Visibility.Collapsed };
        _firewallButton.Click += async (_, _) =>
        {
            _firewallButton.IsEnabled = false;
            await Task.Run(() => Firewall.RequestAllow(Startup.ExePath));
            _firewallButton.IsEnabled = true;
            await RefreshFirewall();
        };
        var fw = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        fw.Children.Add(_firewallState);
        fw.Children.Add(_firewallButton);
        _firewallCard = Card("\uEA18", Loc.S("Firewall_Title"), Loc.S("Firewall_Body"), fw);
        p.Children.Add(_firewallCard);

        var header = new Grid { Margin = new Thickness(0, 22, 0, 6) };
        header.Children.Add(new TextBlock { Text = Loc.S("MyDevices"), Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"], VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(1, 0, 0, 0) });
        var add = new Button { Style = (Style)Application.Current.Resources["AccentButtonStyle"], HorizontalAlignment = HorizontalAlignment.Right };
        var addContent = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        addContent.Children.Add(new FontIcon { Glyph = "\uE710", FontSize = 12 });
        addContent.Children.Add(new TextBlock { Text = Loc.S("AddDevice_Ellipsis") });
        add.Content = addContent;
        add.Click += (_, _) => Host.ShowAddDevice();
        header.Children.Add(add);
        p.Children.Add(header);
        _members = new StackPanel { Spacing = 4 };
        p.Children.Add(_members);

        p.Children.Add(Section(Loc.S("Advanced")));
        _leaveButton = new Button { Content = Loc.S("Dev_LeaveButton") };
        _leaveButton.Click += async (_, _) =>
        {
            var d = Dialog(Loc.S("Dev_LeaveConfirmTitle"), Loc.S("Dev_LeaveConfirmBody"), Loc.S("Dev_Leave"));
            if (await d.ShowAsync() == ContentDialogResult.Primary) Model.LeaveGroup();
        };
        p.Children.Add(Card("\uE89B", Loc.S("Dev_LeaveTitle"), Loc.S("Dev_LeaveBody"), _leaveButton));
        RefreshDevices();
        _ = RefreshFirewall();
        return p;
    }

    void RefreshDevices()
    {
        if (_members is null) return;
        if (_selfCard is not null)
        {
            _selfCard.Header = Model.DeviceName + "  ·  " + Loc.S("ThisPC");
            var me = Model.Me;
            _selfCard.Description = "Windows PC" + (me?.Model is { Length: > 0 } m ? " · " + m : "");
        }
        if (_address is not null)
        {
            var addr = Model.Addresses.FirstOrDefault();
            _address.Text = addr is not null && Model.Port > 0 ? Loc.F("Add_Address", addr, Model.Port) : (S.Paused ? Loc.S("Status_Paused") : "—");
        }
        _members.Children.Clear();
        var others = Model.OtherMembers.OrderBy(m => Model.IsOnline(m.Id) ? 0 : 1).ThenBy(m => m.AddedAt).ToList();
        if (others.Count == 0)
        {
            _members.Children.Add(Card("\uE8EA", Loc.S("Dev_EmptyTitle"), Loc.S("Dev_EmptyBody")));
        }
        foreach (var m in others) _members.Children.Add(MemberRow(m));
        if (Model.SuggestsRemote)
        {
            var link = new HyperlinkButton { Content = Loc.S("Remote_Suggest"), Margin = new Thickness(0, 4, 0, 0) };
            link.Click += (_, _) => _window.Navigate("general");
            _members.Children.Add(link);
        }
        if (_leaveButton is not null) _leaveButton.IsEnabled = others.Count > 0;
    }

    FrameworkElement MemberRow(MemberRecord m)
    {
        var online = Model.IsOnline(m.Id) && !S.Paused;
        var g = new Grid { Padding = new Thickness(16, 12, 10, 12), ColumnSpacing = 14, MinHeight = 64 };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var tile = new Border { Width = 36, Height = 36, CornerRadius = new CornerRadius(8), Style = St(online ? "TileIris" : "TileSubtle") };
        tile.Child = new FontIcon { Glyph = Format.PlatformGlyph(m.Platform, m.Model), FontSize = 17, FontFamily = (FontFamily)Application.Current.Resources["Icons"], Style = St(online ? "IconIris" : "IconSecondary") };
        g.Children.Add(tile);
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Spacing = 2 };
        text.Children.Add(new TextBlock { Text = m.Name.Length > 0 ? m.Name : Format.PlatformName(m.Platform, m.Model), FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
        var status = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        status.Children.Add(new Ellipse { Width = 7, Height = 7, Style = St(online ? "DotOnline" : "DotOffline"), VerticalAlignment = VerticalAlignment.Center });
        var statusText = online ? Model.ConnectionText(m.Id) : Format.LastSeen(Model.LastSeen.TryGetValue(m.Id, out var seen) ? seen : null);
        status.Children.Add(new TextBlock { Text = statusText, FontSize = 12, Style = St("TextSecondary") });
        if (online && Model.Route(m.Id) == PeerRoute.Remote)
            status.Children.Add(new FontIcon { Glyph = "\uE774", FontSize = 11, Style = St("IconOnline"), VerticalAlignment = VerticalAlignment.Center });
        text.Children.Add(status);
        Grid.SetColumn(text, 1);
        g.Children.Add(text);
        var platform = new TextBlock { Text = Format.PlatformName(m.Platform, m.Model), FontSize = 12, Style = St("TextTertiary"), VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(platform, 2);
        g.Children.Add(platform);
        var more = new Button { Style = (Style)Application.Current.Resources["SubtleIconButton"], Content = new FontIcon { Glyph = "\uE712", FontSize = 14 } };
        AutomationProperties.SetName(more, Loc.S("More") + " " + m.Name);
        var menu = new MenuFlyout();
        var sync = new MenuFlyoutItem { Text = Loc.S("SyncSettings_Title"), Icon = new FontIcon { Glyph = "\uE713" } };
        sync.Click += async (_, _) => {
            var policy = Model.Node.PolicyFor(m.Id);
            var panel = new StackPanel { Spacing = 12 };
            var send = new ToggleSwitch { Header = Loc.S("SyncPolicy_Send"), IsOn = policy.Send };
            var receive = new ToggleSwitch { Header = Loc.S("SyncPolicy_Receive"), IsOn = policy.Receive };
            var images = new ToggleSwitch { Header = Loc.S("SyncPolicy_Images"), IsOn = policy.Images };
            var codes = new ToggleSwitch { Header = Loc.S("SyncPolicy_Codes"), IsOn = policy.Codes };
            panel.Children.Add(send); panel.Children.Add(receive); panel.Children.Add(images); panel.Children.Add(codes);
            var dialog = new ContentDialog { XamlRoot = _window.DialogRoot, Title = m.Name, Content = panel,
                PrimaryButtonText = Loc.S("Save"), CloseButtonText = Loc.S("Cancel") };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary)
                Model.Node.SetPolicy(m.Id, new SyncPolicy(send.IsOn, receive.IsOn, images.IsOn, codes.IsOn));
        };
        menu.Items.Add(sync);
        var remove = new MenuFlyoutItem { Text = Loc.S("Remove_Ellipsis"), Icon = new FontIcon { Glyph = "\uE738" } };
        remove.Click += async (_, _) =>
        {
            var d = Dialog(Loc.F("Remove_Title", m.Name), Loc.S("Remove_Body"), Loc.S("Remove"));
            if (await d.ShowAsync() == ContentDialogResult.Primary) Model.Remove(m);
        };
        menu.Items.Add(remove);
        more.Flyout = menu;
        Grid.SetColumn(more, 3);
        g.Children.Add(more);
        AutomationProperties.SetName(g, $"{m.Name}, {statusText}, {Format.PlatformName(m.Platform, m.Model)}");
        return new Border { Child = g, CornerRadius = new CornerRadius(4), Style = St("CardBorder"), ContextFlyout = menu };
    }

    async Task RefreshFirewall()
    {
        var status = await Task.Run(() => Firewall.Check(Startup.ExePath));
        if (_firewallState is null || _firewallButton is null || _firewallCard is null) return;
        var (text, style, showButton) = status.State switch
        {
            Firewall.State.Allowed => ("✓ " + Loc.S("Allowed"), "TextOnline", false),
            Firewall.State.Off => ("✓ " + Loc.S("Firewall_Off"), "TextOnline", false),
            Firewall.State.Blocked => (Loc.S("Firewall_Blocked"), "TextWarning", true),
            Firewall.State.NotAllowedYet => (Loc.S("Firewall_NotYet"), "TextWarning", true),
            _ => (Loc.S("Firewall_AskedWhenNeeded"), "TextSecondary", false),
        };
        _firewallState.Text = text;
        _firewallState.Style = St(style);
        _firewallButton.Visibility = showButton ? Visibility.Visible : Visibility.Collapsed;
        _firewallCard.Description = Firewall.Describe(status);
    }

    // ------------------------------------------------------------------ Privacy

    FrameworkElement Privacy()
    {
        var p = Page(Loc.S("Page_Privacy"));
        p.Children.Add(Section(Loc.S("Priv_PasswordManagers")));
        p.Children.Add(Card("\uE8D7", Loc.S("Priv_Skip"), Loc.S("Priv_SkipBody"), Toggle(true, _ => { }, Loc.S("Priv_Skip"), enabled: false)));
        p.Children.Add(Section(Loc.S("Priv_Ignore")));
        var list = new StackPanel { Spacing = 4 };
        void Rebuild()
        {
            list.Children.Clear();
            foreach (var app in S.IgnoredApps.ToList())
            {
                var remove = new Button { Style = (Style)Application.Current.Resources["SubtleIconButton"], Content = new FontIcon { Glyph = "\uE738", FontSize = 13 } };
                AutomationProperties.SetName(remove, Loc.S("Remove") + " " + app);
                ToolTipService.SetToolTip(remove, Loc.S("Remove"));
                remove.Click += (_, _) =>
                {
                    S.IgnoredApps.Remove(app);
                    Model.SaveSettings();
                    Rebuild();
                };
                list.Children.Add(Card("\uECAA", System.IO.Path.GetFileNameWithoutExtension(app), app, remove));
            }
            var add = new Button { Margin = new Thickness(0, 6, 0, 0) };
            var addContent = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            addContent.Children.Add(new FontIcon { Glyph = "\uE710", FontSize = 12 });
            addContent.Children.Add(new TextBlock { Text = Loc.S("Priv_AddApp") });
            add.Content = addContent;
            add.Click += async (_, _) =>
            {
                var picker = new Windows.Storage.Pickers.FileOpenPicker();
                WinRT.Interop.InitializeWithWindow.Initialize(picker, WindowHelper.Hwnd(_window));
                picker.FileTypeFilter.Add(".exe");
                picker.SuggestedStartLocation = Windows.Storage.Pickers.PickerLocationId.ComputerFolder;
                var file = await picker.PickSingleFileAsync();
                if (file is null || S.IgnoredApps.Contains(file.Name, StringComparer.OrdinalIgnoreCase)) return;
                S.IgnoredApps.Add(file.Name);
                Model.SaveSettings();
                Rebuild();
            };
            list.Children.Add(add);
        }
        Rebuild();
        p.Children.Add(list);
        p.Children.Add(Section(Loc.S("Priv_Encryption")));
        p.Children.Add(Card("\uE72E", Loc.S("Onb_E2eTitle"), Loc.S("Priv_EncryptionBody")));
        return p;
    }

    // ------------------------------------------------------------------ History

    FrameworkElement History()
    {
        var p = Page(Loc.S("Page_History"));
        var keep = new ComboBox { MinWidth = 180 };
        int[] days = [1, 7, 30, 0];
        keep.Items.Add(Loc.S("Hist_1Day"));
        keep.Items.Add(Loc.S("Hist_7Days"));
        keep.Items.Add(Loc.S("Hist_30Days"));
        keep.Items.Add(Loc.S("Hist_Forever"));
        keep.SelectedIndex = Math.Max(0, Array.IndexOf(days, S.RetentionDays));
        AutomationProperties.SetName(keep, Loc.S("Hist_Keep"));
        keep.SelectionChanged += (_, _) => Model.SetRetention(days[Math.Max(0, keep.SelectedIndex)]);
        p.Children.Add(Section(Loc.S("Page_History")));
        p.Children.Add(Card("\uE81C", Loc.S("Hist_Keep"), Loc.S("Hist_KeepBody"), keep));
        _clipCount = new TextBlock { Style = St("TextSecondary") };
        _pinCount = new TextBlock { Style = St("TextSecondary") };
        p.Children.Add(Card("\uE8C8", Loc.S("Hist_Clips"), "", _clipCount));
        p.Children.Add(Card("\uE840", Loc.S("Section_Pinned"), "", _pinCount));
        p.Children.Add(Section(Loc.S("Hist_ClearSection")));
        _clearButton = new Button { Content = Loc.S("Hist_ClearButton") };
        _clearButton.Click += async (_, _) =>
        {
            var d = Dialog(Loc.S("Hist_ClearConfirmTitle"), Loc.S("Hist_ClearConfirmBody"), Loc.S("Hist_ClearConfirm"));
            if (await d.ShowAsync() == ContentDialogResult.Primary) Model.ClearHistory();
        };
        p.Children.Add(Card("\uE74D", Loc.S("Hist_Clear"), Loc.S("Hist_ClearBody"), _clearButton));
        RefreshCounts();
        return p;
    }

    void RefreshCounts()
    {
        if (_clipCount is null || _pinCount is null || _clearButton is null) return;
        _clipCount.Text = Model.Items.Count.ToString("N0");
        _pinCount.Text = Model.Items.Count(i => i.Pinned).ToString("N0");
        _clearButton.IsEnabled = Model.Items.Count > 0;
    }

    // ------------------------------------------------------------------ About

    static FrameworkElement About()
    {
        var p = new StackPanel { Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 36, 0, 0) };
        p.Children.Add(new Image { Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri("ms-appx:///Assets/win-256.png")), Width = 96, Height = 96 });
        p.Children.Add(new TextBlock { Text = "Nearclip", FontSize = 28, FontWeight = FontWeights.Bold, HorizontalAlignment = HorizontalAlignment.Center });
        p.Children.Add(new TextBlock { Text = Loc.S("Tagline"), FontSize = 16, Style = St("TextSecondary"), HorizontalAlignment = HorizontalAlignment.Center });
        p.Children.Add(new TextBlock { Text = Loc.F("About_Version", AppHost.AppVersion), Style = St("TextTertiary"), HorizontalAlignment = HorizontalAlignment.Center });
        var chips = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 8, 0, 8) };
        foreach (var (glyph, text) in new[] { ("\uE8AB", Loc.S("About_Direct")), ("\uE72E", Loc.S("Onb_E2eTitle")) })
        {
            var chip = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 7 };
            chip.Children.Add(new FontIcon { Glyph = glyph, FontSize = 13, Style = St("IconIris") });
            chip.Children.Add(new TextBlock { Text = text, FontSize = 13 });
            chips.Children.Add(new Border { Child = chip, Padding = new Thickness(12, 6, 12, 6), CornerRadius = new CornerRadius(14), Style = St("ChipIris") });
        }
        p.Children.Add(chips);
        var licenses = new StackPanel { Spacing = 4, MinWidth = 420 };
        licenses.Children.Add(new TextBlock { Text = Loc.S("About_OpenSource"), Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"], Margin = new Thickness(1, 12, 0, 4) });
        foreach (var (name, license) in new[] { ("Windows App SDK / WinUI 3", "MIT"), (".NET", "MIT"), ("QRCoder", "MIT"),
                     ("Tailscale (tsnet)", "BSD-3-Clause"), ("wireguard-go", "MIT"), ("gVisor", "Apache-2.0"), ("Go, golang.org/x", "BSD-3-Clause") })
            licenses.Children.Add(Card("", name, "", new TextBlock { Text = license, Style = St("TextSecondary") }));
        // Every module inside the embedded Tailscale node with its license text (copied next to Nearclip.exe).
        var notices = System.IO.Path.Combine(AppContext.BaseDirectory, "THIRD_PARTY_NOTICES.txt");
        if (File.Exists(notices))
        {
            var link = new HyperlinkButton { Content = Loc.S("About_LicenseTexts"), Margin = new Thickness(-10, 4, 0, 0) };
            link.Click += (_, _) =>
            {
                try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(notices) { UseShellExecute = true }); }
                catch (Exception e) { Log.Write("open notices failed: " + e.Message); }
            };
            licenses.Children.Add(link);
        }
        p.Children.Add(licenses);
        p.Children.Add(new TextBlock { Text = "© 2026 ivLis Studio · MIT License", FontSize = 12, Style = St("TextTertiary"), HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 16, 0, 0) });
        return p;
    }
}
