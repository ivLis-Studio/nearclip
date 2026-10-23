using System.Runtime.InteropServices;
using System.Text;
using Microsoft.UI.Dispatching;
using Nearclip.Core;

namespace Nearclip.App.Platform;

internal abstract record CopiedContent
{
    public sealed record Text(string Value) : CopiedContent;
    public sealed record Image(byte[] Data, string Mime, int Width, int Height, bool TooLarge) : CopiedContent;
}

/// <summary>Watches the Windows clipboard (AddClipboardFormatListener) and writes clips that arrive from other devices.
/// Clips written by Nearclip carry a private marker format so they are never sent back out (DESIGN.md §4.3), and
/// content that password managers exclude from clipboard history / monitoring is never read (PROTOCOL.md §8).</summary>
internal sealed class ClipboardService
{
    static readonly uint MarkerFormat = Native.RegisterClipboardFormat("Nearclip.ClipId");
    static readonly uint PngFormat = Native.RegisterClipboardFormat("PNG");
    static readonly uint JfifFormat = Native.RegisterClipboardFormat("JFIF");
    static readonly uint ExcludeFormat = Native.RegisterClipboardFormat("ExcludeClipboardContentFromMonitorProcessing");
    static readonly uint HistoryFormat = Native.RegisterClipboardFormat("CanIncludeInClipboardHistory");
    static readonly uint CloudFormat = Native.RegisterClipboardFormat("CanUploadToCloudClipboard");
    static readonly uint ViewerIgnoreFormat = Native.RegisterClipboardFormat("Clipboard Viewer Ignore");

    readonly MessageWindow _window;
    readonly DispatcherQueueTimer _debounce;
    uint _lastSeq;
    uint _ownSeq;

    public Func<bool> IsPaused { get; set; } = () => false;
    public Func<IReadOnlyCollection<string>> IgnoredApps { get; set; } = () => [];
    public event Action<CopiedContent>? Copied;

    public ClipboardService(MessageWindow window, DispatcherQueue ui)
    {
        _window = window;
        _debounce = ui.CreateTimer();
        _debounce.Interval = TimeSpan.FromMilliseconds(120);
        _debounce.IsRepeating = false;
        _debounce.Tick += (_, _) => _ = ReadAsync();
        _window.ClipboardChanged += () => { _debounce.Stop(); _debounce.Start(); };
        _lastSeq = Native.GetClipboardSequenceNumber();
    }

    bool Open()
    {
        for (var i = 0; i < 12; i++)
        {
            if (Native.OpenClipboard(_window.Handle)) return true;
            Thread.Sleep(15);
        }
        return false;
    }

    static byte[]? Read(uint format)
    {
        var h = Native.GetClipboardData(format);
        if (h == IntPtr.Zero) return null;
        var p = Native.GlobalLock(h);
        if (p == IntPtr.Zero) return null;
        try
        {
            var size = (int)(ulong)Native.GlobalSize(h);
            var data = new byte[size];
            Marshal.Copy(p, data, 0, size);
            return data;
        }
        finally { Native.GlobalUnlock(h); }
    }

    static bool DwordIsZero(uint format)
    {
        if (!Native.IsClipboardFormatAvailable(format)) return false;
        var d = Read(format);
        return d is { Length: >= 4 } && BitConverter.ToUInt32(d, 0) == 0;
    }

    string? OwnerProcessName()
    {
        var owner = Native.GetClipboardOwner();
        var hwnd = owner != IntPtr.Zero ? owner : Native.GetForegroundWindow();
        if (hwnd == IntPtr.Zero) return null;
        Native.GetWindowThreadProcessId(hwnd, out var pid);
        var path = pid == 0 ? null : Native.ProcessPath(pid);
        return path is null ? null : Path.GetFileName(path);
    }

    async Task ReadAsync()
    {
        var seq = Native.GetClipboardSequenceNumber();
        if (seq == _lastSeq || seq == _ownSeq) return;
        _lastSeq = seq;
        if (IsPaused()) return;
        var owner = OwnerProcessName();
        if (owner is not null && IgnoredApps().Any(a => string.Equals(a, owner, StringComparison.OrdinalIgnoreCase)))
        {
            Log.Write("clipboard: skipped copy from ignored app " + owner);
            return;
        }
        string? text = null;
        byte[]? png = null, dib = null;
        if (!Open()) { Log.Write("clipboard: busy"); return; }
        try
        {
            if (Native.IsClipboardFormatAvailable(MarkerFormat)) return;
            if (Native.IsClipboardFormatAvailable(ExcludeFormat) || Native.IsClipboardFormatAvailable(ViewerIgnoreFormat) ||
                DwordIsZero(HistoryFormat) || DwordIsZero(CloudFormat))
            {
                Log.Write("clipboard: skipped private item");
                return;
            }
            if (Native.IsClipboardFormatAvailable(Native.CF_HDROP)) return;
            var formats = new List<uint>();
            for (uint f = 0; (f = Native.EnumClipboardFormats(f)) != 0 && formats.Count < 64;) formats.Add(f);
            var hasText = formats.Contains(Native.CF_UNICODETEXT);
            var hasImage = formats.Contains(PngFormat) || formats.Contains(Native.CF_DIB) || formats.Contains(Native.CF_DIBV5);
            var first = formats.Count > 0 ? formats[0] : 0;
            var imageFirst = first == PngFormat || first is Native.CF_DIB or Native.CF_DIBV5 or Native.CF_BITMAP;
            if (hasImage && (imageFirst || !hasText))
            {
                if (formats.Contains(PngFormat)) png = Read(PngFormat);
                if (png is null || !ImageCodec.IsPng(png))
                {
                    png = null;
                    dib = formats.Contains(Native.CF_DIBV5) ? Read(Native.CF_DIBV5) : Read(Native.CF_DIB);
                }
            }
            if (png is null && dib is null && hasText)
            {
                var raw = Read(Native.CF_UNICODETEXT);
                if (raw is not null)
                {
                    var s = Encoding.Unicode.GetString(raw);
                    var nul = s.IndexOf('\0');
                    text = nul >= 0 ? s[..nul] : s;
                }
            }
        }
        finally { Native.CloseClipboard(); }

        try
        {
            if (text is { Length: > 0 })
            {
                Copied?.Invoke(new CopiedContent.Text(text));
                return;
            }
            if (png is null && dib is not null && ImageCodec.DibToBgra(dib) is { } bmp)
                png = await ImageCodec.EncodeAsync(bmp.Bgra, bmp.W, bmp.H, jpeg: false);
            if (png is null) return;
            var (w, h) = ImageCodec.PngSize(png) ?? (0, 0);
            if (png.Length <= Wire.MaxImage)
            {
                Copied?.Invoke(new CopiedContent.Image(png, "image/png", w, h, false));
                return;
            }
            // Too big as PNG: send a JPEG (quality 0.9) when that fits (PROTOCOL.md §7).
            var decoded = await ImageCodec.DecodeAsync(png);
            var jpeg = await ImageCodec.EncodeAsync(decoded.Bgra, decoded.W, decoded.H, jpeg: true, 0.9);
            Copied?.Invoke(new CopiedContent.Image(jpeg, "image/jpeg", decoded.W, decoded.H, jpeg.Length > Wire.MaxImage));
        }
        catch (Exception e)
        {
            Log.Write("clipboard: image conversion failed: " + e.Message);
        }
    }

    /// <summary>Writes a clip to the clipboard, marked so Nearclip never picks it up again.</summary>
    public async Task WriteAsync(Clip clip, byte[]? blob)
    {
        byte[]? dib = null;
        if (clip.IsImage)
        {
            if (blob is null) return;
            try
            {
                var d = await ImageCodec.DecodeAsync(blob);
                dib = ImageCodec.BgraToDibV5(d.Bgra, d.W, d.H);
            }
            catch (Exception e) { Log.Write("clipboard: decode failed: " + e.Message); }
        }
        if (!Open()) { Log.Write("clipboard: could not open for writing"); return; }
        try
        {
            Native.EmptyClipboard();
            if (clip.IsText)
            {
                SetData(Native.CF_UNICODETEXT, Encoding.Unicode.GetBytes((clip.Text ?? "") + "\0"));
            }
            else if (blob is not null)
            {
                SetData(clip.Mime == "image/jpeg" ? JfifFormat : PngFormat, blob);
                if (dib is not null) SetData(Native.CF_DIBV5, dib);
            }
            SetData(MarkerFormat, Encoding.UTF8.GetBytes(clip.Id));
        }
        finally
        {
            Native.CloseClipboard();
            _ownSeq = Native.GetClipboardSequenceNumber();
            _lastSeq = _ownSeq;
        }
    }

    static void SetData(uint format, byte[] data)
    {
        var h = Native.GlobalAlloc(Native.GMEM_MOVEABLE, (UIntPtr)Math.Max(1, data.Length));
        if (h == IntPtr.Zero) return;
        var p = Native.GlobalLock(h);
        Marshal.Copy(data, 0, p, data.Length);
        Native.GlobalUnlock(h);
        if (Native.SetClipboardData(format, h) == IntPtr.Zero) Native.GlobalFree(h);
    }
}
