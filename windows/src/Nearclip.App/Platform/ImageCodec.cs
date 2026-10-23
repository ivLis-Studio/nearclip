using System.Buffers.Binary;
using System.Runtime.InteropServices.WindowsRuntime;
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

    /// <summary>CF_DIB / CF_DIBV5 (24/32-bit, BI_RGB / BI_BITFIELDS) → top-down BGRA with straight alpha.</summary>
    public static (byte[] Bgra, int W, int H)? DibToBgra(byte[] dib)
    {
        if (dib.Length < 40) return null;
        var headerSize = BinaryPrimitives.ReadInt32LittleEndian(dib);
        var width = BinaryPrimitives.ReadInt32LittleEndian(dib.AsSpan(4));
        var height = BinaryPrimitives.ReadInt32LittleEndian(dib.AsSpan(8));
        var bitCount = BinaryPrimitives.ReadInt16LittleEndian(dib.AsSpan(14));
        var compression = BinaryPrimitives.ReadInt32LittleEndian(dib.AsSpan(16));
        var clrUsed = BinaryPrimitives.ReadInt32LittleEndian(dib.AsSpan(32));
        if (width <= 0 || height == 0 || width > 30000 || Math.Abs(height) > 30000) return null;
        if (bitCount is not (24 or 32) || compression is not (0 or 3)) return null;
        var topDown = height < 0;
        var h = Math.Abs(height);
        var offset = headerSize;
        uint rMask = 0x00FF0000, gMask = 0x0000FF00, bMask = 0x000000FF, aMask = 0;
        if (compression == 3)
        {
            if (headerSize == 40)
            {
                rMask = BinaryPrimitives.ReadUInt32LittleEndian(dib.AsSpan(40));
                gMask = BinaryPrimitives.ReadUInt32LittleEndian(dib.AsSpan(44));
                bMask = BinaryPrimitives.ReadUInt32LittleEndian(dib.AsSpan(48));
                offset += 12;
            }
            else if (headerSize >= 56)
            {
                rMask = BinaryPrimitives.ReadUInt32LittleEndian(dib.AsSpan(40));
                gMask = BinaryPrimitives.ReadUInt32LittleEndian(dib.AsSpan(44));
                bMask = BinaryPrimitives.ReadUInt32LittleEndian(dib.AsSpan(48));
                aMask = BinaryPrimitives.ReadUInt32LittleEndian(dib.AsSpan(52));
            }
        }
        else if (headerSize >= 56 && bitCount == 32)
        {
            aMask = BinaryPrimitives.ReadUInt32LittleEndian(dib.AsSpan(52));
        }
        offset += clrUsed * 4;
        var stride = ((width * bitCount + 31) / 32) * 4;
        if (offset + (long)stride * h > dib.Length)
        {
            // Some producers omit the colour masks after a BITMAPINFOHEADER with BI_BITFIELDS.
            offset = headerSize + clrUsed * 4;
            if (offset + (long)stride * h > dib.Length) return null;
        }
        var outPx = new byte[width * h * 4];
        var anyAlpha = false;
        for (var y = 0; y < h; y++)
        {
            var srcRow = offset + (topDown ? y : h - 1 - y) * stride;
            var dstRow = y * width * 4;
            for (var x = 0; x < width; x++)
            {
                int s = srcRow + x * (bitCount / 8), d = dstRow + x * 4;
                if (bitCount == 24)
                {
                    outPx[d] = dib[s]; outPx[d + 1] = dib[s + 1]; outPx[d + 2] = dib[s + 2]; outPx[d + 3] = 255;
                }
                else
                {
                    var v = BinaryPrimitives.ReadUInt32LittleEndian(dib.AsSpan(s));
                    outPx[d] = Extract(v, bMask);
                    outPx[d + 1] = Extract(v, gMask);
                    outPx[d + 2] = Extract(v, rMask);
                    var a = aMask != 0 ? Extract(v, aMask) : (byte)(v >> 24);
                    outPx[d + 3] = a;
                    if (a != 0) anyAlpha = true;
                }
            }
        }
        // 32-bit BI_RGB bitmaps usually carry an unused (zero) alpha byte: treat them as opaque.
        if (bitCount == 32 && !anyAlpha)
            for (var i = 3; i < outPx.Length; i += 4) outPx[i] = 255;
        return (outPx, width, h);
    }

    static byte Extract(uint v, uint mask)
    {
        if (mask == 0) return 0;
        var shift = System.Numerics.BitOperations.TrailingZeroCount(mask);
        var bits = System.Numerics.BitOperations.PopCount(mask);
        var value = (v & mask) >> shift;
        return bits >= 8 ? (byte)(value >> (bits - 8)) : (byte)(value * 255 / ((1u << bits) - 1));
    }

    /// <summary>Straight-alpha BGRA → CF_DIBV5 (bottom-up, BI_BITFIELDS, sRGB) for apps that only read bitmaps.</summary>
    public static byte[] BgraToDibV5(byte[] bgra, int width, int height)
    {
        const int header = 124;
        var stride = width * 4;
        var dib = new byte[header + stride * height];
        var s = dib.AsSpan();
        BinaryPrimitives.WriteInt32LittleEndian(s, header);
        BinaryPrimitives.WriteInt32LittleEndian(s[4..], width);
        BinaryPrimitives.WriteInt32LittleEndian(s[8..], height);
        BinaryPrimitives.WriteInt16LittleEndian(s[12..], 1);
        BinaryPrimitives.WriteInt16LittleEndian(s[14..], 32);
        BinaryPrimitives.WriteInt32LittleEndian(s[16..], 3);
        BinaryPrimitives.WriteInt32LittleEndian(s[20..], stride * height);
        BinaryPrimitives.WriteInt32LittleEndian(s[24..], 2835);
        BinaryPrimitives.WriteInt32LittleEndian(s[28..], 2835);
        BinaryPrimitives.WriteUInt32LittleEndian(s[40..], 0x00FF0000);
        BinaryPrimitives.WriteUInt32LittleEndian(s[44..], 0x0000FF00);
        BinaryPrimitives.WriteUInt32LittleEndian(s[48..], 0x000000FF);
        BinaryPrimitives.WriteUInt32LittleEndian(s[52..], 0xFF000000);
        BinaryPrimitives.WriteUInt32LittleEndian(s[56..], 0x73524742); // LCS_sRGB
        BinaryPrimitives.WriteUInt32LittleEndian(s[108..], 4); // LCS_GM_IMAGES
        for (var y = 0; y < height; y++)
            System.Buffer.BlockCopy(bgra, (height - 1 - y) * stride, dib, header + y * stride, stride);
        return dib;
    }
}
