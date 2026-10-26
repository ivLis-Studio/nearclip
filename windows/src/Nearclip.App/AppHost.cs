using System.Diagnostics;
using System.Reflection;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Win32;
using Nearclip.App.Model;
using Nearclip.App.Platform;
using Nearclip.App.Views;
using Nearclip.Core;

namespace Nearclip.App;

/// <summary>Composition root: engine, settings, platform services and windows. UI thread.</summary>
internal sealed class AppHost
{
    public static AppHost Current { get; private set; } = null!;

    readonly MessageWindow _messages;
    readonly ClipboardService _clipboard;
    readonly TrayIcon _tray;
    readonly HotKeyService _hotkey;
    ToastWindow? _toast;
    SettingsWindow? _settingsWindow;
    AddDeviceWindow? _addDevice;
    OnboardingWindow? _onboarding;
    PairPromptWindow? _promptWindow;
    bool _quitting;

    public DispatcherQueue Dispatcher { get; }
    public AppSettings Settings { get; }
    public NearclipNode Node { get; }
    public AppModel Model { get; }
    public DnsSdDiscovery Discovery { get; }
    public FlyoutWindow? Flyout { get; private set; }
    public string DataDirectory { get; }
    public static string AppVersion => Assembly.GetExecutingAssembly().GetName().Version is { } v ? $"{v.Major}.{v.Minor}.{v.Build}" : "1.0.0";
    public bool HotKeyRegistered => _hotkey.IsRegistered;
    public string HotKeyText => HotKeyService.Describe(Settings.HotKeyModifiers, Settings.HotKeyKey);

    public ElementTheme Theme => Settings.Theme switch { "light" => ElementTheme.Light, "dark" => ElementTheme.Dark, _ => ElementTheme.Default };

    public AppHost(DispatcherQueue dispatcher, AppSettings settings, string dataDirectory)
    {
        Current = this;
        Dispatcher = dispatcher;
        Settings = settings;
        DataDirectory = dataDirectory;
        try { Native.SetPreferredAppMode(1); Native.FlushMenuThemes(); } catch (Exception) { /* menus stay light */ }
        Discovery = new DnsSdDiscovery();
        // Remote connection: embedded Tailscale node (nctailnet.dll next to the exe). NEARCLIP_TAILNET_CONTROL points it
        // at a test control server; NEARCLIP_TAILNET_LOG writes its verbose log.
        var tailnetControl = Environment.GetEnvironmentVariable("NEARCLIP_TAILNET_CONTROL");
#if DEBUG
        // Debug builds: %LOCALAPPDATA%\Nearclip\tailnet-control.txt does the same (the test VM cannot pass env vars to
        // the GUI session easily).
        var devControl = Path.Combine(dataDirectory, "tailnet-control.txt");
        if (string.IsNullOrEmpty(tailnetControl) && File.Exists(devControl)) tailnetControl = File.ReadAllText(devControl).Trim();
#endif
        var tailnet = new TailnetOptions(Path.Combine(dataDirectory, "tailnet"), tailnetControl,
            Environment.GetEnvironmentVariable("NEARCLIP_TAILNET_LOG"), TestMode: !string.IsNullOrEmpty(tailnetControl));
        Node = new NearclipNode(new NearclipNode.Options
        {
            StateDirectory = Path.Combine(dataDirectory, "state"),
            DeviceName = Environment.MachineName,
            Platform = "win",
            Model = DeviceModel(),
            AppVersion = AppVersion,
            Port = int.TryParse(Environment.GetEnvironmentVariable("NEARCLIP_PORT"), out var p) ? p : Wire.DefaultPort,
            SecretStore = new DpapiSecretStore(Path.Combine(dataDirectory, "state", "secrets")),
            Discovery = Discovery,
            Tailnet = tailnet,
        });
        Model = new AppModel(Node, settings, dispatcher);
        _messages = new MessageWindow(Program.InstanceKey);
        _messages.CommandLine += HandleArgs;
        _clipboard = new ClipboardService(_messages, dispatcher)
        {
            IsPaused = () => Settings.Paused,
            IgnoredApps = () => Settings.IgnoredApps,
            // Large images: the other devices show "Receiving…" while this PC encodes (PROTOCOL.md §6.6).
            ImageStarting = () => Model?.AnnounceImage(),
            ImageCancelled = id => Model?.CancelImage(id),
        };
        _clipboard.Copied += c => Model.LocalCopy(c);
        Model.WriteClipboard = (clip, blob) => _clipboard.WriteAsync(clip, blob);
        Model.OnReceive = ShowToast;
        Model.OnShownTransfer = t =>
        {
            if (t is not null) Toast()?.ShowTransfer(t);
            else _toast?.HideTransfer();
        };
        Model.OnReceivedQuietly = sc => Toast()?.ShowReceived(sc);
        Model.OnTransferFailed = t => Toast()?.ShowFailed(t);
        // A code waits for an answer, so it shows even with arrival notices off.
        Model.OnCode = sc => Toast(force: true)?.ShowCode(sc);
        Model.OnActivity = () => _tray?.Pulse();
        Model.OnPairPrompt = ShowPairPrompt;
        Model.Changed += OnModelChanged;
        _tray = new TrayIcon(_messages, Path.Combine(AppContext.BaseDirectory, "Assets"));
        _tray.LeftClick += () => Flyout?.ToggleNearTray(_tray.Bounds());
        _tray.RightClick += ShowTrayMenu;
        _hotkey = new HotKeyService(_messages);
        _hotkey.Pressed += () => Flyout?.ShowFromShortcut();
        _messages.SettingsChanged += () => { if (Settings.Theme == "system") ApplyTheme(); };
        // Wi-Fi changes, VPN up/down, wake from sleep: redial at once (PROTOCOL.md §4.5, §10.4).
        System.Net.NetworkInformation.NetworkChange.NetworkAddressChanged += (_, _) => OnNetworkChanged();
        System.Net.NetworkInformation.NetworkChange.NetworkAvailabilityChanged += (_, _) => OnNetworkChanged();
    }

    DispatcherQueueTimer? _networkTimer;

    void OnNetworkChanged() => Dispatcher.TryEnqueue(() =>
    {
        _networkTimer ??= Dispatcher.CreateTimer();
        _networkTimer.Interval = TimeSpan.FromSeconds(1);
        _networkTimer.IsRepeating = false;
        _networkTimer.Tick -= NetworkTimerTick;
        _networkTimer.Tick += NetworkTimerTick;
        _networkTimer.Stop();
        _networkTimer.Start();
    });

    void NetworkTimerTick(DispatcherQueueTimer sender, object args)
    {
        Log.Write("network changed");
        Node.NetworkChanged();
    }

    public void Start(string[] args)
    {
        Log.Write($"Nearclip {AppVersion} starting ({string.Join(' ', args)})");
        if (!PackageInfo.IsPackaged) RegisterLinkProtocol(); // the Store edition declares nearclip: in its manifest
        _hotkey.Register(Settings.HotKeyModifiers, Settings.HotKeyKey);
        Flyout = new FlyoutWindow();
        ApplyTheme();
        Model.Start();
        UpdateTray();
        if (!Settings.LoginItemInitialized)
        {
            if (Startup.EnableByDefault) Startup.Set(true);
            Settings.LoginItemInitialized = true;
            Settings.Save();
        }
        var background = args.Contains("--background") || PackageInfo.StartedAtSignIn();
        if (!Settings.OnboardingDone && !background && !args.Contains("--show")) ShowOnboarding();
        HandleArgs(args);
    }

    static string? DeviceModel()
    {
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey(@"HARDWARE\DESCRIPTION\System\BIOS");
            var product = key?.GetValue("SystemProductName") as string;
            return string.IsNullOrWhiteSpace(product) ? null : product.Trim();
        }
        catch (Exception) { return null; }
    }

    /// <summary>nearclip:// links (QR codes opened on this PC) start Nearclip and pair.</summary>
    static void RegisterLinkProtocol()
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(@"Software\Classes\nearclip");
            key.SetValue("", "URL:Nearclip pairing link");
            key.SetValue("URL Protocol", "");
            using var icon = key.CreateSubKey("DefaultIcon");
            icon.SetValue("", $"\"{Startup.ExePath}\",0");
            using var cmd = key.CreateSubKey(@"shell\open\command");
            cmd.SetValue("", $"\"{Startup.ExePath}\" \"%1\"");
        }
        catch (Exception e) { Log.Write("protocol registration failed: " + e.Message); }
    }

    /// <summary>Command line of this or a redirected second launch.</summary>
    public void HandleArgs(IReadOnlyList<string> args)
    {
        for (var i = 0; i < args.Count; i++)
        {
            var a = args[i];
            string? Next() => i + 1 < args.Count ? args[++i] : null;
            if (a.StartsWith("nearclip:", StringComparison.OrdinalIgnoreCase))
            {
                ShowAddDevice();
                if (!Model.JoinLink(a)) Model.FailJoin("bad_uri");
                continue;
            }
            switch (a)
            {
                case "--show":
                    Show(Next() ?? "flyout");
                    break;
                case "--theme":
                    Settings.Theme = Next() ?? "system";
                    Settings.Save();
                    ApplyTheme();
                    break;
                case "--quit":
                    Quit();
                    break;
                case "--login": // turn Open at login on or off (the Run key, or the startup task of the Store edition)
                    var on = Next() == "on";
                    var done = Startup.Set(on);
                    Log.Write("open at login " + (on ? "on" : "off") + ": " + (done ? "ok" : "failed") + ", now " + (Startup.IsEnabled ? "on" : "off") + (PackageInfo.IsPackaged ? " (startup task)" : " (Run key)"));
                    break;
            }
        }
    }

    void Show(string what)
    {
        var parts = what.Split(':', 2);
        switch (parts[0])
        {
            case "flyout": if (Flyout is { IsOpen: false }) Flyout.ToggleNearTray(_tray.Bounds()); break;
            case "shortcut": Flyout?.ShowFromShortcut(); break;
            case "settings": ShowSettings(parts.Length > 1 ? parts[1] : "general"); break;
            case "add":
                ShowAddDevice();
                if (parts.Length > 1 && parts[1] == "address") _addDevice?.AddView.FocusAddress();
                break;
            case "onboarding": ShowOnboarding(parts.Length > 1 && int.TryParse(parts[1], out var s) ? s : 0); break;
            case "toast":
                var sc = Model.History.FirstOrDefault(c => c.Clip.Src != Model.DeviceId) ?? Model.History.FirstOrDefault();
                if (sc is not null) ShowToast(sc, force: true);
                break;
            case "prompt":
                ShowPairPrompt(new PairPrompt("00000000-0000-4000-8000-000000000000", parts.Length > 1 ? parts[1] : "Pixel 9", "android", "231291"), preview: true);
                break;
        }
    }

    // ------------------------------------------------------------------ windows

    public void ApplyTheme()
    {
        foreach (var w in new Window?[] { Flyout, _toast, _settingsWindow, _addDevice, _onboarding, _promptWindow })
            if (w is not null) WindowHelper.ApplyTheme(w, Theme);
    }

    public void ShowSettings(string page)
    {
        if (_settingsWindow is null)
        {
            _settingsWindow = new SettingsWindow();
            _settingsWindow.Closed += (_, _) => _settingsWindow = null;
            WindowHelper.ApplyTheme(_settingsWindow, Theme);
        }
        _settingsWindow.Navigate(page);
        WindowHelper.BringToFront(_settingsWindow);
    }

    public void ShowAddDevice()
    {
        if (_onboarding is not null)
        {
            WindowHelper.BringToFront(_onboarding);
            _onboarding.GoTo(2);
            return;
        }
        if (_addDevice is null)
        {
            _addDevice = new AddDeviceWindow();
            _addDevice.Closed += (_, _) => _addDevice = null;
            WindowHelper.ApplyTheme(_addDevice, Theme);
        }
        WindowHelper.BringToFront(_addDevice);
    }

    public void ShowOnboarding(int step = 0)
    {
        if (_onboarding is null)
        {
            _onboarding = new OnboardingWindow();
            _onboarding.Closed += (_, _) => _onboarding = null;
            WindowHelper.ApplyTheme(_onboarding, Theme);
        }
        _onboarding.GoTo(step);
        WindowHelper.BringToFront(_onboarding);
    }

    void ShowToast(StoredClip sc) => ShowToast(sc, force: false);

    void ShowToast(StoredClip sc, bool force)
    {
        Toast(force)?.Show(sc);
    }

    /// <summary>The toast window, created on first use; null when toasts are turned off.</summary>
    ToastWindow? Toast(bool force = false)
    {
        if (!Settings.ShowToasts && !force) return null;
        if (_toast is null)
        {
            _toast = new ToastWindow();
            WindowHelper.ApplyTheme(_toast, Theme);
        }
        return _toast;
    }

    public void ToastClicked()
    {
        if (Flyout is { IsOpen: false }) Flyout.ToggleNearTray(_tray.Bounds());
    }

    /// <summary>Inviter side of code pairing: a dialog in the Add-device window, or a small always-on-top window.</summary>
    void ShowPairPrompt(PairPrompt prompt) => ShowPairPrompt(prompt, preview: false);

    void ShowPairPrompt(PairPrompt prompt, bool preview)
    {
        if (_addDevice is not null && !preview) { WindowHelper.BringToFront(_addDevice); return; }
        if (_onboarding is not null && !preview) { WindowHelper.BringToFront(_onboarding); return; }
        _promptWindow?.Close();
        _promptWindow = new PairPromptWindow(prompt, preview);
        _promptWindow.Closed += (_, _) => _promptWindow = null;
        WindowHelper.ApplyTheme(_promptWindow, Theme);
        _promptWindow.Present();
    }

    void ShowTrayMenu(int x, int y)
    {
        Flyout?.Hide();
        var paused = Settings.Paused;
        var choice = _tray.ShowMenu(x, y,
        [
            (0, Loc.Plain(Model.StatusLine), false, false),
            (0, null, true, false),
            (1, Loc.Raw("Menu_Open"), true, false),
            (2, Loc.Raw("AddDevice_Ellipsis"), true, false),
            (3, Loc.Raw("PauseSyncing"), true, paused),
            (0, null, true, false),
            (4, Loc.Raw("Settings_Ellipsis"), true, false),
            (5, Loc.Raw("Quit"), true, false),
        ]);
        switch (choice)
        {
            case 1: Flyout?.ToggleNearTray(_tray.Bounds()); break;
            case 2: ShowAddDevice(); break;
            case 3: Model.SetPaused(!paused); break;
            case 4: ShowSettings("general"); break;
            case 5: Quit(); break;
        }
    }

    void OnModelChanged(ModelChange change)
    {
        if (change.HasFlag(ModelChange.Online) || change.HasFlag(ModelChange.Members) || change.HasFlag(ModelChange.Settings) || change == ModelChange.All)
            UpdateTray();
        if (change.HasFlag(ModelChange.Prompt) && Model.PairPrompt is null) _promptWindow?.Dismissed();
    }

    void UpdateTray() => _tray.SetState("Nearclip — " + Model.StatusLine, Settings.Paused);

    public bool SetHotKey(uint modifiers, uint key)
    {
        var ok = _hotkey.Register(modifiers, key);
        if (ok)
        {
            Settings.HotKeyModifiers = modifiers;
            Settings.HotKeyKey = key;
            Settings.Save();
        }
        else
        {
            _hotkey.Register(Settings.HotKeyModifiers, Settings.HotKeyKey);
        }
        return ok;
    }

    public void SuspendHotKey() => _hotkey.Unregister();

    public void ResumeHotKey() => _hotkey.Register(Settings.HotKeyModifiers, Settings.HotKeyKey);

    /// <summary>Starts a fresh copy (after a language change) and quits this one.</summary>
    public void Restart(string args)
    {
        try { Process.Start(new ProcessStartInfo(Startup.ExePath, "--relaunch " + args) { UseShellExecute = false }); }
        catch (Exception e) { Log.Write("restart failed: " + e.Message); return; }
        Quit();
    }

    public void OpenUrl(Uri uri)
    {
        try { Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true }); }
        catch (Exception e) { Log.Write("open link failed: " + e.Message); }
    }

    /// <summary>"Paste after choosing": brings back the app the user was in and presses Ctrl+V there.</summary>
    public async Task PasteIntoAsync(IntPtr target)
    {
        if (!Native.IsWindow(target)) return;
        Native.SetForegroundWindow(target);
        await Task.Delay(120);
        var inputs = new[]
        {
            Key(0x11, false), Key(0x56, false), Key(0x56, true), Key(0x11, true),
        };
        Native.SendInput((uint)inputs.Length, inputs, System.Runtime.InteropServices.Marshal.SizeOf<Native.INPUT>());

        static Native.INPUT Key(ushort vk, bool up) => new()
        {
            type = Native.INPUT_KEYBOARD,
            u = new Native.INPUTUNION { ki = new Native.KEYBDINPUT { wVk = vk, dwFlags = up ? Native.KEYEVENTF_KEYUP : 0 } },
        };
    }

    public void Quit()
    {
        if (_quitting) return;
        _quitting = true;
        Log.Write("quitting");
        try
        {
            _hotkey.Dispose();
            _tray.Dispose();
            Node.Dispose();
            Discovery.Dispose(); // withdraws the DNS-SD advertisement and waits for Windows to confirm
            _messages.Dispose();
        }
        catch (Exception e) { Log.Write("shutdown: " + e.Message); }
        Application.Current.Exit();
        Environment.Exit(0);
    }
}
