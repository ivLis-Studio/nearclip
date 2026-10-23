using Microsoft.UI.Xaml.Markup;
using Microsoft.Windows.ApplicationModel.Resources;

namespace Nearclip.App.Model;

/// <summary>Strings from Strings/&lt;lang&gt;/Resources.resw (MRT Core).</summary>
/// <remarks>
/// XAML line breaking treats every Hangul syllable as a break opportunity, so Korean paragraphs would wrap in the
/// middle of words. <see cref="S"/> applies "keep-all" wrapping (as Apple platforms do) by joining the characters of
/// each Korean word with U+2060 WORD JOINER, which is invisible and ignored by screen readers. Use <see cref="Raw"/>
/// for native Win32 surfaces (tray menu, tooltip).
/// </remarks>
internal static class Loc
{
    static ResourceLoader? s_loader;

    static ResourceLoader Loader => s_loader ??= new ResourceLoader();

    public const char WordJoiner = '\u2060';

    public static string S(string key) => KeepAll(Raw(key));

    public static string Raw(string key)
    {
        try
        {
            var v = Loader.GetString(key);
            return string.IsNullOrEmpty(v) ? key : v;
        }
        catch (Exception) { return key; }
    }

    public static string F(string key, params object[] args)
    {
        try { return string.Format(System.Globalization.CultureInfo.CurrentUICulture, S(key), args); }
        catch (FormatException) { return S(key); }
    }

    /// <summary>Removes the word joiners added by <see cref="S"/> (for Win32 text such as the tray tooltip).</summary>
    public static string Plain(string s) => s.Contains(WordJoiner) ? s.Replace(WordJoiner.ToString(), "") : s;

    /// <summary>Prevents line breaks inside words that contain Hangul (CSS <c>word-break: keep-all</c>).</summary>
    public static string KeepAll(string s)
    {
        System.Text.StringBuilder? sb = null;
        for (var i = 1; i < s.Length; i++)
        {
            char a = s[i - 1], b = s[i];
            var join = !char.IsWhiteSpace(a) && !char.IsWhiteSpace(b) && a != WordJoiner && (IsHangul(a) || IsHangul(b))
                       && !char.IsHighSurrogate(a);
            if (join)
            {
                sb ??= new System.Text.StringBuilder(s, 0, i, s.Length + s.Length / 2);
                sb.Append(WordJoiner);
            }
            sb?.Append(b);
        }
        return sb?.ToString() ?? s;
    }

    /// <summary><see cref="KeepAll"/> for user content (display only): words longer than <paramref name="maxWord"/>
    /// characters stay breakable so they still wrap inside narrow rows.</summary>
    public static string KeepAllWords(string s, int maxWord = 16)
    {
        var sb = new System.Text.StringBuilder(s.Length + s.Length / 2);
        var i = 0;
        while (i < s.Length)
        {
            var start = i;
            var space = char.IsWhiteSpace(s[i]);
            while (i < s.Length && char.IsWhiteSpace(s[i]) == space) i++;
            var token = s[start..i];
            sb.Append(!space && token.Length <= maxWord ? KeepAll(token) : token);
        }
        return sb.ToString();
    }

    static bool IsHangul(char c) => c is (>= '\uAC00' and <= '\uD7A3') or (>= '\u1100' and <= '\u11FF') or (>= '\u3130' and <= '\u318F');
}

/// <summary><c>{m:Str Key=…}</c> markup extension for XAML text.</summary>
[MarkupExtensionReturnType(ReturnType = typeof(string))]
public sealed partial class Str : MarkupExtension
{
    public string Key { get; set; } = "";
    protected override object ProvideValue() => Loc.S(Key);
}
