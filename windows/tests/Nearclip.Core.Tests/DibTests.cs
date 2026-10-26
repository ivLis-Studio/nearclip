using System.Buffers.Binary;
using Xunit;

namespace Nearclip.Core.Tests;

/// <summary>Clipboard bitmaps decode to the picture they hold, whichever way the producer packed them.</summary>
public sealed class DibTests
{
    const int W = 7, H = 5;

    static byte[] Picture()
    {
        var px = new byte[W * H * 4];
        for (var y = 0; y < H; y++)
        for (var x = 0; x < W; x++)
        {
            var i = (y * W + x) * 4;
            px[i] = (byte)(x * 30); px[i + 1] = (byte)(y * 50); px[i + 2] = (byte)(200 - x * 10 - y); px[i + 3] = 255;
        }
        return px;
    }

    static byte[] Header(int size, int bpp, int compression, int height = H, uint[]? masks = null)
    {
        var b = new byte[size];
        BinaryPrimitives.WriteInt32LittleEndian(b, size);
        BinaryPrimitives.WriteInt32LittleEndian(b.AsSpan(4), W);
        BinaryPrimitives.WriteInt32LittleEndian(b.AsSpan(8), height);
        BinaryPrimitives.WriteInt16LittleEndian(b.AsSpan(12), 1);
        BinaryPrimitives.WriteInt16LittleEndian(b.AsSpan(14), (short)bpp);
        BinaryPrimitives.WriteInt32LittleEndian(b.AsSpan(16), compression);
        if (masks is not null && size >= 56)
            for (var i = 0; i < 4; i++) BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(40 + i * 4), masks[i]);
        return b;
    }

    static byte[] Rows(byte[] bgra, int bpp, bool alpha = true)
    {
        var stride = ((W * bpp + 31) / 32) * 4;
        var rows = new byte[stride * H];
        for (var y = 0; y < H; y++) // bottom-up
        for (var x = 0; x < W; x++)
        {
            var s = ((H - 1 - y) * W + x) * 4;
            var d = y * stride + x * (bpp / 8);
            rows[d] = bgra[s]; rows[d + 1] = bgra[s + 1]; rows[d + 2] = bgra[s + 2];
            if (bpp == 32) rows[d + 3] = alpha ? bgra[s + 3] : (byte)0;
        }
        return rows;
    }

    static byte[] Cat(params byte[][] parts) => parts.SelectMany(p => p).ToArray();

    static byte[] Masks(params uint[] m)
    {
        var b = new byte[m.Length * 4];
        for (var i = 0; i < m.Length; i++) BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(i * 4), m[i]);
        return b;
    }

    static void AssertPicture(byte[] dib)
    {
        var r = Dib.ToBgra(dib);
        Assert.NotNull(r);
        Assert.Equal(W, r.Value.W);
        Assert.Equal(H, r.Value.H);
        Assert.Equal(Picture(), r.Value.Bgra);
    }

    [Fact]
    public void V5WithItsMasksRepeatedAfterTheHeader()
    {
        // What Windows makes when an app puts only a bitmap on the clipboard: every row used to come out three pixels off.
        var masks = new uint[] { 0x00FF0000, 0x0000FF00, 0x000000FF, 0 };
        AssertPicture(Cat(Header(124, 32, 3, masks: masks), Masks(0x00FF0000, 0x0000FF00, 0x000000FF), Rows(Picture(), 32, alpha: false)));
    }

    [Fact]
    public void V5WithMasksInTheHeaderOnly() =>
        AssertPicture(Cat(Header(124, 32, 3, masks: new uint[] { 0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000 }), Rows(Picture(), 32)));

    [Fact]
    public void InfoHeaderWithBitfields() =>
        AssertPicture(Cat(Header(40, 32, 3), Masks(0x00FF0000, 0x0000FF00, 0x000000FF), Rows(Picture(), 32, alpha: false)));

    [Fact]
    public void TwentyFourBitRowsArePadded() => AssertPicture(Cat(Header(40, 24, 0), Rows(Picture(), 24)));

    [Fact]
    public void TopDownRows()
    {
        var rows = Rows(Picture(), 32);
        var stride = W * 4;
        var flipped = new byte[rows.Length];
        for (var y = 0; y < H; y++) Buffer.BlockCopy(rows, (H - 1 - y) * stride, flipped, y * stride, stride);
        AssertPicture(Cat(Header(40, 32, 0, height: -H), flipped));
    }

    [Fact]
    public void RoundTrip() => AssertPicture(Dib.FromBgra(Picture(), W, H));

    [Fact]
    public void GlobalAllocationSlackAfterThePixels() =>
        AssertPicture(Cat(Dib.FromBgra(Picture(), W, H), new byte[16]));
}
