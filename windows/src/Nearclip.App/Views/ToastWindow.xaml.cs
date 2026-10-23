using System.Numerics;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Input;
using Nearclip.App.Controls;
using Nearclip.App.Model;
using Nearclip.App.Platform;
using Nearclip.Core;
using Windows.Graphics;

namespace Nearclip.App.Views;

/// <summary>"Copied from iPhone": small borderless window above the tray, 2.5 s, hover keeps it, click opens history.</summary>
public sealed partial class ToastWindow : Window
{
    readonly DispatcherTimerLike _timer;
    bool _hover;

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

    internal void Show(StoredClip sc)
    {
        var model = AppHost.Current.Model;
        DeviceGlyph.Glyph = model.SourceGlyph(sc);
        TitleText.Text = Loc.F("Toast_CopiedFrom", model.SourceName(sc));
        var c = sc.Clip;
        ThumbBorder.Visibility = Visibility.Collapsed;
        if (c.IsImage)
        {
            PreviewText.Text = (c.W ?? 0) > 0 ? Loc.F("Toast_ImageSize", c.W!, c.H ?? 0) : Loc.S("Kind_Image");
            _ = LoadThumb(sc);
        }
        else
        {
            PreviewText.Text = Format.Preview(c.Text ?? "", 1);
        }
        AutomationProperties.SetName(Root, TitleText.Text + ". " + PreviewText.Text);
        var scale = Native.Dpi(WindowHelper.Hwnd(this)) / 96.0;
        var area = WindowHelper.WorkAreaAtCursor();
        int w = (int)(340 * scale), h = (int)(62 * scale), gap = (int)(12 * scale);
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
        _timer.Restart();
    }

    async Task LoadThumb(StoredClip sc)
    {
        var img = await Thumbnails.GetAsync(sc.Id, AppHost.Current.Node.BlobPath(sc.Id), 96);
        if (img is null) return;
        Thumb.Source = img;
        ThumbBorder.Visibility = Visibility.Visible;
    }

    void HideIfIdle()
    {
        if (_hover) { _timer.Restart(TimeSpan.FromSeconds(1)); return; }
        AppWindow.Hide();
    }

    void Root_PointerEntered(object sender, PointerRoutedEventArgs e) => _hover = true;

    void Root_PointerExited(object sender, PointerRoutedEventArgs e) => _hover = false;

    void Root_Tapped(object sender, TappedRoutedEventArgs e)
    {
        AppWindow.Hide();
        AppHost.Current.ToastClicked();
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
