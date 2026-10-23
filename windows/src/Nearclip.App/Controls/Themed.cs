using Microsoft.UI.Xaml;

namespace Nearclip.App.Controls;

/// <summary>Keyed theme-aware styles from App.xaml for elements built in code.</summary>
/// <remarks>
/// Never read a brush from <c>Application.Current.Resources</c> in code: that returns the brush of the application
/// theme (the Windows theme), not of the window's Light/Dark choice, and it never follows theme changes. A style whose
/// setters use <c>{ThemeResource}</c> is resolved per element, like the built-in control styles.
/// </remarks>
internal static class Themed
{
    public static Style Style(string key) => (Style)Application.Current.Resources[key];
}
