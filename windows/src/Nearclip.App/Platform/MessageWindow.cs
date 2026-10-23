using System.Runtime.InteropServices;

namespace Nearclip.App.Platform;

/// <summary>Hidden top-level window that receives clipboard updates, hotkeys, tray callbacks and shell broadcasts
/// (a message-only window would miss <c>TaskbarCreated</c>). Lives on the UI thread.</summary>
internal sealed class MessageWindow : IDisposable
{
    public const string ClassName = "NearclipMessageWindow";

    readonly Native.WndProc _proc;
    public IntPtr Handle { get; }
    public uint TaskbarCreatedMessage { get; }

    public event Action? ClipboardChanged;
    public event Action<int>? HotKey;
    public event Action? TaskbarCreated;
    public event Action? SettingsChanged;
    public event Action<uint, IntPtr, IntPtr>? Message;
    /// <summary>Command line forwarded by a later launch (see <see cref="Program"/>).</summary>
    public event Action<IReadOnlyList<string>>? CommandLine;

    /// <param name="title">Window title; later launches find the running instance by class and title.</param>
    public MessageWindow(string title)
    {
        _proc = WndProc;
        var cls = new Native.WNDCLASSEX
        {
            cbSize = (uint)Marshal.SizeOf<Native.WNDCLASSEX>(),
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_proc),
            hInstance = Native.GetModuleHandle(null),
            lpszClassName = ClassName,
        };
        Native.RegisterClassEx(ref cls);
        Handle = Native.CreateWindowEx(Native.WS_EX_TOOLWINDOW, cls.lpszClassName, title, Native.WS_POPUP, 0, 0, 0, 0,
            IntPtr.Zero, IntPtr.Zero, cls.hInstance, IntPtr.Zero);
        TaskbarCreatedMessage = Native.RegisterWindowMessage("TaskbarCreated");
        Native.AddClipboardFormatListener(Handle);
    }

    IntPtr WndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        try
        {
            switch (msg)
            {
                case Native.WM_CLIPBOARDUPDATE:
                    ClipboardChanged?.Invoke();
                    return IntPtr.Zero;
                case Native.WM_HOTKEY:
                    HotKey?.Invoke((int)wParam);
                    return IntPtr.Zero;
                case Native.WM_SETTINGCHANGE:
                case Native.WM_THEMECHANGED:
                    SettingsChanged?.Invoke();
                    break;
                case Native.WM_COPYDATA:
                    var data = Marshal.PtrToStructure<Native.COPYDATASTRUCT>(lParam);
                    if (data.dwData != Program.ForwardTag || data.lpData == IntPtr.Zero || data.cbData < 2) break;
                    var text = Marshal.PtrToStringUni(data.lpData, data.cbData / 2).TrimEnd('\0');
                    var args = text.Split('\0').Where(a => a.Length > 0).ToList();
                    // Handle it after SendMessage returns so the sender is not kept waiting by dialogs.
                    Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread()?.TryEnqueue(() => CommandLine?.Invoke(args));
                    return (IntPtr)1;
            }
            if (msg == TaskbarCreatedMessage && msg != 0) TaskbarCreated?.Invoke();
            Message?.Invoke(msg, wParam, lParam);
        }
        catch (Exception e)
        {
            Log.Write("message window: " + e);
        }
        return Native.DefWindowProc(hWnd, msg, wParam, lParam);
    }

    public void Dispose()
    {
        Native.RemoveClipboardFormatListener(Handle);
        Native.DestroyWindow(Handle);
    }
}
