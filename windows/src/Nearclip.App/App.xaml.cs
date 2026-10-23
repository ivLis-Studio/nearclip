using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Nearclip.App.Platform;

namespace Nearclip.App;

public partial class App : Application
{
    public App()
    {
        InitializeComponent();
        // A tray app: keep running with no visible window until the user quits.
        DispatcherShutdownMode = DispatcherShutdownMode.OnExplicitShutdown;
        UnhandledException += (_, e) =>
        {
            Log.Write("unhandled: " + e.Exception);
            e.Handled = true;
        };
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var host = new AppHost(DispatcherQueue.GetForCurrentThread(), Program.Settings, Program.DataDirectory);
        host.Start(Program.Args);
    }
}
