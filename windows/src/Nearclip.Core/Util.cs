using System.Text;

namespace Nearclip.Core;

/// <summary>base64url without padding (RFC 4648 §5). Decoding accepts input with or without padding.</summary>
public static class B64u
{
    public static string Encode(ReadOnlySpan<byte> data) =>
        Convert.ToBase64String(data).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    public static byte[]? Decode(string? s)
    {
        if (s is null) return null;
        var t = s.Trim().Replace('-', '+').Replace('_', '/').TrimEnd('=');
        switch (t.Length % 4)
        {
            case 1: return null;
            case 2: t += "=="; break;
            case 3: t += "="; break;
        }
        try { return Convert.FromBase64String(t); }
        catch (FormatException) { return null; }
    }
}

public static class Hex
{
    public static string Encode(ReadOnlySpan<byte> data) => Convert.ToHexStringLower(data);

    public static byte[]? Decode(string? s)
    {
        if (s is null || s.Length % 2 != 0) return null;
        try { return Convert.FromHexString(s); }
        catch (FormatException) { return null; }
    }
}

public static class Clock
{
    /// <summary>Unix epoch milliseconds.</summary>
    public static long NowMs() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
}

public static class Ids
{
    /// <summary>Lowercase RFC 4122 UUID string (PROTOCOL.md §0).</summary>
    public static string New() => Guid.NewGuid().ToString("D").ToLowerInvariant();

    public static string Norm(string? id) => (id ?? "").Trim().ToLowerInvariant();
}

internal static class Utf8
{
    public static byte[] Bytes(string s) => Encoding.UTF8.GetBytes(s);

    /// <summary>At most <paramref name="max"/> user-perceived characters, never splitting a surrogate pair or cluster.</summary>
    public static string TruncateChars(string s, int max)
    {
        var info = new System.Globalization.StringInfo(s);
        return info.LengthInTextElements <= max ? s : info.SubstringByTextElements(0, max);
    }

    /// <summary>Truncates to at most <paramref name="limit"/> UTF-8 bytes on a character (text element) boundary.</summary>
    public static string Truncate(string s, int limit)
    {
        if (Encoding.UTF8.GetByteCount(s) <= limit) return s;
        var sb = new StringBuilder();
        var used = 0;
        var e = System.Globalization.StringInfo.GetTextElementEnumerator(s);
        while (e.MoveNext())
        {
            var el = e.GetTextElement();
            var n = Encoding.UTF8.GetByteCount(el);
            if (used + n > limit) break;
            sb.Append(el);
            used += n;
        }
        return sb.ToString();
    }
}

public enum ErrorKind { Protocol, Crypto, Remote, Io, Timeout, Cancelled }

/// <summary>Engine error. <see cref="Code"/> is the short machine-readable form used by the CLI and the UI.</summary>
public sealed class NearclipException : Exception
{
    public ErrorKind Kind { get; }
    public string Detail { get; }

    public NearclipException(ErrorKind kind, string detail = "") : base(kind + (detail.Length > 0 ? ": " + detail : ""))
    {
        Kind = kind;
        Detail = detail;
    }

    public string Code => Kind switch
    {
        ErrorKind.Remote => Detail,
        ErrorKind.Timeout => "timeout",
        ErrorKind.Cancelled => "cancelled",
        ErrorKind.Io => "io",
        ErrorKind.Crypto => "crypto",
        _ => "protocol",
    };

    public static NearclipException Protocol(string s) => new(ErrorKind.Protocol, s);
    public static NearclipException Crypto(string s) => new(ErrorKind.Crypto, s);
    public static NearclipException Remote(string code) => new(ErrorKind.Remote, code);
    public static NearclipException Io(string s) => new(ErrorKind.Io, s);
    public static NearclipException TimedOut() => new(ErrorKind.Timeout);
}
