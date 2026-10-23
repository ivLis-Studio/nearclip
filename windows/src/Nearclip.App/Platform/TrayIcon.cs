using System.Runtime.InteropServices;

namespace Nearclip.App.Platform;

/// <summary>Notification-area icon (light/dark glyph), left click / right click, tooltip and the 300 ms send pulse.</summary>
internal sealed class TrayIcon : IDisposable
{
    const uint CallbackMessage = Native.WM_APP + 1;
    const uint IconId = 1;

    readonly MessageWindow _window;
    readonly string _assets;
    IntPtr _normal, _pulse, _dimmed;
    bool _added;
    bool _paused;
    bool _pulsing;
    string _tip = "Nearclip";
    int _lastSize;

    public event Action? LeftClick;
    public event Action<int, int>? RightClick;

    public TrayIcon(MessageWindow window, string assetsDirectory)
    {
        _window = window;
        _assets = assetsDirectory;
        _window.Message += OnMessage;
        _window.TaskbarCreated += () => { _added = false; Add(); };
        _window.SettingsChanged += () => { LoadIcons(); Update(); };
        LoadIcons();
        Add();
    }

    int IconSize()
    {
        var dpi = (uint)Native.Dpi(_window.Handle);
        try { return Native.GetSystemMetricsForDpi(Native.SM_CXSMICON, dpi); }
        catch (EntryPointNotFoundException) { return 16 * (int)dpi / 96; }
    }

    void LoadIcons()
    {
        var size = IconSize();
        var light = SystemTheme.TaskbarIsLight;
        foreach (var h in new[] { _normal, _pulse, _dimmed }) if (h != IntPtr.Zero) Native.DestroyIcon(h);
        var file = Path.Combine(_assets, light ? "Tray-Light.ico" : "Tray-Dark.ico");
        _normal = Native.LoadImage(IntPtr.Zero, file, Native.IMAGE_ICON, size, size, Native.LR_LOADFROMFILE);
        // Pulse: the glyph in the accent colour (Iris for light taskbars, the lighter dark-mode accent otherwise).
        _pulse = IconTint.Recolor(_normal, light ? (byte)0x4C : (byte)0x8B, light ? (byte)0x5B : (byte)0x96, light ? (byte)0xF5 : (byte)0xFF, 1.0);
        _dimmed = IconTint.Recolor(_normal, null, null, null, 0.45);
        _lastSize = size;
    }

    Native.NOTIFYICONDATA Data(uint flags) => new()
    {
        cbSize = Marshal.SizeOf<Native.NOTIFYICONDATA>(),
        hWnd = _window.Handle,
        uID = IconId,
        uFlags = flags,
        uCallbackMessage = CallbackMessage,
        hIcon = CurrentIcon,
        szTip = _tip.Length > 127 ? _tip[..127] : _tip,
        szInfo = "",
        szInfoTitle = "",
    };

    IntPtr CurrentIcon => _pulsing && _pulse != IntPtr.Zero ? _pulse : (_paused && _dimmed != IntPtr.Zero ? _dimmed : _normal);

    void Add()
    {
        var nid = Data(Native.NIF_MESSAGE | Native.NIF_ICON | Native.NIF_TIP | Native.NIF_SHOWTIP);
        _added = Native.Shell_NotifyIcon(Native.NIM_ADD, ref nid);
        if (!_added)
        {
            // Explorer may still hold a stale icon from a previous run.
            Native.Shell_NotifyIcon(Native.NIM_DELETE, ref nid);
            _added = Native.Shell_NotifyIcon(Native.NIM_ADD, ref nid);
        }
        nid.uVersionOrTimeout = Native.NOTIFYICON_VERSION_4;
        Native.Shell_NotifyIcon(Native.NIM_SETVERSION, ref nid);
        if (!_added) Log.Write("tray icon could not be added");
    }

    void Update()
    {
        if (!_added) { Add(); return; }
        var nid = Data(Native.NIF_ICON | Native.NIF_TIP | Native.NIF_SHOWTIP);
        Native.Shell_NotifyIcon(Native.NIM_MODIFY, ref nid);
    }

    public void SetState(string tooltip, bool paused)
    {
        _tip = Nearclip.App.Model.Loc.Plain(tooltip);
        _paused = paused;
        if (IconSize() != _lastSize) LoadIcons();
        Update();
    }

    /// <summary>Brief accent tint when a clip is sent or received.</summary>
    public async void Pulse()
    {
        if (_paused || _pulsing) return;
        _pulsing = true;
        Update();
        await Task.Delay(300);
        _pulsing = false;
        Update();
    }

    /// <summary>Screen rectangle of the icon (physical pixels), if the shell reports it.</summary>
    public Native.RECT? Bounds()
    {
        var id = new Native.NOTIFYICONIDENTIFIER { cbSize = Marshal.SizeOf<Native.NOTIFYICONIDENTIFIER>(), hWnd = _window.Handle, uID = IconId };
        return Native.Shell_NotifyIconGetRect(ref id, out var r) == 0 && r.Width > 0 ? r : null;
    }

    void OnMessage(uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg != CallbackMessage) return;
        var ev = (uint)(lParam.ToInt64() & 0xFFFF);
        switch (ev)
        {
            case Native.NIN_SELECT:
            case Native.NIN_KEYSELECT:
                LeftClick?.Invoke();
                break;
            case Native.WM_CONTEXTMENU:
                var x = (short)(wParam.ToInt64() & 0xFFFF);
                var y = (short)((wParam.ToInt64() >> 16) & 0xFFFF);
                RightClick?.Invoke(x, y);
                break;
        }
    }

    /// <summary>Shows a native popup menu (follows the system light/dark mode) and returns the chosen id or 0.</summary>
    public uint ShowMenu(int x, int y, IReadOnlyList<(uint Id, string? Text, bool Enabled, bool Checked)> items)
    {
        var menu = Native.CreatePopupMenu();
        try
        {
            foreach (var (id, text, enabled, check) in items)
            {
                if (text is null) { Native.AppendMenu(menu, Native.MF_SEPARATOR, UIntPtr.Zero, null); continue; }
                var flags = Native.MF_STRING | (enabled ? 0 : Native.MF_GRAYED) | (check ? Native.MF_CHECKED : 0);
                Native.AppendMenu(menu, flags, (UIntPtr)id, text);
            }
            Native.SetForegroundWindow(_window.Handle);
            var chosen = Native.TrackPopupMenuEx(menu, Native.TPM_RIGHTBUTTON | Native.TPM_RETURNCMD | Native.TPM_NONOTIFY | Native.TPM_BOTTOMALIGN,
                x, y, _window.Handle, IntPtr.Zero);
            Native.PostMessage(_window.Handle, 0, IntPtr.Zero, IntPtr.Zero);
            return chosen;
        }
        finally { Native.DestroyMenu(menu); }
    }

    public void Dispose()
    {
        var nid = Data(0);
        Native.Shell_NotifyIcon(Native.NIM_DELETE, ref nid);
        foreach (var h in new[] { _normal, _pulse, _dimmed }) if (h != IntPtr.Zero) Native.DestroyIcon(h);
    }
}

/// <summary>Recolours / fades a 32-bit icon (used for the tray pulse and the paused state).</summary>
internal static class IconTint
{
    public static IntPtr Recolor(IntPtr icon, byte? r, byte? g, byte? b, double alphaScale)
    {
        if (icon == IntPtr.Zero || !Native.GetIconInfo(icon, out var info)) return IntPtr.Zero;
        var dc = Native.GetDC(IntPtr.Zero);
        try
        {
            var bmi = new Native.BITMAPINFOHEADER { biSize = Marshal.SizeOf<Native.BITMAPINFOHEADER>() };
            if (Native.GetDIBits(dc, info.hbmColor, 0, 0, null, ref bmi, 0) == 0) return IntPtr.Zero;
            int w = bmi.biWidth, h = Math.Abs(bmi.biHeight);
            bmi = new Native.BITMAPINFOHEADER
            {
                biSize = Marshal.SizeOf<Native.BITMAPINFOHEADER>(), biWidth = w, biHeight = -h, biPlanes = 1, biBitCount = 32, biCompression = 0,
            };
            var px = new byte[w * h * 4];
            if (Native.GetDIBits(dc, info.hbmColor, 0, (uint)h, px, ref bmi, 0) == 0) return IntPtr.Zero;
            for (var i = 0; i < px.Length; i += 4)
            {
                var a = px[i + 3];
                if (a == 0) continue;
                var na = (byte)Math.Clamp(a * alphaScale, 0, 255);
                if (r is { } rr && g is { } gg && b is { } bb)
                {
                    px[i] = (byte)(bb * na / 255);
                    px[i + 1] = (byte)(gg * na / 255);
                    px[i + 2] = (byte)(rr * na / 255);
                }
                else
                {
                    px[i] = (byte)(px[i] * na / Math.Max(1, (int)a));
                    px[i + 1] = (byte)(px[i + 1] * na / Math.Max(1, (int)a));
                    px[i + 2] = (byte)(px[i + 2] * na / Math.Max(1, (int)a));
                }
                px[i + 3] = na;
            }
            var color = Native.CreateDIBSection(dc, ref bmi, 0, out var bits, IntPtr.Zero, 0);
            if (color == IntPtr.Zero) return IntPtr.Zero;
            Marshal.Copy(px, 0, bits, px.Length);
            var mask = Native.CreateBitmap(w, h, 1, 1, IntPtr.Zero);
            var ii = new Native.ICONINFO { fIcon = true, hbmColor = color, hbmMask = mask };
            var result = Native.CreateIconIndirect(ref ii);
            Native.DeleteObject(color);
            Native.DeleteObject(mask);
            return result;
        }
        finally
        {
            Native.ReleaseDC(IntPtr.Zero, dc);
            if (info.hbmColor != IntPtr.Zero) Native.DeleteObject(info.hbmColor);
            if (info.hbmMask != IntPtr.Zero) Native.DeleteObject(info.hbmMask);
        }
    }
}
