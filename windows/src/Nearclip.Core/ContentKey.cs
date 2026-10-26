using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;

namespace Nearclip.Core;

/// <summary>
/// What a clip holds, so that the same thing put on the clipboard again is not taken for a new copy (DESIGN.md §4.3):
/// a screenshot tool that sets its picture twice, or another sync app (a phone link, Universal Clipboard) that puts back
/// what Nearclip just delivered. Text compares with line endings, Unicode composition and trailing whitespace evened
/// out; an image by its pixels, so the same picture as a bitmap and as a PNG is one image. A clip in history, known only
/// by its file, compares by the file's SHA-256. Keys are only compared on the device that made them.
/// </summary>
public static class ContentKey
{
    /// <summary>Line endings as <c>\n</c>, composed Unicode (NFC), no trailing spaces, tabs or line breaks.</summary>
    public static string NormalizeText(string text)
    {
        var s = text.Contains('\r') ? text.Replace("\r\n", "\n").Replace('\r', '\n') : text;
        try
        {
            if (!s.IsNormalized(NormalizationForm.FormC)) s = s.Normalize(NormalizationForm.FormC);
        }
        catch (ArgumentException)
        {
            // Ill-formed UTF-16 (a lone surrogate) cannot be normalized: compare it as it is.
        }
        return s.TrimEnd(' ', '\t', '\n', '\f', '\v');
    }

    public static string Text(string text) => "t:" + Hex.Encode(SHA256.HashData(Encoding.UTF8.GetBytes(NormalizeText(text))));

    /// <summary>Top-down BGRA with straight alpha. Fully transparent pixels count as transparent black, whatever colour
    /// they carry.</summary>
    public static string Pixels(ReadOnlySpan<byte> bgra, int width, int height)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        Span<byte> size = stackalloc byte[8];
        BinaryPrimitives.WriteInt32LittleEndian(size, width);
        BinaryPrimitives.WriteInt32LittleEndian(size[4..], height);
        hash.AppendData(size);
        var length = (int)Math.Min(bgra.Length / 4, Math.Max(0L, (long)width * height)) * 4;
        var buffer = new byte[64 * 1024];
        var n = 0;
        for (var i = 0; i < length; i += 4)
        {
            if (bgra[i + 3] == 0)
            {
                buffer[n] = buffer[n + 1] = buffer[n + 2] = buffer[n + 3] = 0;
            }
            else
            {
                buffer[n] = bgra[i];
                buffer[n + 1] = bgra[i + 1];
                buffer[n + 2] = bgra[i + 2];
                buffer[n + 3] = bgra[i + 3];
            }
            n += 4;
            if (n == buffer.Length)
            {
                hash.AppendData(buffer);
                n = 0;
            }
        }
        if (n > 0) hash.AppendData(buffer.AsSpan(0, n));
        return "p:" + Hex.Encode(hash.GetHashAndReset());
    }

    /// <summary>A clip in history: its text, or its image file's SHA-256 (null when neither is known).</summary>
    public static string? Of(Clip clip) =>
        clip.IsText ? Text(clip.Text ?? "") : clip.Sha is { Length: > 0 } sha ? "f:" + sha.ToLowerInvariant() : null;
}
