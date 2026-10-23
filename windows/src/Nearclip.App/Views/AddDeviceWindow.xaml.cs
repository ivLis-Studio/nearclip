using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Nearclip.App.Model;
using Nearclip.App.Platform;

namespace Nearclip.App.Views;

public sealed partial class AddDeviceWindow : Window
{
    public AddDeviceWindow()
    {
        InitializeComponent();
        Title = Loc.Raw("AddDevice") + " — Nearclip";
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);
        var presenter = OverlappedPresenter.CreateForDialog();
        presenter.IsResizable = true;
        AppWindow.SetPresenter(presenter);
        WindowHelper.SetIcon(this);
        WindowHelper.UseBackdrop(this);
        WindowHelper.CenterOnScreen(this, 740, 500);
    }

    public AddDeviceView AddView => View;
}
