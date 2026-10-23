using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;

namespace Nearclip.App.Platform;

/// <summary>Window plumbing shared by all Nearclip windows: DPI, placement, backdrop, theme, icon.</summary>
internal static class WindowHelper
{
    public static IntPtr Hwnd(Window w) => WinRT.Interop.WindowNative.GetWindowHandle(w);

    public static double Scale(Window w) => Native.Dpi(Hwnd(w)) / 96.0;

    public static void SetIcon(Window w) =>
        w.AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Nearclip.ico"));

    public static void UseBackdrop(Window w, bool preferMica = true)
    {
        if (preferMica && MicaController.IsSupported()) w.SystemBackdrop = new MicaBackdrop { Kind = MicaKind.Base };
        else if (DesktopAcrylicController.IsSupported()) w.SystemBackdrop = new DesktopAcrylicBackdrop();
    }

    /// <summary>Applies the app theme (system / light / dark) to the window content, frame and caption buttons.</summary>
    public static void ApplyTheme(Window w, ElementTheme theme)
    {
        if (w.Content is FrameworkElement root) root.RequestedTheme = theme;
        // The custom always-active Mica (toast, pair prompt) does not re-tint reliably while its window is hidden:
        // give it a fresh controller, which reads the new theme when it connects.
        if (w.SystemBackdrop is Nearclip.App.Controls.ActiveMicaBackdrop) w.SystemBackdrop = new Nearclip.App.Controls.ActiveMicaBackdrop();
        var dark = theme == ElementTheme.Dark || (theme == ElementTheme.Default && !SystemTheme.AppsAreLight);
        var value = dark ? 1 : 0;
        Native.DwmSetWindowAttribute(Hwnd(w), Native.DWMWA_USE_IMMERSIVE_DARK_MODE, ref value, sizeof(int));
        if (AppWindowTitleBar.IsCustomizationSupported() && w.AppWindow.TitleBar.ExtendsContentIntoTitleBar)
        {
            var tb = w.AppWindow.TitleBar;
            tb.ButtonBackgroundColor = Colors.Transparent;
            tb.ButtonInactiveBackgroundColor = Colors.Transparent;
            tb.ButtonForegroundColor = dark ? Colors.White : Colors.Black;
            tb.ButtonInactiveForegroundColor = dark ? ColorHelper.FromArgb(0x80, 0xFF, 0xFF, 0xFF) : ColorHelper.FromArgb(0x80, 0, 0, 0);
            tb.ButtonHoverBackgroundColor = dark ? ColorHelper.FromArgb(0x18, 0xFF, 0xFF, 0xFF) : ColorHelper.FromArgb(0x10, 0, 0, 0);
            tb.ButtonHoverForegroundColor = dark ? Colors.White : Colors.Black;
            tb.ButtonPressedBackgroundColor = dark ? ColorHelper.FromArgb(0x10, 0xFF, 0xFF, 0xFF) : ColorHelper.FromArgb(0x0A, 0, 0, 0);
        }
    }

    public static void SetCorner(Window w, int preference)
    {
        var v = preference;
        Native.DwmSetWindowAttribute(Hwnd(w), Native.DWMWA_WINDOW_CORNER_PREFERENCE, ref v, sizeof(int));
    }

    /// <summary>Work area (physical pixels) of the monitor that contains the cursor.</summary>
    public static Native.RECT WorkAreaAtCursor()
    {
        Native.GetCursorPos(out var pt);
        return Native.MonitorInfoFor(pt).rcWork;
    }

    public static Native.RECT WorkAreaFor(Window w)
    {
        var mi = new Native.MONITORINFO { cbSize = Marshal.SizeOf<Native.MONITORINFO>() };
        Native.GetMonitorInfo(Native.MonitorFromWindow(Hwnd(w), Native.MONITOR_DEFAULTTONEAREST), ref mi);
        return mi.rcWork;
    }

    /// <summary>Centers a window of the given logical size on the work area of the cursor's monitor, clamped to fit.</summary>
    public static void CenterOnScreen(Window w, double width, double height)
    {
        var area = WorkAreaAtCursor();
        var scale = Native.Dpi(Hwnd(w)) / 96.0;
        var pw = (int)Math.Min(width * scale, area.Width * 0.96);
        var ph = (int)Math.Min(height * scale, area.Height * 0.96);
        w.AppWindow.MoveAndResize(new RectInt32(area.Left + (area.Width - pw) / 2, area.Top + (area.Height - ph) / 2, pw, ph));
    }

    public static void BringToFront(Window w)
    {
        var h = Hwnd(w);
        if (!w.AppWindow.IsVisible) w.AppWindow.Show();
        if (w.AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } p) p.Restore();
        w.Activate();
        Native.SetForegroundWindow(h);
    }

    public static void SetToolWindow(Window w, bool noActivate)
    {
        var h = Hwnd(w);
        var ex = Native.GetWindowLongPtr(h, Native.GWL_EXSTYLE).ToInt64();
        ex |= Native.WS_EX_TOOLWINDOW;
        if (noActivate) ex |= Native.WS_EX_NOACTIVATE;
        Native.SetWindowLongPtr(h, Native.GWL_EXSTYLE, new IntPtr(ex));
    }
}
