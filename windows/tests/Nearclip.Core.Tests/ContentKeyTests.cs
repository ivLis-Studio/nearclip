using Xunit;

namespace Nearclip.Core.Tests;

/// <summary>The same thing copied again is recognised as the same thing (DESIGN.md §4.3).</summary>
public sealed class ContentKeyTests
{
    [Fact]
    public void TextIgnoresLineEndingsCompositionAndTrailingWhitespace()
    {
        var key = ContentKey.Text("첫 줄\n둘째 줄");
        Assert.Equal(key, ContentKey.Text("첫 줄\r\n둘째 줄"));
        Assert.Equal(key, ContentKey.Text("첫 줄\r둘째 줄"));
        Assert.Equal(key, ContentKey.Text("첫 줄\n둘째 줄\r\n"));
        Assert.Equal(key, ContentKey.Text("첫 줄\n둘째 줄 \t "));
        // Decomposed Hangul (as macOS file names carry it) is the same text.
        Assert.Equal(key, ContentKey.Text("첫 줄\n둘째 줄".Normalize(System.Text.NormalizationForm.FormD)));
        Assert.StartsWith("t:", key);
    }

    [Fact]
    public void DifferentTextStaysDifferent()
    {
        Assert.NotEqual(ContentKey.Text("hello"), ContentKey.Text("Hello"));
        Assert.NotEqual(ContentKey.Text("hello"), ContentKey.Text(" hello"));
        Assert.NotEqual(ContentKey.Text("a\nb"), ContentKey.Text("a\n\nb"));
        Assert.NotEqual(ContentKey.Text("1234"), ContentKey.Text("12345"));
    }

    [Fact]
    public void LoneSurrogateDoesNotThrow()
    {
        Assert.Equal(ContentKey.Text("a\uD800"), ContentKey.Text("a\uD800\r\n"));
    }

    /// <summary>The same keys as the Apple and Android apps compute (not required, but easy to keep).</summary>
    [Fact]
    public void SameTextKeyAsTheOtherApps()
    {
        Assert.Equal("t:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", ContentKey.Text("hello\r\n"));
    }

    static byte[] Image(int w, int h, Func<int, int, (byte B, byte G, byte R, byte A)> pixel)
    {
        var px = new byte[w * h * 4];
        for (var y = 0; y < h; y++)
        for (var x = 0; x < w; x++)
        {
            var (b, g, r, a) = pixel(x, y);
            var i = (y * w + x) * 4;
            px[i] = b; px[i + 1] = g; px[i + 2] = r; px[i + 3] = a;
        }
        return px;
    }

    [Fact]
    public void PixelsCompareTheVisibleImage()
    {
        var a = Image(300, 200, (x, y) => ((byte)x, (byte)y, (byte)(x ^ y), 255));
        var key = ContentKey.Pixels(a, 300, 200);
        Assert.StartsWith("p:", key);
        Assert.Equal(key, ContentKey.Pixels((byte[])a.Clone(), 300, 200));

        var oneOff = (byte[])a.Clone();
        oneOff[(150 * 300 + 299) * 4 + 1] ^= 1;
        Assert.NotEqual(key, ContentKey.Pixels(oneOff, 300, 200));

        // Same bytes, other shape: a different picture.
        Assert.NotEqual(key, ContentKey.Pixels(a, 200, 300));
    }

    [Fact]
    public void TransparentPixelsIgnoreTheirHiddenColour()
    {
        var a = Image(64, 64, (x, y) => x < 32 ? ((byte)0, (byte)0, (byte)0, (byte)0) : ((byte)10, (byte)20, (byte)30, (byte)255));
        var b = Image(64, 64, (x, y) => x < 32 ? ((byte)200, (byte)100, (byte)50, (byte)0) : ((byte)10, (byte)20, (byte)30, (byte)255));
        Assert.Equal(ContentKey.Pixels(a, 64, 64), ContentKey.Pixels(b, 64, 64));
        var c = Image(64, 64, (x, y) => x < 32 ? ((byte)0, (byte)0, (byte)0, (byte)1) : ((byte)10, (byte)20, (byte)30, (byte)255));
        Assert.NotEqual(ContentKey.Pixels(a, 64, 64), ContentKey.Pixels(c, 64, 64));
    }

    [Fact]
    public void ClipsFromHistory()
    {
        var text = new Clip("id", 1, "src", "text", Text: "a\r\nb");
        Assert.Equal(ContentKey.Text("a\nb"), ContentKey.Of(text));
        var image = new Clip("id", 1, "src", "image", Mime: "image/png", Size: 10, Sha: "ABCDEF");
        Assert.Equal("f:abcdef", ContentKey.Of(image));
        Assert.Null(ContentKey.Of(new Clip("id", 1, "src", "image")));
    }
}
