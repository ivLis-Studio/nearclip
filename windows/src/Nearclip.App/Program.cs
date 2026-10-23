using System.Globalization;
using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Nearclip.App.Model;
using Nearclip.App.Platform;

namespace Nearclip.App;

/// <summary>Entry point: single instance (later launches forward their command line), language, then WinUI.</summary>
/// <remarks>
/// One instance per user and data directory, whatever folder Nearclip.exe runs from. (The Windows App SDK instance
/// key of an unpackaged app is scoped to the executable path, so two copies of the app could otherwise run side by
/// side on the same state.) The primary instance holds a named mutex; a later launch sends its arguments to the
/// primary's hidden window with WM_COPYDATA and exits.
/// </remarks>
public static class Program
{
    /// <summary>WM_COPYDATA tag of a forwarded command line ('NC').</summary>
    internal const int ForwardTag = 0x4E43;

    internal static string[] Args { get; private set; } = [];
    internal static AppSettings Settings { get; private set; } = null!;
    internal static string DataDirectory { get; private set; } = "";
    /// <summary>Instance key: names the mutex and the title of the hidden message window.</summary>
    internal static string InstanceKey { get; private set; } = "";

    static Mutex? s_instance;

    [STAThread]
    static int Main(string[] args)
    {
        Args = args;
        WinRT.ComWrappersSupport.InitializeComWrappers();
        DataDirectory = Environment.GetEnvironmentVariable("NEARCLIP_DATA") is { Length: > 0 } d
            ? d
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Nearclip");
        Directory.CreateDirectory(DataDirectory);
        Log.Init(Path.Combine(DataDirectory, "logs"));

        InstanceKey = MakeInstanceKey();
        // Restarting after a language change: wait for the previous instance to finish quitting.
        if (!TryBecomePrimary(args.Contains("--relaunch") ? TimeSpan.FromSeconds(10) : TimeSpan.Zero))
        {
            Forward(args);
            return 0;
        }

        Settings = AppSettings.Load(Path.Combine(DataDirectory, "settings.json"));
        var lang = LanguageArgument(args);
        if (lang is not null)
        {
            Settings.Language = lang == "system" ? "" : lang;
            Settings.Save();
        }
        ApplyLanguage(Settings.Language);

        Application.Start(p =>
        {
            var context = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            _ = new App();
        });
        return 0;
    }

    static string? LanguageArgument(string[] args)
    {
        var i = Array.IndexOf(args, "--lang");
        return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
    }

    /// <summary>One instance per user and data directory (string.GetHashCode is randomized per process, so hash explicitly).</summary>
    static string MakeInstanceKey()
    {
        var hash = System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(DataDirectory.ToLowerInvariant()));
        return "Nearclip." + Environment.UserName + "." + Convert.ToHexString(hash, 0, 6);
    }

    static bool TryBecomePrimary(TimeSpan wait)
    {
        s_instance = new Mutex(initiallyOwned: true, @"Local\" + InstanceKey, out var created);
        if (created) return true;
        try { return s_instance.WaitOne(wait); }
        catch (AbandonedMutexException) { return true; } // the previous instance ended without releasing it
    }

    static void ApplyLanguage(string language)
    {
        if (string.IsNullOrEmpty(language)) return;
        try
        {
            Microsoft.Windows.Globalization.ApplicationLanguages.PrimaryLanguageOverride = language;
            var culture = new CultureInfo(language);
            CultureInfo.DefaultThreadCurrentUICulture = culture;
            CultureInfo.DefaultThreadCurrentCulture = culture;
            CultureInfo.CurrentUICulture = culture;
            CultureInfo.CurrentCulture = culture;
        }
        catch (Exception e)
        {
            Log.Write("language override failed: " + e.Message);
        }
    }

    /// <summary>Sends this launch's arguments to the running instance (no arguments = open the history flyout).</summary>
    static void Forward(string[] args)
    {
        var payload = string.Join('\0', args.Length == 0 ? ["--show", "flyout"] : args);
        for (var attempt = 0; attempt < 50; attempt++)
        {
            // The primary may still be starting up: its window appears a moment after the mutex.
            var hwnd = Native.FindWindow(MessageWindow.ClassName, InstanceKey);
            if (hwnd != IntPtr.Zero)
            {
                // Let it bring its window to the front for --show / nearclip:// launches.
                Native.GetWindowThreadProcessId(hwnd, out var pid);
                Native.AllowSetForegroundWindow((int)pid);
                var text = Marshal.StringToHGlobalUni(payload);
                try
                {
                    var data = new Native.COPYDATASTRUCT { dwData = ForwardTag, cbData = (payload.Length + 1) * 2, lpData = text };
                    if (Native.SendMessageTimeout(hwnd, Native.WM_COPYDATA, IntPtr.Zero, ref data, Native.SMTO_ABORTIFHUNG, 10_000, out _) != IntPtr.Zero)
                        return;
                }
                finally { Marshal.FreeHGlobal(text); }
            }
            Thread.Sleep(100);
        }
        Log.Write("could not reach the running instance");
    }
}
