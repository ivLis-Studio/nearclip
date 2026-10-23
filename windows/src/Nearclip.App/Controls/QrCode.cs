using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml.Media.Imaging;
using QRCoder;

namespace Nearclip.App.Controls;

/// <summary>Renders a pairing QR code: dark Iris modules on white, error correction H (room for the glyph in the centre).</summary>
internal static class QrCode
{
    public static WriteableBitmap Render(string text, int targetPixels)
    {
        using var generator = new QRCodeGenerator();
        using var data = generator.CreateQrCode(text, QRCodeGenerator.ECCLevel.H);
        var matrix = data.ModuleMatrix;
        var count = matrix.Count;
        var module = Math.Max(2, targetPixels / count);
        var size = module * count;
        var px = new byte[size * size * 4];
        Array.Fill(px, (byte)255);
        const byte r = 0x2B, g = 0x33, b = 0x8C;
        for (var y = 0; y < count; y++)
        {
            var row = matrix[y];
            for (var x = 0; x < count; x++)
            {
                if (!row[x]) continue;
                for (var dy = 0; dy < module; dy++)
                {
                    var o = ((y * module + dy) * size + x * module) * 4;
                    for (var dx = 0; dx < module; dx++, o += 4)
                    {
                        px[o] = b; px[o + 1] = g; px[o + 2] = r; px[o + 3] = 255;
                    }
                }
            }
        }
        var bmp = new WriteableBitmap(size, size);
        using (var s = bmp.PixelBuffer.AsStream()) s.Write(px, 0, px.Length);
        bmp.Invalidate();
        return bmp;
    }
}
