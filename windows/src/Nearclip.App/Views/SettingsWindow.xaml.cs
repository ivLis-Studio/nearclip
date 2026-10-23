using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Nearclip.App.Model;
using Nearclip.App.Platform;

namespace Nearclip.App.Views;

/// <summary>Settings (DESIGN.md §4.5–4.6) in the Windows 11 Settings style: NavigationView + setting cards.</summary>
public sealed partial class SettingsWindow : Window
{
    SettingsPages? _pages;
    string _page = "general";
    bool _initialFocusDone;

    public SettingsWindow()
    {
        InitializeComponent();
        Title = Loc.Raw("SettingsTitle");
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);
        WindowHelper.SetIcon(this);
        WindowHelper.UseBackdrop(this);
        WindowHelper.CenterOnScreen(this, 940, 680);
        _pages = new SettingsPages(this);
        AppHost.Current.Model.Changed += OnChanged;
        // The first keyboard focus goes to the selected page's item, as in Windows Settings (not to the first item).
        Nav.GettingFocus += (_, e) =>
        {
            if (_initialFocusDone) return;
            _initialFocusDone = true;
            if (Nav.SelectedItem is NavigationViewItem selected && !ReferenceEquals(e.NewFocusedElement, selected))
                e.TrySetNewFocusedElement(selected);
        };
        Closed += (_, _) =>
        {
            AppHost.Current.Model.Changed -= OnChanged;
            _pages?.Detach();
        };
    }

    void OnChanged(ModelChange change) => _pages?.OnModelChanged(_page, change);

    public void Navigate(string page)
    {
        var item = page switch
        {
            "devices" => NavDevices,
            "privacy" => NavPrivacy,
            "history" => NavHistory,
            "about" => NavAbout,
            _ => NavGeneral,
        };
        if (ReferenceEquals(Nav.SelectedItem, item)) Show(page);
        else Nav.SelectedItem = item;
        // Keep keyboard focus on the selected page when the window already has focus (programmatic navigation
        // would otherwise leave it on the previous item).
        if (_initialFocusDone) item.Focus(FocusState.Programmatic);
    }

    void Nav_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is NavigationViewItem { Tag: string tag }) Show(tag);
    }

    void Show(string page)
    {
        _page = page;
        PageHost.Content = _pages?.Build(page);
        PageScroll.ChangeView(null, 0, null, true);
    }

    internal XamlRoot? DialogRoot => Content.XamlRoot;
}
