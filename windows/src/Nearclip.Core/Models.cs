using System.Text;

namespace Nearclip.Core;

public static class Wire
{
    public const int MaxFrame = 17_825_792;
    public const int ChunkSize = 1_048_576;
    public const int MaxText = 4 * 1_048_576;
    public const long MaxImage = 32 * 1_048_576;
    public const long MaxCatchUpImage = 16 * 1_048_576;
    public const byte TypeJson = 0x01;
    public const byte TypeChunk = 0x02;
    public const string ServiceType = "_nearclip._tcp";
    public const int DefaultPort = 45821;
    public const long DayMs = 86_400_000;
}

/// <summary>A listener endpoint (<c>{"h":"192.168.0.12","p":45821}</c>).</summary>
public sealed record Endpoint(string H, int P)
{
    public override string ToString() => H.Contains(':') ? $"[{H}]:{P}" : $"{H}:{P}";
}

/// <summary>A member of the group (PROTOCOL.md §1.1).</summary>
public sealed record MemberRecord(
    string Id,
    string Name,
    string Platform,
    string? Model,
    string? App,
    long AddedAt,
    long UpdatedAt,
    bool Removed);

/// <summary>Wire form of a clip (PROTOCOL.md §6.1). <see cref="Otp"/>: a verification code a phone found in a message
/// (§6.7), offered rather than copied by the devices that receive it.</summary>
public sealed record Clip(
    string Id,
    long Ts,
    string Src,
    string Kind,
    string? Text = null,
    string? Mime = null,
    long? Size = null,
    string? Sha = null,
    int? W = null,
    int? H = null,
    bool? Otp = null,
    string[]? Recipients = null)
{
    public bool IsImage => Kind == "image";
    public bool IsText => Kind == "text";
    public bool IsCode => Otp == true && IsText;
    public bool IsAddressedTo(string device) => Recipients is null || Recipients.Contains(device) || Src == device;
    public bool IsExpired(long now) => IsCode && (Ts <= now - 180_000 || Ts > now + 60_000);
}

/// <summary>A clip in local history. <see cref="GroupId"/> is the group it belongs to; <see cref="LocalOnly"/> clips
/// (too large to sync) are never advertised.</summary>
public sealed record StoredClip(
    Clip Clip,
    string GroupId,
    bool Pinned,
    long ReceivedAt,
    string? SrcName,
    string? SrcPlatform,
    bool LocalOnly = false)
{
    public string Id => Clip.Id;
}

public sealed record IdTs(string Id, long Ts);

public sealed record NearbyDevice(string Id, string Name, string Platform, bool PairingMode);

public sealed record PairPrompt(string PeerId, string Name, string Platform, string Code);

/// <summary><c>nearclip://pair?…</c> (PROTOCOL.md §5.1).</summary>
public sealed record PairingInvite(string InviterId, string Name, string Platform, IReadOnlyList<string> Hosts, int Port, byte[] Secret)
{
    static string Enc(string s) => Uri.EscapeDataString(s);

    public string ToUri()
    {
        var sb = new StringBuilder("nearclip://pair?v=1");
        sb.Append("&id=").Append(Enc(InviterId));
        sb.Append("&nm=").Append(Enc(Name));
        sb.Append("&pf=").Append(Enc(Platform));
        sb.Append("&h=").Append(string.Join(",", Hosts.Select(Enc)));
        sb.Append("&p=").Append(Port);
        sb.Append("&s=").Append(B64u.Encode(Secret));
        return sb.ToString();
    }

    /// <summary>Parses a pairing link. Returns null when it is not a valid v1 link.</summary>
    public static PairingInvite? TryParse(string? uri)
    {
        if (string.IsNullOrWhiteSpace(uri)) return null;
        var s = uri.Trim();
        const string prefix = "nearclip://pair";
        if (!s.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return null;
        var rest = s[prefix.Length..];
        if (rest.StartsWith('/')) rest = rest[1..];
        if (!rest.StartsWith('?')) return null;
        var q = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var part in rest[1..].Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var eq = part.IndexOf('=');
            var k = eq < 0 ? part : part[..eq];
            var v = eq < 0 ? "" : part[(eq + 1)..];
            try { q[Uri.UnescapeDataString(k)] = Uri.UnescapeDataString(v); }
            catch (UriFormatException) { return null; }
        }
        if (!q.TryGetValue("v", out var ver) || ver != "1") return null;
        if (!q.TryGetValue("id", out var id) || string.IsNullOrWhiteSpace(id)) return null;
        if (!q.TryGetValue("p", out var ps) || !int.TryParse(ps, out var port) || port is < 1 or > 65535) return null;
        var secret = B64u.Decode(q.GetValueOrDefault("s"));
        if (secret is null || secret.Length < 16) return null;
        var hosts = (q.GetValueOrDefault("h") ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        return new PairingInvite(Ids.Norm(id), q.GetValueOrDefault("nm") ?? "", q.GetValueOrDefault("pf") ?? "", hosts, port, secret);
    }
}

public sealed record PairingTicket(PairingInvite Invite, DateTimeOffset ExpiresAt)
{
    public string Uri => Invite.ToUri();
}

/// <summary>Everything the engine reports. Delivered in order on the node's event thread.</summary>
public abstract record NodeEvent
{
    public sealed record Ready(int Port, string GroupId, string GroupTag) : NodeEvent;
    public sealed record TicketCreated(PairingTicket Ticket) : NodeEvent;
    public sealed record TicketExpired : NodeEvent;
    /// <summary>Joiner side of code pairing: show this code and wait.</summary>
    public sealed record PairCode(string Code, string PeerName, string PeerPlatform) : NodeEvent;
    /// <summary>Inviter side of code pairing: ask the user.</summary>
    public sealed record PairPromptShown(PairPrompt Prompt) : NodeEvent;
    public sealed record PairPromptDismissed : NodeEvent;
    public sealed record Paired(string GroupId, string PeerId, string PeerName, string PeerPlatform, bool Joined) : NodeEvent;
    public sealed record PairFailed(string Reason, string? PeerName) : NodeEvent;
    public sealed record PeerUp(MemberRecord Member, PeerRoute Route = PeerRoute.Lan) : NodeEvent;
    public sealed record PeerDown(string Id) : NodeEvent;
    /// <summary><paramref name="Local"/>: produced on this device. <paramref name="Apply"/>: a live clip from another device
    /// that is newer than anything copied here, i.e. it should go to the system clipboard.</summary>
    public sealed record ClipAdded(StoredClip Clip, bool Live, bool Apply, bool Local) : NodeEvent;
    /// <summary>Progress of a live image from another device (PROTOCOL.md §6.6).</summary>
    public sealed record TransferChanged(IncomingTransfer Transfer) : NodeEvent;
    public sealed record ClipsDeleted(IReadOnlyList<string> Ids) : NodeEvent;
    public sealed record ClipUpdated(StoredClip Clip) : NodeEvent;
    /// <summary>A clip made on this device went out to <paramref name="Devices"/> connected devices.</summary>
    public sealed record Sent(string ClipId, int Devices) : NodeEvent;
    public sealed record MembersChanged(IReadOnlyList<MemberRecord> Members) : NodeEvent;
    public sealed record NearbyChanged(IReadOnlyList<NearbyDevice> Nearby) : NodeEvent;
    public sealed record Left(string Reason) : NodeEvent;
    public sealed record TooLarge(string Kind) : NodeEvent;
    public sealed record PausedChanged(bool Paused) : NodeEvent;
    /// <summary>The embedded Tailscale node changed state (remote connection).</summary>
    public sealed record TailnetChanged(TailnetStatus Status) : NodeEvent;
    public sealed record Log(string Message) : NodeEvent;
}

public enum TransferState
{
    /// <summary>Announced: the other device is still encoding the image (<c>Total</c> is 0).</summary>
    Preparing,
    Receiving,
    /// <summary>Ended without the clip: <c>Reason</c> is cancelled, disconnected, corrupt or timeout.</summary>
    Failed,
}

/// <summary>A live image arriving from another device (PROTOCOL.md §6.6), for progress UI. A transfer ends with the clip's
/// <see cref="NodeEvent.ClipAdded"/> or with <see cref="TransferState.Failed"/>.</summary>
/// <param name="Id">Id of the clip being transferred.</param>
/// <param name="From">The device the image was copied on.</param>
public sealed record IncomingTransfer(string Id, string From, TransferState State, long Received, long Total, string? Reason = null)
{
    /// <summary>0…1, or null while the size is unknown.</summary>
    public double? Fraction => Total > 0 ? Math.Min(1.0, (double)Received / Total) : null;

    public string StateName => State switch
    {
        TransferState.Preparing => "preparing",
        TransferState.Receiving => "receiving",
        _ => "failed",
    };
}

public sealed record NodeSnapshot(
    string DeviceId,
    string DeviceName,
    string Platform,
    string GroupId,
    string GroupTag,
    IReadOnlyList<MemberRecord> Members,
    IReadOnlySet<string> Online,
    IReadOnlyDictionary<string, long> LastSeen,
    IReadOnlyList<StoredClip> History,
    IReadOnlyList<NearbyDevice> Nearby,
    int Port,
    bool Paused,
    bool PairingMode,
    IReadOnlyList<string> Addresses,
    /// <summary>Route of every connected member.</summary>
    IReadOnlyDictionary<string, PeerRoute> Routes,
    bool RemoteEnabled,
    TailnetStatus Tailnet);
