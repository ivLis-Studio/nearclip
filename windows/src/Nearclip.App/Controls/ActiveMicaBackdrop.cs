using Microsoft.UI.Composition;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace Nearclip.App.Controls;

/// <summary>Mica that keeps its material while the window is not focused (toast and prompt windows never take focus
/// from the app the user is working in).</summary>
internal sealed partial class ActiveMicaBackdrop : SystemBackdrop
{
    MicaController? _controller;
    SystemBackdropConfiguration? _config;
    FrameworkElement? _root;

    protected override void OnTargetConnected(ICompositionSupportsSystemBackdrop connectedTarget, XamlRoot xamlRoot)
    {
        base.OnTargetConnected(connectedTarget, xamlRoot);
        if (!MicaController.IsSupported()) return;
        _config = new SystemBackdropConfiguration { IsInputActive = true };
        _root = xamlRoot.Content as FrameworkElement;
        UpdateTheme();
        if (_root is not null) _root.ActualThemeChanged += (_, _) => UpdateTheme();
        _controller = new MicaController { Kind = MicaKind.Base };
        _controller.SetSystemBackdropConfiguration(_config);
        _controller.AddSystemBackdropTarget(connectedTarget);
    }

    void UpdateTheme()
    {
        if (_config is null) return;
        _config.Theme = _root?.ActualTheme switch
        {
            ElementTheme.Dark => SystemBackdropTheme.Dark,
            ElementTheme.Light => SystemBackdropTheme.Light,
            _ => SystemBackdropTheme.Default,
        };
    }

    protected override void OnTargetDisconnected(ICompositionSupportsSystemBackdrop disconnectedTarget)
    {
        base.OnTargetDisconnected(disconnectedTarget);
        _controller?.RemoveSystemBackdropTarget(disconnectedTarget);
        _controller?.Dispose();
        _controller = null;
    }
}
