using System.Runtime.InteropServices;

namespace Nearclip.App.Platform;

/// <summary>Whether this copy runs with package identity: the Microsoft Store edition (MSIX) rather than the folder
/// from GitHub. The two differ only in how Windows integration is registered (Startup.cs, the nearclip: protocol and
/// the firewall rules, which the package manifest declares).</summary>
internal static class PackageInfo
{
    const int APPMODEL_ERROR_NO_PACKAGE = 15700;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    static extern int GetCurrentPackageFullName(ref int packageFullNameLength, char[]? packageFullName);

    public static bool IsPackaged { get; } = Detect();

    static bool Detect()
    {
        try
        {
            var length = 0;
            return GetCurrentPackageFullName(ref length, null) != APPMODEL_ERROR_NO_PACKAGE;
        }
        catch (Exception) { return false; }
    }

    /// <summary>True when Windows started the packaged app through its startup task (at sign-in).</summary>
    public static bool StartedAtSignIn()
    {
        if (!IsPackaged) return false;
        try
        {
            return Microsoft.Windows.AppLifecycle.AppInstance.GetCurrent().GetActivatedEventArgs().Kind ==
                   Microsoft.Windows.AppLifecycle.ExtendedActivationKind.StartupTask;
        }
        catch (Exception e)
        {
            Log.Write("activation kind unavailable: " + e.Message);
            return false;
        }
    }
}

