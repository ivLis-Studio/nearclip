using Nearclip.Core;

namespace Nearclip.App.Model;

public enum HistoryFilter { All, Text, Links, Images, Pinned }

public enum ClipKind { Text, Link, Color, Image }

/// <summary>A history row: newest clip of a set with identical content (deleting the row deletes all of them).</summary>
public sealed class ClipItem
{
    public StoredClip Clip { get; init; } = null!;
    public List<string> Ids { get; } = [];
    public bool Pinned { get; set; }
    /// <summary>Position in the visible list (0-based) for the Ctrl+1…9 hints; -1 when not shown.</summary>
    public int Index { get; set; } = -1;
    public string Id => Clip.Id;

    ClipKind? _kind;
    Uri? _link;

    public ClipKind Kind
    {
        get
        {
            if (_kind is { } k) return k;
            if (Clip.Clip.IsImage) _kind = ClipKind.Image;
            else
            {
                var t = (Clip.Clip.Text ?? "").Trim();
                if (Format.IsHexColor(t)) _kind = ClipKind.Color;
                else if ((_link = Format.Link(t)) is not null) _kind = ClipKind.Link;
                else _kind = ClipKind.Text;
            }
            return _kind.Value;
        }
    }

    public Uri? Link => Kind == ClipKind.Link ? _link : null;

    public string Text => Clip.Clip.Text ?? "";

    public bool Matches(HistoryFilter filter) => filter switch
    {
        HistoryFilter.Text => Kind is ClipKind.Text or ClipKind.Color,
        HistoryFilter.Links => Kind == ClipKind.Link,
        HistoryFilter.Images => Kind == ClipKind.Image,
        HistoryFilter.Pinned => Pinned,
        _ => true,
    };

    public bool LooksLikeCode
    {
        get
        {
            var lines = Text.Split('\n');
            if (lines.Length < 2) return false;
            return lines.Take(6).Count(l => l.StartsWith("  ") || l.StartsWith('\t') || l.TrimEnd().EndsWith('{') ||
                                            l.TrimEnd().EndsWith(';') || l.TrimEnd().EndsWith(')')) >= 2;
        }
    }
}

/// <summary>A day group of the history list.</summary>
public sealed class ClipGroup : List<ClipItem>
{
    public ClipGroup(string title, IEnumerable<ClipItem> items) : base(items) => Title = title;
    public string Title { get; }
    public override string ToString() => Title;
}
