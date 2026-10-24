using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Nearclip.App.Controls;

/// <summary>A row in the Windows 11 Settings card style.</summary>
public sealed partial class SettingsCard : ContentControl
{
    public static readonly DependencyProperty HeaderProperty =
        DependencyProperty.Register(nameof(Header), typeof(string), typeof(SettingsCard), new PropertyMetadata("", (d, _) => ((SettingsCard)d).Sync()));

    public static readonly DependencyProperty DescriptionProperty =
        DependencyProperty.Register(nameof(Description), typeof(string), typeof(SettingsCard), new PropertyMetadata("", (d, _) => ((SettingsCard)d).Sync()));

    public static readonly DependencyProperty GlyphProperty =
        DependencyProperty.Register(nameof(Glyph), typeof(string), typeof(SettingsCard), new PropertyMetadata("", (d, _) => ((SettingsCard)d).Sync()));

    /// <summary>Optional FontIcon style for the leading glyph (status tint).</summary>
    public static readonly DependencyProperty GlyphStyleProperty =
        DependencyProperty.Register(nameof(GlyphStyle), typeof(Style), typeof(SettingsCard), new PropertyMetadata(null, (d, _) => ((SettingsCard)d).Sync()));

    FrameworkElement? _icon, _description;

    public SettingsCard()
    {
        DefaultStyleKey = typeof(SettingsCard);
    }

    public string Header { get => (string)GetValue(HeaderProperty); set => SetValue(HeaderProperty, value); }
    public string Description { get => (string)GetValue(DescriptionProperty); set => SetValue(DescriptionProperty, value); }
    public string Glyph { get => (string)GetValue(GlyphProperty); set => SetValue(GlyphProperty, value); }
    public Style? GlyphStyle { get => (Style?)GetValue(GlyphStyleProperty); set => SetValue(GlyphStyleProperty, value); }

    protected override void OnApplyTemplate()
    {
        base.OnApplyTemplate();
        _icon = GetTemplateChild("PART_Icon") as FrameworkElement;
        _description = GetTemplateChild("PART_Description") as FrameworkElement;
        Sync();
    }

    void Sync()
    {
        if (_icon is not null) _icon.Visibility = string.IsNullOrEmpty(Glyph) ? Visibility.Collapsed : Visibility.Visible;
        if (_icon is FontIcon fi && GlyphStyle is { } s) fi.Style = s;
        if (_description is not null) _description.Visibility = string.IsNullOrEmpty(Description) ? Visibility.Collapsed : Visibility.Visible;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, Header);
    }
}
