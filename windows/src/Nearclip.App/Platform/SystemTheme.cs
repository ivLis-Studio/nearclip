using Microsoft.Win32;

namespace Nearclip.App.Platform;

internal static class SystemTheme
{
    const string Key = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";

    /// <summary>True when the taskbar / tray uses the light theme.</summary>
    public static bool TaskbarIsLight => Read("SystemUsesLightTheme", 0) == 1;

    public static bool AppsAreLight => Read("AppsUseLightTheme", 1) == 1;

    static int Read(string name, int fallback)
    {
        try { return Registry.CurrentUser.OpenSubKey(Key)?.GetValue(name) is int v ? v : fallback; }
        catch (Exception) { return fallback; }
    }
}
