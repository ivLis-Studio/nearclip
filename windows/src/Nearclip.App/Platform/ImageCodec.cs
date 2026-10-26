using System.Buffers.Binary;
using System.Runtime.InteropServices.WindowsRuntime;
using Nearclip.Core;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace Nearclip.App.Platform;

/// <summary>PNG / JPEG / DIB conversions via Windows Imaging (WinRT BitmapEncoder/Decoder).</summary>
internal static class ImageCodec
{
    public static bool IsPng(ReadOnlySpan<byte> b) => b.Length > 24 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47;
    public static bool IsJpeg(ReadOnlySpan<byte> b) => b.Length > 3 && b[0] == 0xFF && b[1] == 0xD8;

    public static (int W, int H)? PngSize(ReadOnlySpan<byte> png) =>
        IsPng(png) ? ((int)BinaryPrimitives.ReadUInt32BigEndian(png[16..]), (int)BinaryPrimitives.ReadUInt32BigEndian(png[20..])) : null;

    /// <summary>Pixel size read from a PNG or JPEG file header, for received clips whose metadata has no w/h.</summary>
    public static (int W, int H)? SizeOfFile(string path)
    {
        try
        {
            using var fs = File.OpenRead(path);
            var buf = new byte[(int)Math.Min(fs.Length, 256 * 1024)];
            var n = fs.ReadAtLeast(buf, buf.Length, throwOnEndOfStream: false);
            var b = buf.AsSpan(0, n);
            if (IsPng(b)) return PngSize(b);
            if (IsJpeg(b)) return JpegSize(b);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        return null;
    }

    /// <summary>Width and height from the first SOFn segment.</summary>
    static (int W, int H)? JpegSize(ReadOnlySpan<byte> b)
    {
        var i = 2;
        while (i + 9 < b.Length)
        {
            if (b[i] != 0xFF) { i++; continue; }
            var marker = b[i + 1];
            if (marker == 0xFF) { i++; continue; }
            if (marker is 0xD8 or 0x01 or (>= 0xD0 and <= 0xD7)) { i += 2; continue; }
            var length = (b[i + 2] << 8) | b[i + 3];
            if (marker is >= 0xC0 and <= 0xCF and not 0xC4 and not 0xC8 and not 0xCC)
                return ((b[i + 7] << 8) | b[i + 8], (b[i + 5] << 8) | b[i + 6]);
            i += 2 + length;
        }
        return null;
    }

    public static async Task<byte[]> EncodeAsync(byte[] bgra, int width, int height, bool jpeg, double quality = 0.9)
    {
        using var stream = new InMemoryRandomAccessStream();
        BitmapEncoder encoder;
        if (jpeg)
        {
            var props = new BitmapPropertySet { ["ImageQuality"] = new BitmapTypedValue(quality, Windows.Foundation.PropertyType.Single) };
            encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.JpegEncoderId, stream, props);
        }
        else
        {
            encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
        }
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, jpeg ? BitmapAlphaMode.Ignore : BitmapAlphaMode.Straight,
            (uint)width, (uint)height, 96, 96, bgra);
        await encoder.FlushAsync();
        return await ReadAll(stream);
    }

    public static async Task<(byte[] Bgra, int W, int H)> DecodeAsync(byte[] data)
    {
        using var stream = new InMemoryRandomAccessStream();
        await stream.WriteAsync(data.AsBuffer());
        stream.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(stream);
        var pixels = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Straight, new BitmapTransform(),
            ExifOrientationMode.RespectExifOrientation, ColorManagementMode.DoNotColorManage);
        return (pixels.DetachPixelData(), (int)decoder.OrientedPixelWidth, (int)decoder.OrientedPixelHeight);
    }

    static async Task<byte[]> ReadAll(IRandomAccessStream stream)
    {
        var bytes = new byte[stream.Size];
        using var reader = new DataReader(stream.GetInputStreamAt(0));
        await reader.LoadAsync((uint)stream.Size);
        reader.ReadBytes(bytes);
        return bytes;
    }

    /// <summary>CF_DIB / CF_DIBV5 → top-down BGRA (<see cref="Dib.ToBgra"/>).</summary>
    public static (byte[] Bgra, int W, int H)? DibToBgra(byte[] dib) => Dib.ToBgra(dib);

    /// <summary>Straight-alpha BGRA → CF_DIBV5 (<see cref="Dib.FromBgra"/>).</summary>
    public static byte[] BgraToDibV5(byte[] bgra, int width, int height) => Dib.FromBgra(bgra, width, height);
}
