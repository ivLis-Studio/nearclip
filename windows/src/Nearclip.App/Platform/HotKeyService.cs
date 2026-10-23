namespace Nearclip.App.Platform;

/// <summary>System-wide shortcut for the history flyout (default Win+Alt+V).</summary>
internal sealed class HotKeyService : IDisposable
{
    const int Id = 0x4E43;
    readonly MessageWindow _window;
    bool _registered;

    public event Action? Pressed;
    public bool IsRegistered => _registered;

    public HotKeyService(MessageWindow window)
    {
        _window = window;
        _window.HotKey += id => { if (id == Id) Pressed?.Invoke(); };
    }

    public bool Register(uint modifiers, uint vk)
    {
        Unregister();
        _registered = Native.RegisterHotKey(_window.Handle, Id, modifiers | Native.MOD_NOREPEAT, vk);
        if (!_registered) Log.Write($"hotkey {Describe(modifiers, vk)} is taken");
        return _registered;
    }

    public void Unregister()
    {
        if (_registered) Native.UnregisterHotKey(_window.Handle, Id);
        _registered = false;
    }

    public static string Describe(uint modifiers, uint vk)
    {
        var parts = new List<string>();
        if ((modifiers & Native.MOD_WIN) != 0) parts.Add("Win");
        if ((modifiers & Native.MOD_CONTROL) != 0) parts.Add("Ctrl");
        if ((modifiers & Native.MOD_ALT) != 0) parts.Add("Alt");
        if ((modifiers & Native.MOD_SHIFT) != 0) parts.Add("Shift");
        parts.Add(KeyName(vk));
        return string.Join(" + ", parts);
    }

    public static string KeyName(uint vk)
    {
        if (vk is >= 0x30 and <= 0x39 or >= 0x41 and <= 0x5A) return ((char)vk).ToString();
        if (vk is >= 0x70 and <= 0x87) return "F" + (vk - 0x6F);
        var scan = Native.MapVirtualKey(vk, 0);
        var buf = new char[64];
        var n = Native.GetKeyNameText((int)(scan << 16), buf, buf.Length);
        return n > 0 ? new string(buf, 0, n) : "0x" + vk.ToString("X2");
    }

    public void Dispose() => Unregister();
}
