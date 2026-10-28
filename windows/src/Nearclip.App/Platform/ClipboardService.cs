using System.Runtime.InteropServices;
using System.Text;
using Microsoft.UI.Dispatching;
using Nearclip.Core;

namespace Nearclip.App.Platform;

internal abstract record CopiedContent
{
    /// <param name="Key">What the text holds (<see cref="ContentKey"/>).</param>
    public sealed record Text(string Value, string Key) : CopiedContent;
    /// <param name="Announced">The id from <see cref="ClipboardService.ImageStarting"/> (PROTOCOL.md §6.6), if announced.</param>
    public sealed record Image(byte[] Data, string Mime, int Width, int Height, bool TooLarge, string? Announced = null) : CopiedContent;
}

/// <summary>Watches the Windows clipboard (AddClipboardFormatListener) and writes clips that arrive from other devices.
/// Clips written by Nearclip carry a private marker format so they are never sent back out (DESIGN.md §4.3), and
/// content that password managers exclude from clipboard history / monitoring is never read (PROTOCOL.md §8).
/// The clipboard set again to what it already holds is not a new copy: a screenshot tool that puts its picture there
/// twice, or a phone link that puts back the text Nearclip just wrote, would otherwise send it again — and around again.
/// Likewise a clip that the clipboard already holds is not written again.</summary>
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
    /// <summary>Bumped on every clipboard change: an image still being encoded when a newer copy comes is dropped, so the
    /// newest copy always wins.</summary>
    int _generation;
    /// <summary>What the clipboard holds as far as Nearclip knows (<see cref="ContentKey"/>; null: something it did not
    /// read), and the clipboard sequence number at which that was true.</summary>
    string? _lastKey;
    uint _lastKeySeq;

    public Func<bool> IsPaused { get; set; } = () => false;
    public Func<IReadOnlyCollection<string>> IgnoredApps { get; set; } = () => [];
    /// <summary>An image copy is about to be encoded: returns an announcement id (PROTOCOL.md §6.6) or null.</summary>
    public Func<string?> ImageStarting { get; set; } = () => null;
    /// <summary>The announced image will not be sent (unreadable, or replaced by a newer copy).</summary>
    public Action<string?> ImageCancelled { get; set; } = _ => { };
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
        var generation = ++_generation;
        if (IsPaused())
        {
            Remember(null, seq);
            return;
        }
        var owner = OwnerProcessName();
        if (owner is not null && IgnoredApps().Any(a => string.Equals(a, owner, StringComparison.OrdinalIgnoreCase)))
        {
            Remember(null, seq);
            Log.Write("clipboard: skipped copy from ignored app " + owner);
            return;
        }
        string? text = null;
        byte[]? png = null, dib = null;
        if (!Open())
        {
            Remember(null, seq);
            Log.Write("clipboard: busy");
            return;
        }
        try
        {
            // A clip of Nearclip's, set again by another app together with its marker (a clipboard manager restoring
            // it): never sent back out. Which one it is, is not known.
            if (Native.IsClipboardFormatAvailable(MarkerFormat))
            {
                Remember(null, seq);
                return;
            }
            if (Native.IsClipboardFormatAvailable(ExcludeFormat) || Native.IsClipboardFormatAvailable(ViewerIgnoreFormat) ||
                DwordIsZero(HistoryFormat) || DwordIsZero(CloudFormat))
            {
                Remember(null, seq);
                Log.Write("clipboard: skipped private item");
                return;
            }
            if (Native.IsClipboardFormatAvailable(Native.CF_HDROP))
            {
                Remember(null, seq);
                return;
            }
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

        string? announced = null;
        try
        {
            if (text is { Length: > 0 })
            {
                var key = ContentKey.Text(text);
                if (key == _lastKey)
                {
                    Remember(key, seq);
                    Log.Write("clipboard: the same text again, not a new copy");
                    return;
                }
                Remember(key, seq);
                Copied?.Invoke(new CopiedContent.Text(text, key));
                return;
            }
            if (png is null && dib is null)
            {
                Remember(null, seq);
                return;
            }
            // The pixels first: the same picture set again (as a bitmap, then as PNG) is not a new copy, and is not even
            // announced to the other devices.
            var pixels = dib is not null ? ImageCodec.DibToBgra(dib) : await ImageCodec.DecodeAsync(png!);
            if (generation != _generation) return;
            if (pixels is not { } bmp)
            {
                Remember(null, seq);
                return;
            }
            var imageKey = ContentKey.Pixels(bmp.Bgra, bmp.W, bmp.H);
            if (imageKey == _lastKey)
            {
                Remember(imageKey, seq);
                Log.Write("clipboard: the same image again, not a new copy");
                return;
            }
            Remember(imageKey, seq);
            // Large images: the other devices show "Receiving…" while this PC is still encoding.
            announced = ImageStarting();
            png ??= await ImageCodec.EncodeAsync(bmp.Bgra, bmp.W, bmp.H, jpeg: false);
            if (generation != _generation)
            {
                ImageCancelled(announced);
                return;
            }
            if (png.Length <= Wire.MaxImage)
            {
                Copied?.Invoke(new CopiedContent.Image(png, "image/png", bmp.W, bmp.H, false, announced));
                return;
            }
            // Too big as PNG: send a JPEG (quality 0.9) when that fits (PROTOCOL.md §7).
            var jpeg = await ImageCodec.EncodeAsync(bmp.Bgra, bmp.W, bmp.H, jpeg: true, 0.9);
            if (generation != _generation)
            {
                ImageCancelled(announced);
                return;
            }
            Copied?.Invoke(new CopiedContent.Image(jpeg, "image/jpeg", bmp.W, bmp.H, jpeg.Length > Wire.MaxImage, announced));
        }
        catch (Exception e)
        {
            ImageCancelled(announced);
            Log.Write("clipboard: image conversion failed: " + e.Message);
        }
    }

    void Remember(string? key, uint seq)
    {
        _lastKey = key;
        _lastKeySeq = seq;
    }

    /// <summary>Writes a clip to the clipboard, marked so Nearclip never picks it up again. Returns false when nothing
    /// was written: the clipboard already holds the same content, or it could not be opened.</summary>
    public async Task<bool> WriteAsync(Clip clip, byte[]? blob)
    {
        if (clip.IsExpired(Clock.NowMs())) return false;
        byte[]? dib = null;
        string? key;
        if (clip.IsImage)
        {
            if (blob is null) return false;
            key = null;
            try
            {
                var d = await ImageCodec.DecodeAsync(blob);
                key = ContentKey.Pixels(d.Bgra, d.W, d.H);
                dib = ImageCodec.BgraToDibV5(d.Bgra, d.W, d.H);
            }
            catch (Exception e) { Log.Write("clipboard: decode failed: " + e.Message); }
            key ??= ContentKey.Of(clip);
        }
        else
        {
            key = ContentKey.Text(clip.Text ?? "");
        }
        if (key is not null && key == _lastKey && Native.GetClipboardSequenceNumber() == _lastKeySeq)
        {
            Log.Write("clipboard: already holds this clip, not written again");
            return false;
        }
        if (!Open())
        {
            Log.Write("clipboard: could not open for writing");
            return false;
        }
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
            if (clip.IsCode) {
                SetData(ExcludeFormat, new byte[4]);
                SetData(HistoryFormat, new byte[4]);
                SetData(CloudFormat, new byte[4]);
            }
        }
        finally
        {
            Native.CloseClipboard();
            _ownSeq = Native.GetClipboardSequenceNumber();
            _lastSeq = _ownSeq;
            _generation++;
            Remember(key, _ownSeq);
        }
        if (clip.IsCode) _ = ExpireCodeAsync(clip, _ownSeq);
        return true;
    }

    async Task ExpireCodeAsync(Clip clip, uint written) {
        await Task.Delay(TimeSpan.FromMilliseconds(Math.Clamp(clip.Ts + 180_000 - Clock.NowMs(), 0, 240_000)));
        // Only our original clipboard write may be cleared. A newer copy, even of the same digits, wins.
        if (Native.GetClipboardSequenceNumber() != written || !Open()) return;
        try {
            if (Native.GetClipboardSequenceNumber() != written) return;
            var raw = Read(Native.CF_UNICODETEXT);
            if (raw is not null && Encoding.Unicode.GetString(raw).TrimEnd('\0') == clip.Text) Native.EmptyClipboard();
        } finally { Native.CloseClipboard(); }
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
