using System.Globalization;
using System.Numerics;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Nearclip.App.Controls;
using Nearclip.App.Model;
using Nearclip.App.Platform;
using Nearclip.Core;
using Windows.Graphics;

namespace Nearclip.App.Views;

/// <summary>"Copied from iPhone": small borderless window above the tray, 2.5 s, hover keeps it, click opens history.
/// For a large image it first shows "Receiving an image from iPhone…" with a progress bar (PROTOCOL.md §6.6) and turns
/// into "Copied from iPhone" in place when the image is in. A verification code from a phone (§6.7) asks "Copy it?"
/// with Copy and Not now, and waits for an answer.</summary>
public sealed partial class ToastWindow : Window
{
    enum Kind { None, Copied, Received, Transfer, Failed, Code }

    readonly DispatcherTimerLike _timer;
    bool _hover;
    Kind _kind;
    string? _transferId;
    /// <summary>A transfer the user clicked away: its progress no longer brings the toast back (its arrival still does).</summary>
    string? _dismissedTransfer;
    /// <summary>The code being offered.</summary>
    StoredClip? _code;

    /// <summary>A code waits for an answer: notices do not push it away (a newer code replaces it).</summary>
    bool CodeWaiting => _kind == Kind.Code && AppWindow.IsVisible;

    public ToastWindow()
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
        SystemBackdrop = new ActiveMicaBackdrop();
        WindowHelper.SetToolWindow(this, noActivate: true);
        WindowHelper.SetCorner(this, Native.DWMWCP_ROUND);
        ElementCompositionPreview.SetIsTranslationEnabled(Root, true);
        _timer = new DispatcherTimerLike(TimeSpan.FromSeconds(2.5), HideIfIdle);
    }

    /// <summary>A clip from another device was copied to the clipboard.</summary>
    internal void Show(StoredClip sc)
    {
        if (CodeWaiting) return;
        var model = AppHost.Current.Model;
        var c = sc.Clip;
        var detail = c.IsImage
            ? (c.W ?? 0) > 0 ? Loc.F("Toast_ImageSize", c.W!, c.H ?? 0) : Loc.S("Kind_Image")
            : Format.Preview(c.Text ?? "", 1);
        ShowClip(sc, Loc.F("Toast_CopiedFrom", model.SourceName(sc)), detail, Kind.Copied);
    }

    /// <summary>An image that was shown arriving is in history but was not copied (auto-copy off, or an older clip).</summary>
    internal void ShowReceived(StoredClip sc)
    {
        if (CodeWaiting) return;
        ShowClip(sc, Loc.F("Toast_ImageFrom", AppHost.Current.Model.SourceName(sc)), Loc.S("Toast_SavedToHistory"), Kind.Received);
    }

    /// <summary>A large image is on its way; stays up (no timer) until it is in or gone.</summary>
    internal void ShowTransfer(IncomingTransfer t)
    {
        if (t.Id == _dismissedTransfer || CodeWaiting) return;
        var model = AppHost.Current.Model;
        SetCodeLayout(false);
        SetIcon(model.DeviceGlyphOf(t.From), warning: false);
        TitleText.Text = Loc.F("Toast_Receiving", model.DeviceNameOf(t.From));
        PreviewText.Visibility = Visibility.Collapsed;
        ProgressRow.Visibility = Visibility.Visible;
        if (t.Fraction is { } f)
        {
            Progress.IsIndeterminate = false;
            Progress.Value = f * 1000;
            ProgressText.Text = ProgressLabel(t);
        }
        else
        {
            Progress.IsIndeterminate = true;
            ProgressText.Text = Loc.S("Toast_Preparing");
        }
        ThumbBorder.Visibility = Visibility.Visible;
        if (_transferId != t.Id)
        {
            Thumb.Source = null;
            ThumbPlaceholder.Visibility = Visibility.Visible;
        }
        _kind = Kind.Transfer;
        _transferId = t.Id;
        Present(TitleText.Text + ". " + ProgressText.Text, hideAfter: null);
    }

    /// <summary>The image shown arriving did not make it.</summary>
    internal void ShowFailed(IncomingTransfer t)
    {
        if (CodeWaiting) return;
        SetCodeLayout(false);
        SetIcon("\uE7BA", warning: true);
        TitleText.Text = Loc.S("Toast_ReceiveFailed");
        PreviewText.Text = Loc.F("Toast_CopyAgain", AppHost.Current.Model.DeviceNameOf(t.From));
        PreviewText.Visibility = Visibility.Visible;
        ProgressRow.Visibility = Visibility.Collapsed;
        ThumbBorder.Visibility = Visibility.Collapsed;
        _kind = Kind.Failed;
        _transferId = null;
        Present(TitleText.Text + ". " + PreviewText.Text, TimeSpan.FromSeconds(3.5));
    }

    /// <summary>"A verification code arrived from Junseo's iPhone. Copy it?" with the code in large digits. Goes
    /// after a minute, as codes expire; hovering keeps it.</summary>
    internal void ShowCode(StoredClip sc)
    {
        var model = AppHost.Current.Model;
        _code = sc;
        SetCodeLayout(true);
        SetIcon(model.SourceGlyph(sc), warning: false);
        TitleText.Text = Loc.F("Toast_CodeArrived", model.SourceName(sc));
        CodeText.Text = sc.Clip.Text ?? "";
        AutomationProperties.SetName(CodeText, string.Join(' ', (sc.Clip.Text ?? "").ToCharArray()));
        CopyButton.Content = Loc.S("Copy");
        NotNowButton.Content = Loc.S("Toast_NotNow");
        _kind = Kind.Code;
        _transferId = null;
        Present(TitleText.Text + " " + CodeText.Text, TimeSpan.FromSeconds(60), MeasureHeight());
    }

    /// <summary>Copy on a code offer: the code goes to this PC's clipboard, and the toast says so.</summary>
    async void CopyCode()
    {
        if (_code is not { } sc) return;
        _code = null;
        _kind = Kind.None;
        await AppHost.Current.Model.CopyCodeAsync(sc);
        Show(sc);
    }

    void Copy_Click(object sender, RoutedEventArgs e) => CopyCode();

    void NotNow_Click(object sender, RoutedEventArgs e)
    {
        _code = null;
        _timer.Stop();
        _kind = Kind.None;
        AppWindow.Hide();
    }

    void SetCodeLayout(bool code)
    {
        CodePanel.Visibility = code ? Visibility.Visible : Visibility.Collapsed;
        TitleText.MaxLines = code ? 2 : 1;
        TitleText.TextWrapping = code ? TextWrapping.WrapWholeWords : TextWrapping.NoWrap;
        IconGrid.VerticalAlignment = code ? VerticalAlignment.Top : VerticalAlignment.Center;
        if (!code) return;
        PreviewText.Visibility = Visibility.Collapsed;
        ProgressRow.Visibility = Visibility.Collapsed;
        ThumbBorder.Visibility = Visibility.Collapsed;
    }

    /// <summary>The height the content needs at the toast's width (the code offer's title can wrap).</summary>
    double MeasureHeight()
    {
        Root.Measure(new Windows.Foundation.Size(ToastWidth, double.PositiveInfinity));
        return Math.Max(62, Math.Ceiling(Root.DesiredSize.Height));
    }

    /// <summary>No image is arriving any more (and nothing else took the toast over).</summary>
    internal void HideTransfer()
    {
        if (_kind != Kind.Transfer) return;
        _timer.Stop();
        _kind = Kind.None;
        _transferId = null;
        AppWindow.Hide();
    }

    void ShowClip(StoredClip sc, string title, string detail, Kind kind)
    {
        var model = AppHost.Current.Model;
        SetCodeLayout(false);
        SetIcon(model.SourceGlyph(sc), warning: false);
        TitleText.Text = title;
        PreviewText.Text = detail;
        PreviewText.Visibility = Visibility.Visible;
        ProgressRow.Visibility = Visibility.Collapsed;
        var image = sc.Clip.IsImage;
        ThumbBorder.Visibility = image ? Visibility.Visible : Visibility.Collapsed;
        Thumb.Source = null;
        ThumbPlaceholder.Visibility = Visibility.Visible;
        if (image) _ = LoadThumb(sc);
        _kind = kind;
        _transferId = null;
        Present(title + ". " + detail, TimeSpan.FromSeconds(2.5));
    }

    void SetIcon(string glyph, bool warning)
    {
        DeviceGlyph.Glyph = glyph;
        AccentCircle.Visibility = warning ? Visibility.Collapsed : Visibility.Visible;
        WarningCircle.Visibility = warning ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>"3.1 / 8.0 MB": both in the unit of the total, so the numbers don't jump between units. Binary units
    /// like the history list (Format.Size) and File Explorer, so the toast and the flyout show the same size.</summary>
    static string ProgressLabel(IncomingTransfer t)
    {
        var culture = CultureInfo.CurrentUICulture;
        if (t.Total >= 1024 * 1024)
            return (t.Received / 1048576.0).ToString("0.0", culture) + " / " + (t.Total / 1048576.0).ToString("0.0", culture) + " MB";
        return (t.Received / 1024).ToString(culture) + " / " + Math.Max(1, t.Total / 1024).ToString(culture) + " KB";
    }

    const double ToastWidth = 340;

    void Present(string accessibleName, TimeSpan? hideAfter, double height = 62)
    {
        AutomationProperties.SetName(Root, accessibleName);
        var scale = Native.Dpi(WindowHelper.Hwnd(this)) / 96.0;
        var area = WindowHelper.WorkAreaAtCursor();
        int w = (int)(ToastWidth * scale), h = (int)(height * scale), gap = (int)(12 * scale);
        AppWindow.MoveAndResize(new RectInt32(area.Right - w - gap, area.Bottom - h - gap, w, h));
        if (!AppWindow.IsVisible)
        {
            AppWindow.Show(false);
            var v = ElementCompositionPreview.GetElementVisual(Root);
            if (new Windows.UI.ViewManagement.UISettings().AnimationsEnabled)
            {
                var comp = v.Compositor;
                var fade = comp.CreateScalarKeyFrameAnimation();
                fade.InsertKeyFrame(0, 0);
                fade.InsertKeyFrame(1, 1);
                fade.Duration = TimeSpan.FromMilliseconds(180);
                var slide = comp.CreateVector3KeyFrameAnimation();
                slide.InsertKeyFrame(0, new Vector3(0, 10, 0));
                slide.InsertKeyFrame(1, Vector3.Zero);
                slide.Duration = TimeSpan.FromMilliseconds(200);
                v.StartAnimation("Opacity", fade);
                v.StartAnimation("Translation", slide);
            }
        }
        Native.SetWindowPos(WindowHelper.Hwnd(this), Native.HWND_TOPMOST, 0, 0, 0, 0, Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE);
        if (hideAfter is { } d) _timer.Restart(d); else _timer.Stop();
    }

    async Task LoadThumb(StoredClip sc)
    {
        var img = await Thumbnails.GetAsync(sc.Id, AppHost.Current.Node.BlobPath(sc.Id), 96);
        if (img is null || _kind is Kind.Transfer or Kind.Failed or Kind.None) return;
        Thumb.Source = img;
        ThumbPlaceholder.Visibility = Visibility.Collapsed;
    }

    void HideIfIdle()
    {
        if (_hover) { _timer.Restart(TimeSpan.FromSeconds(1)); return; }
        _kind = Kind.None;
        _code = null;
        AppWindow.Hide();
    }

    void Root_PointerEntered(object sender, PointerRoutedEventArgs e) => _hover = true;

    void Root_PointerExited(object sender, PointerRoutedEventArgs e) => _hover = false;

    void Root_Tapped(object sender, TappedRoutedEventArgs e)
    {
        if (_kind == Kind.Code)
        {
            // Clicking a code offer anywhere but its buttons copies it, like Copy.
            if (!IsWithin(e.OriginalSource as DependencyObject, CodeButtons)) CopyCode();
            return;
        }
        if (_kind == Kind.Transfer) _dismissedTransfer = _transferId;
        _timer.Stop();
        _kind = Kind.None;
        AppWindow.Hide();
        AppHost.Current.ToastClicked();
    }

    static bool IsWithin(DependencyObject? node, DependencyObject container)
    {
        for (var n = node; n is not null; n = VisualTreeHelper.GetParent(n))
            if (ReferenceEquals(n, container)) return true;
        return false;
    }
}

/// <summary>One-shot timer on the UI thread that can be restarted.</summary>
internal sealed class DispatcherTimerLike
{
    readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _t;
    readonly TimeSpan _interval;

    public DispatcherTimerLike(TimeSpan interval, Action tick)
    {
        _interval = interval;
        _t = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread().CreateTimer();
        _t.IsRepeating = false;
        _t.Tick += (_, _) => tick();
    }

    public void Restart(TimeSpan? interval = null)
    {
        _t.Stop();
        _t.Interval = interval ?? _interval;
        _t.Start();
    }

    public void Stop() => _t.Stop();
}
