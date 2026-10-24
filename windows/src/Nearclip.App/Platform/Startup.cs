using Microsoft.Win32;
using Windows.ApplicationModel;

namespace Nearclip.App.Platform;

/// <summary>"Open at login": the per-user Run key for the GitHub build, the package's startup task (NearclipStartup in
/// packaging\Package.appxmanifest) for the Microsoft Store edition.</summary>
internal static class Startup
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string ValueName = "Nearclip";
    const string TaskId = "NearclipStartup";

    public static string ExePath => Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "Nearclip.exe");

    /// <summary>Whether Nearclip turns itself on at login without asking (the GitHub build). The Store edition leaves
    /// its startup task off until the user turns it on in onboarding or Settings.</summary>
    public static bool EnableByDefault => !PackageInfo.IsPackaged;

    public static bool IsEnabled
    {
        get
        {
            if (PackageInfo.IsPackaged) return TaskState() is StartupTaskState.Enabled or StartupTaskState.EnabledByPolicy;
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
        if (PackageInfo.IsPackaged) return SetTask(on);
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

    // The startup task API is asynchronous; these run it off the UI thread and wait (it answers in milliseconds).
    static StartupTaskState? TaskState()
    {
        try { return Task.Run(async () => (await StartupTask.GetAsync(TaskId)).State).GetAwaiter().GetResult(); }
        catch (Exception e)
        {
            Log.Write("startup task unavailable: " + e.Message);
            return null;
        }
    }

    static bool SetTask(bool on)
    {
        try
        {
            return Task.Run(async () =>
            {
                var task = await StartupTask.GetAsync(TaskId);
                if (!on)
                {
                    task.Disable();
                    return true;
                }
                // DisabledByUser (Task Manager › Startup apps) or DisabledByPolicy can only be undone there.
                var state = await task.RequestEnableAsync();
                if (state is not (StartupTaskState.Enabled or StartupTaskState.EnabledByPolicy))
                    Log.Write("startup task stays " + state);
                return state is StartupTaskState.Enabled or StartupTaskState.EnabledByPolicy;
            }).GetAwaiter().GetResult();
        }
        catch (Exception e)
        {
            Log.Write("startup task change failed: " + e.Message);
            return false;
        }
    }
}

