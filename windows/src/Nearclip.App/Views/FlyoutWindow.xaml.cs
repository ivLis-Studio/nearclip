using System.Numerics;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Nearclip.App.Model;
using Nearclip.App.Platform;
using Windows.Graphics;
using Windows.System;
using Windows.UI.Core;

namespace Nearclip.App.Views;

/// <summary>The Win+V-style history flyout (DESIGN.md §5 Windows): 360 × 520, Mica, above the tray, closes on deactivate.</summary>
public sealed partial class FlyoutWindow : Window
{
    public const double LogicalWidth = 360, LogicalHeight = 520;

    readonly CollectionViewSource _cvs = new() { IsSourceGrouped = true };
    HistoryFilter _filter = HistoryFilter.All;
    string _query = "";
    List<ClipItem> _flat = [];
    IntPtr _previousForeground;
    bool _openedByShortcut;
    bool _busy;
    DateTime _shownAt;

    static AppHost Host => AppHost.Current;
    static AppModel Model => AppHost.Current.Model;

    public FlyoutWindow()
    {
        InitializeComponent();
        Title = "Nearclip";
        var presenter = OverlappedPresenter.Create();
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.IsAlwaysOnTop = true;
        presenter.SetBorderAndTitleBar(true, false);
        AppWindow.SetPresenter(presenter);
        AppWindow.IsShownInSwitchers = false;
        WindowHelper.SetIcon(this);
        WindowHelper.UseBackdrop(this);
        WindowHelper.SetCorner(this, Native.DWMWCP_ROUND);
        AppWindow.Closing += (_, e) => { e.Cancel = true; Hide(); };
        Activated += (_, e) =>
        {
            if (e.WindowActivationState == WindowActivationState.Deactivated && AppWindow.IsVisible && DateTime.UtcNow - _shownAt > TimeSpan.FromMilliseconds(300))
                Hide();
        };
        AutomationProperties.SetName(MoreButton, Loc.S("More"));
        ToolTipService.SetToolTip(MoreButton, Loc.S("More"));
        AutomationProperties.SetName(FooterAdd, Loc.S("AddDevice"));
        ToolTipService.SetToolTip(FooterAdd, Loc.S("AddDevice_Ellipsis"));
        ElementCompositionPreview.SetIsTranslationEnabled(Root, true);
        Model.Changed += OnModelChanged;
        Refresh();
    }

    public bool IsOpen => AppWindow.IsVisible;

    void OnModelChanged(ModelChange change)
    {
        if (change.HasFlag(ModelChange.History) || change.HasFlag(ModelChange.Members) || change == ModelChange.All) Refresh();
        else UpdateChrome();
    }

    // ------------------------------------------------------------------ show / hide

    /// <summary>Opens above the taskbar next to the tray icon (or toggles it closed).</summary>
    internal void ToggleNearTray(Native.RECT? icon)
    {
        if (AppWindow.IsVisible) { Hide(); return; }
        _openedByShortcut = false;
        _previousForeground = IntPtr.Zero;
        var scale = Native.Dpi(WindowHelper.Hwnd(this)) / 96.0;
        int w = (int)(LogicalWidth * scale), h = (int)(LogicalHeight * scale), gap = (int)(12 * scale);
        Native.POINT anchor;
        if (icon is { } r) anchor = new Native.POINT { X = (r.Left + r.Right) / 2, Y = (r.Top + r.Bottom) / 2 };
        else Native.GetCursorPos(out anchor);
        var area = Native.MonitorInfoFor(anchor).rcWork;
        h = Math.Min(h, area.Height - 2 * gap);
        var abd = new Native.APPBARDATA { cbSize = System.Runtime.InteropServices.Marshal.SizeOf<Native.APPBARDATA>() };
        Native.SHAppBarMessage(Native.ABM_GETTASKBARPOS, ref abd);
        int x, y;
        switch (abd.uEdge)
        {
            case Native.ABE_TOP:
                x = Math.Clamp(anchor.X - w / 2, area.Left + gap, area.Right - w - gap);
                y = area.Top + gap;
                break;
            case Native.ABE_LEFT:
                x = area.Left + gap;
                y = Math.Clamp(anchor.Y - h / 2, area.Top + gap, area.Bottom - h - gap);
                break;
            case Native.ABE_RIGHT:
                x = area.Right - w - gap;
                y = Math.Clamp(anchor.Y - h / 2, area.Top + gap, area.Bottom - h - gap);
                break;
            default:
                x = Math.Clamp(anchor.X - w / 2, area.Left + gap, area.Right - w - gap);
                y = area.Bottom - h - gap;
                break;
        }
        Present(new RectInt32(x, y, w, h), fromBelow: abd.uEdge != Native.ABE_TOP);
    }

    /// <summary>Opens centered on the active screen (global shortcut), remembering the app to paste into.</summary>
    public void ShowFromShortcut()
    {
        if (AppWindow.IsVisible) { Hide(); return; }
        _openedByShortcut = true;
        _previousForeground = Native.GetForegroundWindow();
        var area = WindowHelper.WorkAreaAtCursor();
        var scale = Native.Dpi(WindowHelper.Hwnd(this)) / 96.0;
        int w = (int)(LogicalWidth * scale), h = Math.Min((int)(LogicalHeight * scale), area.Height - (int)(24 * scale));
        Present(new RectInt32(area.Left + (area.Width - w) / 2, area.Top + (area.Height - h) / 2, w, h), fromBelow: false);
    }

    void Present(RectInt32 rect, bool fromBelow)
    {
        Search.Text = "";
        _query = "";
        Refresh();
        AppWindow.MoveAndResize(rect);
        _shownAt = DateTime.UtcNow;
        AppWindow.Show();
        Activate();
        Native.SetForegroundWindow(WindowHelper.Hwnd(this));
        Animate(fromBelow);
        Search.Focus(FocusState.Programmatic);
        SelectFirst();
    }

    void Animate(bool fromBelow)
    {
        var visual = ElementCompositionPreview.GetElementVisual(Root);
        if (!new Windows.UI.ViewManagement.UISettings().AnimationsEnabled)
        {
            visual.Opacity = 1;
            visual.Properties.InsertVector3("Translation", Vector3.Zero);
            return;
        }
        var compositor = visual.Compositor;
        var ease = compositor.CreateCubicBezierEasingFunction(new Vector2(0.1f, 0.9f), new Vector2(0.2f, 1f));
        var fade = compositor.CreateScalarKeyFrameAnimation();
        fade.InsertKeyFrame(0f, 0f);
        fade.InsertKeyFrame(1f, 1f, ease);
        fade.Duration = TimeSpan.FromMilliseconds(180);
        var slide = compositor.CreateVector3KeyFrameAnimation();
        slide.InsertKeyFrame(0f, new Vector3(0, fromBelow ? 14 : -10, 0));
        slide.InsertKeyFrame(1f, Vector3.Zero, ease);
        slide.Duration = TimeSpan.FromMilliseconds(220);
        visual.StartAnimation("Opacity", fade);
        visual.StartAnimation("Translation", slide);
    }

    public void Hide()
    {
        if (!AppWindow.IsVisible) return;
        AppWindow.Hide();
    }

    // ------------------------------------------------------------------ content

    void Refresh()
    {
        var selectedId = (List.SelectedItem as ClipItem)?.Id;
        var items = Model.Filtered(_filter, _query);
        var groups = new List<ClipGroup>();
        if (_filter != HistoryFilter.Pinned)
        {
            var pinned = items.Where(i => i.Pinned).ToList();
            if (pinned.Count > 0) groups.Add(new ClipGroup(Loc.S("Section_Pinned"), pinned));
            foreach (var day in items.Where(i => !i.Pinned).GroupBy(i => Format.DaySection(i.Clip.Clip.Ts)))
                groups.Add(new ClipGroup(day.Key, day));
        }
        else if (items.Count > 0)
        {
            groups.Add(new ClipGroup(Loc.S("Section_Pinned"), items));
        }
        _flat = groups.SelectMany(g => g).ToList();
        for (var i = 0; i < _flat.Count; i++) _flat[i].Index = i;
        _cvs.Source = groups;
        List.ItemsSource = _cvs.View;
        var keep = _flat.FirstOrDefault(i => i.Id == selectedId) ?? _flat.FirstOrDefault();
        if (keep is not null) List.SelectedItem = keep;

        var filtered = _query.Trim().Length > 0 || _filter != HistoryFilter.All;
        EmptyState.Visibility = _flat.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        List.Visibility = _flat.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        EmptyGlyph.Glyph = filtered ? "\uE721" : "\uE77F";
        EmptyTitle.Text = Loc.S(filtered ? "Empty_NoMatches" : "Empty_Title");
        EmptyBody.Text = Loc.S(filtered ? "Empty_TryDifferent" : "Empty_Body");
        EmptyAdd.Visibility = !filtered && !Model.OtherMembers.Any() ? Visibility.Visible : Visibility.Collapsed;
        UpdateChrome();
    }

    void UpdateChrome()
    {
        var paused = Model.Settings.Paused;
        StatusText.Text = Model.StatusLine;
        StatusDot.Style = Controls.Themed.Style(paused ? "DotWarning" : Model.ConnectedCount > 0 ? "DotOnline" : "DotOffline");
        FooterPauseGlyph.Glyph = paused ? "\uE768" : "\uE769";
        var pauseLabel = Loc.S(paused ? "Resume" : "PauseSyncing");
        ToolTipService.SetToolTip(FooterPause, pauseLabel);
        AutomationProperties.SetName(FooterPause, pauseLabel);
        MenuPause.Text = pauseLabel;
        MenuPauseGlyph.Glyph = paused ? "\uE768" : "\uE769";
        PausedBar.Title = Loc.S("Status_Paused");
        PausedBar.Message = Loc.S("Paused_Body");
        PausedBar.IsOpen = paused;
        if (Model.Notice is { } n)
        {
            NoticeBar.Message = n.Text;
            NoticeBar.Severity = n.Tone switch { NoticeTone.Warning => InfoBarSeverity.Warning, NoticeTone.Success => InfoBarSeverity.Success, _ => InfoBarSeverity.Informational };
            NoticeBar.IsOpen = true;
        }
        else
        {
            NoticeBar.IsOpen = false;
        }
        BuildDeviceStack();
    }

    void BuildDeviceStack()
    {
        DeviceStack.Children.Clear();
        var others = Model.OtherMembers.OrderBy(m => Model.IsOnline(m.Id) ? 0 : 1).ThenBy(m => m.AddedAt).ToList();
        DevicesButton.Visibility = others.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        foreach (var m in others.Take(4))
        {
            var on = Model.IsOnline(m.Id) && !Model.Settings.Paused;
            var avatar = new Grid { Width = 26, Height = 26 };
            avatar.Children.Add(new Ellipse { Style = Controls.Themed.Style(on ? "AvatarIris" : "AvatarSubtle"), StrokeThickness = 1 });
            avatar.Children.Add(new FontIcon
            {
                Glyph = Format.PlatformGlyph(m.Platform, m.Model),
                FontFamily = (FontFamily)Application.Current.Resources["Icons"],
                FontSize = 11,
                Style = Controls.Themed.Style(on ? "IconIris" : "IconSecondary"),
            });
            if (on)
            {
                avatar.Children.Add(new Ellipse
                {
                    Width = 9, Height = 9, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom,
                    Style = Controls.Themed.Style("DotOnlineRinged"),
                    StrokeThickness = 1.5,
                });
            }
            ToolTipService.SetToolTip(avatar, m.Name + " · " + (on ? Loc.S("Connected") : Format.LastSeen(Model.LastSeen.GetValueOrDefault(m.Id))));
            DeviceStack.Children.Add(avatar);
        }
        if (others.Count > 4)
        {
            var more = new Grid { Width = 26, Height = 26 };
            more.Children.Add(new Ellipse { Style = Controls.Themed.Style("AvatarSubtle"), StrokeThickness = 1 });
            more.Children.Add(new TextBlock { Text = "+" + (others.Count - 4), FontSize = 10, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
            DeviceStack.Children.Add(more);
        }
        AutomationProperties.SetName(DevicesButton, Model.StatusLine);
        ToolTipService.SetToolTip(DevicesButton, Model.StatusLine);
    }

    void SelectFirst()
    {
        if (_flat.Count > 0) List.SelectedItem = _flat[0];
    }

    void Move(int delta)
    {
        if (_flat.Count == 0) return;
        var i = List.SelectedItem is ClipItem cur ? _flat.IndexOf(cur) : -1;
        i = Math.Clamp(i + delta, 0, _flat.Count - 1);
        List.SelectedItem = _flat[i];
        List.ScrollIntoView(_flat[i]);
    }

    // ------------------------------------------------------------------ actions

    public async void CopyItem(ClipItem item)
    {
        if (_busy) return;
        _busy = true;
        try
        {
            List.SelectedItem = item;
            var pill = ElementCompositionPreview.GetElementVisual(CopiedPill);
            CopiedPill.Opacity = 1;
            pill.Opacity = 1;
            await Model.CopyAsync(item);
            await Task.Delay(new Windows.UI.ViewManagement.UISettings().AnimationsEnabled ? 420 : 150);
            CopiedPill.Opacity = 0;
            var paste = _openedByShortcut && Model.Settings.PasteAfterChoosing ? _previousForeground : IntPtr.Zero;
            Hide();
            if (paste != IntPtr.Zero) await Host.PasteIntoAsync(paste);
        }
        finally { _busy = false; }
    }

    void List_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is ClipItem item) CopyItem(item);
    }

    void Root_PreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var ctrl = (InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control) & CoreVirtualKeyStates.Down) == CoreVirtualKeyStates.Down;
        var inSearch = FocusManager.GetFocusedElement(Content.XamlRoot) is TextBox;
        var selected = List.SelectedItem as ClipItem;
        switch (e.Key)
        {
            case VirtualKey.Escape:
                Hide();
                break;
            case VirtualKey.Down:
                Move(1);
                break;
            case VirtualKey.Up:
                Move(-1);
                break;
            case VirtualKey.Enter:
                var target = selected ?? _flat.FirstOrDefault();
                if (target is not null) CopyItem(target);
                break;
            case VirtualKey.F when ctrl:
                Search.Focus(FocusState.Keyboard);
                break;
            case VirtualKey.P when ctrl:
                if (selected is not null) Model.TogglePin(selected);
                break;
            case VirtualKey.Delete or VirtualKey.Back when ctrl:
                if (selected is not null) Model.Delete(selected);
                break;
            case VirtualKey.Delete when !inSearch || _query.Length == 0:
                if (selected is not null) Model.Delete(selected);
                break;
            case >= VirtualKey.Number1 and <= VirtualKey.Number9 when ctrl:
                CopyIndex(e.Key - VirtualKey.Number1);
                break;
            case >= VirtualKey.NumberPad1 and <= VirtualKey.NumberPad9 when ctrl:
                CopyIndex(e.Key - VirtualKey.NumberPad1);
                break;
            default:
                return;
        }
        e.Handled = true;
    }

    void CopyIndex(int i)
    {
        if (i >= 0 && i < _flat.Count) CopyItem(_flat[i]);
    }

    void Search_TextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        _query = sender.Text ?? "";
        Refresh();
        SelectFirst();
    }

    void Filters_SelectionChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        var s = sender.SelectedItem;
        _filter = s == FilterText ? HistoryFilter.Text : s == FilterLinks ? HistoryFilter.Links : s == FilterImages ? HistoryFilter.Images :
            s == FilterPinned ? HistoryFilter.Pinned : HistoryFilter.All;
        Refresh();
        SelectFirst();
    }

    void AddDevice_Click(object sender, RoutedEventArgs e)
    {
        Hide();
        Host.ShowAddDevice();
    }

    void Pause_Click(object sender, RoutedEventArgs e) => Model.SetPaused(!Model.Settings.Paused);

    void Settings_Click(object sender, RoutedEventArgs e)
    {
        Hide();
        Host.ShowSettings("general");
    }

    void DevicesButton_Click(object sender, RoutedEventArgs e)
    {
        Hide();
        Host.ShowSettings("devices");
    }

    void Quit_Click(object sender, RoutedEventArgs e) => Host.Quit();
}
