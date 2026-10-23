using Microsoft.Win32;

namespace Nearclip.App.Platform;

/// <summary>"Open at login" through the per-user Run key.</summary>
internal static class Startup
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string ValueName = "Nearclip";

    public static string ExePath => Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "Nearclip.exe");

    public static bool IsEnabled
    {
        get
        {
            try
            {
                return Registry.CurrentUser.OpenSubKey(RunKey)?.GetValue(ValueName) is string s &&
                       s.Contains(ExePath, StringComparison.OrdinalIgnoreCase);
            }
            catch (Exception) { return false; }
        }
    }

    public static bool Set(bool on)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (on) key.SetValue(ValueName, $"\"{ExePath}\" --background");
            else key.DeleteValue(ValueName, throwOnMissingValue: false);
            return true;
        }
        catch (Exception e)
        {
            Log.Write("startup registration failed: " + e.Message);
            return false;
        }
    }
}
