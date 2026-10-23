using System.Globalization;
using System.Text.RegularExpressions;
using Nearclip.Core;

namespace Nearclip.App.Model;

internal static partial class Format
{
    static DateTime Local(long ms) => DateTimeOffset.FromUnixTimeMilliseconds(ms).LocalDateTime;

    public static string Relative(long ms)
    {
        var delta = DateTime.Now - Local(ms);
        if (delta.TotalSeconds < 45) return Loc.S("Time_JustNow");
        if (delta.TotalMinutes < 60) return Loc.F("Time_Minutes", Math.Max(1, (int)Math.Round(delta.TotalMinutes)));
        if (delta.TotalHours < 24) return Loc.F("Time_Hours", (int)delta.TotalHours);
        var days = (DateTime.Today - Local(ms).Date).Days;
        if (days == 1) return Loc.S("Time_Yesterday");
        if (days < 7) return Loc.F("Time_Days", days);
        return Local(ms).ToString(CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "ko" ? "M월 d일" : "MMM d", CultureInfo.CurrentUICulture);
    }

    public static string LastSeen(long? ms)
    {
        if (ms is not > 0) return Loc.S("Devices_NotNearby");
        var rel = Relative(ms.Value);
        // "Last seen just now / yesterday" (English relative phrases start lowercase mid-sentence).
        if (CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "en" && rel.Length > 1 && !char.IsDigit(rel[0]))
            rel = char.ToLowerInvariant(rel[0]) + rel[1..];
        return Loc.F("Devices_LastSeen", rel);
    }

    public static string DaySection(long ms)
    {
        var d = Local(ms).Date;
        var days = (DateTime.Today - d).Days;
        if (days <= 0) return Loc.S("Section_Today");
        if (days == 1) return Loc.S("Section_Yesterday");
        var culture = CultureInfo.CurrentUICulture;
        if (days < 7) return culture.DateTimeFormat.GetDayName(d.DayOfWeek);
        return d.ToString(culture.TwoLetterISOLanguageName == "ko" ? "M월 d일 (ddd)" : "ddd, MMM d", culture);
    }

    public static string Bytes(long n)
    {
        if (n < 1024) return n + " B";
        if (n < 1024 * 1024) return (n / 1024.0).ToString("0", CultureInfo.CurrentUICulture) + " KB";
        return (n / 1048576.0).ToString("0.0", CultureInfo.CurrentUICulture) + " MB";
    }

    /// <summary>First lines of a text, trimmed, for a two-line preview.</summary>
    public static string Preview(string text, int maxLines = 2)
    {
        var lines = text.Split('\n').Select(l => l.Trim('\r', ' ', '\t')).Where(l => l.Length > 0).Take(maxLines);
        var joined = string.Join("\n", lines);
        return joined.Length > 400 ? joined[..400] + "…" : joined;
    }

    public static string GroupedCode(string code) => code.Length == 6 ? code[..3] + " " + code[3..] : code;

    public static string PlatformName(string platform, string? model = null) => platform switch
    {
        "mac" => "Mac",
        "win" => "Windows PC",
        "android" => "Android",
        "ios" => (model ?? "").StartsWith("iPad", StringComparison.Ordinal) ? "iPad" : "iPhone",
        _ => "Nearclip CLI",
    };

    /// <summary>Segoe Fluent Icons glyph for a device platform.</summary>
    public static string PlatformGlyph(string platform, string? model = null) => platform switch
    {
        "mac" => "\uE7F8",       // DeviceLaptopNoPic
        "win" => "\uE7F4",       // TVMonitor (desktop PC)
        "android" => "\uE8EA",   // CellPhone
        "ios" => (model ?? "").StartsWith("iPad", StringComparison.Ordinal) ? "\uE70A" : "\uE8EA",
        _ => "\uE756",           // CommandPrompt
    };

    [GeneratedRegex("^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$")]
    private static partial Regex HexColor();

    public static bool IsHexColor(string t) => HexColor().IsMatch(t);

    public static Windows.UI.Color? ColorFromHex(string hex)
    {
        var s = hex.Trim().TrimStart('#');
        if (s.Length == 3) s = string.Concat(s.Select(c => new string(c, 2)));
        if (s.Length is not (6 or 8) || !uint.TryParse(s, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var v)) return null;
        return s.Length == 6
            ? Windows.UI.Color.FromArgb(255, (byte)(v >> 16), (byte)(v >> 8), (byte)v)
            : Windows.UI.Color.FromArgb((byte)v, (byte)(v >> 24), (byte)(v >> 16), (byte)(v >> 8));
    }

    public static Uri? Link(string raw)
    {
        var t = raw.Trim();
        if (t.Length >= 2048 || t.Any(char.IsWhiteSpace)) return null;
        if (Uri.TryCreate(t, UriKind.Absolute, out var u) && (u.Scheme == Uri.UriSchemeHttp || u.Scheme == Uri.UriSchemeHttps) && u.Host.Length > 0) return u;
        if (t.StartsWith("www.", StringComparison.OrdinalIgnoreCase) && Uri.TryCreate("https://" + t, UriKind.Absolute, out var w) && w.Host.Contains('.')) return w;
        return null;
    }
}
