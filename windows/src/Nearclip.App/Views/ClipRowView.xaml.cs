using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Nearclip.App.Model;

namespace Nearclip.App.Views;

/// <summary>One history row (DESIGN.md §4.4): leading glyph / thumbnail / swatch, two-line title, source · time caption,
/// pin indicator, Ctrl+N hint or hover actions.</summary>
public sealed partial class ClipRowView : UserControl
{
    public static readonly DependencyProperty ItemProperty =
        DependencyProperty.Register(nameof(Item), typeof(ClipItem), typeof(ClipRowView), new PropertyMetadata(null, (d, _) => ((ClipRowView)d).Bind()));

    /// <summary>Pixel sizes read from blob headers for clips received without w/h.</summary>
    static readonly Dictionary<string, (int W, int H)?> s_sizes = new();

    public ClipRowView()
    {
        InitializeComponent();
        ToolTipService.SetToolTip(DeleteButton, Loc.S("DeleteEverywhere"));
        AutomationProperties.SetName(DeleteButton, Loc.S("DeleteEverywhere"));
    }

    public ClipItem? Item { get => (ClipItem?)GetValue(ItemProperty); set => SetValue(ItemProperty, value); }

    static AppModel Model => AppHost.Current.Model;

    void Bind()
    {
        if (Item is not { } item) return;
        var sc = item.Clip;
        var c = sc.Clip;
        GlyphTile.Visibility = Visibility.Visible;
        ThumbTile.Visibility = Visibility.Collapsed;
        Swatch.Visibility = Visibility.Collapsed;
        Title.FontFamily = (FontFamily)Application.Current.Resources["ContentControlThemeFontFamily"];
        Title.FontSize = 13;
        TitleMain.FontWeight = FontWeights.Normal;
        TitleMain.Text = "";
        TitleExtra.Text = "";
        GlyphTile.Style = Controls.Themed.Style("TileSubtle");
        Glyph.Style = Controls.Themed.Style("IconSecondary");
        string accessible;
        switch (item.Kind)
        {
            case ClipKind.Image:
            {
                Glyph.Glyph = "\uE91B";
                var size = (c.W ?? 0) > 0 && (c.H ?? 0) > 0 ? (c.W!.Value, c.H!.Value) : PixelSize(sc.Id);
                var dims = size is { } s ? $" · {s.W}×{s.H}" : "";
                TitleMain.Text = Loc.S("Kind_Image");
                TitleExtra.Text = dims + " · " + Format.Bytes(c.Size ?? 0);
                accessible = Loc.S("Kind_Image");
                _ = LoadThumbnail(item);
                break;
            }
            case ClipKind.Link:
            {
                Glyph.Glyph = "\uE71B";
                GlyphTile.Style = Controls.Themed.Style("TileIris");
                Glyph.Style = Controls.Themed.Style("IconIris");
                var u = item.Link!;
                TitleMain.Text = u.Host;
                TitleMain.FontWeight = FontWeights.SemiBold;
                var path = u.PathAndQuery.Length > 1 ? Uri.UnescapeDataString(u.PathAndQuery) : "";
                TitleExtra.Text = path;
                Title.MaxLines = 1;
                accessible = u.Host + path;
                break;
            }
            case ClipKind.Color:
            {
                GlyphTile.Visibility = Visibility.Collapsed;
                Swatch.Visibility = Visibility.Visible;
                Swatch.Background = Format.ColorFromHex(item.Text) is { } col ? new SolidColorBrush(col) : null;
                TitleMain.Text = item.Text.Trim().ToUpperInvariant();
                Title.FontFamily = new FontFamily("Cascadia Mono, Consolas");
                accessible = item.Text.Trim();
                break;
            }
            default:
            {
                Glyph.Glyph = "\uE8E4";
                var preview = Format.Preview(item.Text);
                TitleMain.Text = preview.Length == 0 ? " " : Loc.KeepAllWords(preview);
                Title.MaxLines = 2;
                if (item.LooksLikeCode)
                {
                    Title.FontFamily = new FontFamily("Cascadia Mono, Consolas");
                    Title.FontSize = 12;
                }
                accessible = preview;
                break;
            }
        }
        if (item.Kind != ClipKind.Link && item.Kind != ClipKind.Text) Title.MaxLines = 1;
        SourceGlyph.Glyph = Model.SourceGlyph(sc);
        var source = Model.SourceName(sc);
        var when = Format.Relative(c.Ts);
        Caption.Text = sc.LocalOnly ? source + " · " + Loc.S("TooLarge") : source + " · " + when;
        Caption.Style = Controls.Themed.Style(sc.LocalOnly ? "TextWarning" : "TextSecondary");
        PinGlyph.Visibility = item.Pinned ? Visibility.Visible : Visibility.Collapsed;
        Shortcut.Text = item.Index is >= 0 and < 9 ? "Ctrl+" + (item.Index + 1) : "";
        PinButtonGlyph.Glyph = item.Pinned ? "\uE77A" : "\uE718";
        var pinLabel = Loc.S(item.Pinned ? "Unpin" : "Pin");
        ToolTipService.SetToolTip(PinButton, pinLabel);
        AutomationProperties.SetName(PinButton, pinLabel);
        AutomationProperties.SetName(this, Loc.F("Row_Accessible", accessible, source, when));
        ContextFlyout = BuildMenu(item);
    }

    static (int W, int H)? PixelSize(string id)
    {
        if (s_sizes.TryGetValue(id, out var known)) return known;
        var size = Platform.ImageCodec.SizeOfFile(Model.Node.BlobPath(id));
        if (size is null) return null; // blob not here yet: try again on the next bind
        if (s_sizes.Count > 1000) s_sizes.Clear();
        s_sizes[id] = size;
        return size;
    }

    async Task LoadThumbnail(ClipItem item)
    {
        var img = await Thumbnails.GetAsync(item.Clip.Id, Model.Node.BlobPath(item.Clip.Id));
        if (Item != item || img is null) return;
        Thumb.Source = img;
        ThumbTile.Visibility = Visibility.Visible;
        GlyphTile.Visibility = Visibility.Collapsed;
    }

    MenuFlyout BuildMenu(ClipItem item)
    {
        var menu = new MenuFlyout();
        var copy = new MenuFlyoutItem { Text = Loc.S("Copy"), Icon = new FontIcon { Glyph = "\uE8C8" } };
        copy.Click += (_, _) => AppHost.Current.Flyout?.CopyItem(item);
        menu.Items.Add(copy);
        if (item.Link is { } link)
        {
            var open = new MenuFlyoutItem { Text = Loc.S("OpenLink"), Icon = new FontIcon { Glyph = "\uE8A7" } };
            open.Click += (_, _) => AppHost.Current.OpenUrl(link);
            menu.Items.Add(open);
        }
        var pin = new MenuFlyoutItem { Text = Loc.S(item.Pinned ? "Unpin" : "Pin"), Icon = new FontIcon { Glyph = item.Pinned ? "\uE77A" : "\uE718" } };
        pin.KeyboardAcceleratorTextOverride = "Ctrl+P";
        pin.Click += (_, _) => Model.TogglePin(item);
        menu.Items.Add(pin);
        menu.Items.Add(new MenuFlyoutSeparator());
        var delete = new MenuFlyoutItem { Text = Loc.S("DeleteEverywhere"), Icon = new FontIcon { Glyph = "\uE74D" } };
        delete.KeyboardAcceleratorTextOverride = "Delete";
        delete.Click += (_, _) => Model.Delete(item);
        menu.Items.Add(delete);
        return menu;
    }

    void Root_PointerEntered(object sender, PointerRoutedEventArgs e)
    {
        HoverActions.Visibility = Visibility.Visible;
        Shortcut.Visibility = Visibility.Collapsed;
    }

    void Root_PointerExited(object sender, PointerRoutedEventArgs e)
    {
        HoverActions.Visibility = Visibility.Collapsed;
        Shortcut.Visibility = Visibility.Visible;
    }

    void PinButton_Click(object sender, RoutedEventArgs e)
    {
        if (Item is { } item) Model.TogglePin(item);
    }

    void DeleteButton_Click(object sender, RoutedEventArgs e)
    {
        if (Item is { } item) Model.Delete(item);
    }
}
