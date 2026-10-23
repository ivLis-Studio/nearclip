using System.Buffers;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace Nearclip.Core;

/// <summary>Builds wire JSON with a fixed field order (raw UTF-8, no HTML escaping) and reads it tolerantly:
/// unknown fields are ignored and <c>null</c> counts as omitted (PROTOCOL.md §0).</summary>
public static class WireJson
{
    static readonly JsonWriterOptions WriterOptions = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        Indented = false,
        SkipValidation = false,
    };

    public static byte[] Object(Action<Utf8JsonWriter> body)
    {
        var buffer = new ArrayBufferWriter<byte>(256);
        using (var w = new Utf8JsonWriter(buffer, WriterOptions))
        {
            w.WriteStartObject();
            body(w);
            w.WriteEndObject();
        }
        return buffer.WrittenSpan.ToArray();
    }

    // ---- handshake (plaintext) ----

    public static byte[] HelloMember(string id, string groupTag, byte[] e, byte[] n) => Object(w =>
    {
        w.WriteString("t", "hello"); w.WriteNumber("v", 1); w.WriteString("mode", "member"); w.WriteString("id", id);
        w.WriteString("gt", groupTag); w.WriteString("e", B64u.Encode(e)); w.WriteString("n", B64u.Encode(n));
    });

    public static byte[] HelloPairQr(string id, byte[] e, byte[] n) => Object(w =>
    {
        w.WriteString("t", "hello"); w.WriteNumber("v", 1); w.WriteString("mode", "pair-qr"); w.WriteString("id", id);
        w.WriteString("e", B64u.Encode(e)); w.WriteString("n", B64u.Encode(n));
    });

    public static byte[] HelloPairCodeJoiner(string id, byte[] e, string name, string platform) => Object(w =>
    {
        w.WriteString("t", "hello"); w.WriteNumber("v", 1); w.WriteString("mode", "pair-code"); w.WriteString("id", id);
        w.WriteString("e", B64u.Encode(e)); w.WriteString("nm", name); w.WriteString("pf", platform);
    });

    public static byte[] HelloPairCodeInviter(string id, byte[] e, byte[] commit, string name, string platform) => Object(w =>
    {
        w.WriteString("t", "hello"); w.WriteNumber("v", 1); w.WriteString("mode", "pair-code"); w.WriteString("id", id);
        w.WriteString("e", B64u.Encode(e)); w.WriteString("c", B64u.Encode(commit)); w.WriteString("nm", name); w.WriteString("pf", platform);
    });

    public static byte[] PairNonce(byte[] n) => Object(w => { w.WriteString("t", "pair_nonce"); w.WriteString("n", B64u.Encode(n)); });

    public static byte[] Error(string code, string? msg = null) => Object(w =>
    {
        w.WriteString("t", "error"); w.WriteString("code", code);
        if (msg is not null) w.WriteString("msg", msg);
    });

    // ---- session messages ----

    public static byte[] Simple(string type) => Object(w => w.WriteString("t", type));

    public static byte[] Bye(string reason) => Object(w => { w.WriteString("t", "bye"); w.WriteString("reason", reason); });

    public static byte[] Welcome(MemberRecord device, IEnumerable<MemberRecord> members, IEnumerable<Endpoint> addrs) => Object(w =>
    {
        w.WriteString("t", "welcome");
        w.WritePropertyName("device"); WriteMember(w, device);
        w.WritePropertyName("members"); WriteMembers(w, members);
        w.WriteStartArray("addrs");
        foreach (var a in addrs) { w.WriteStartObject(); w.WriteString("h", a.H); w.WriteNumber("p", a.P); w.WriteEndObject(); }
        w.WriteEndArray();
    });

    public static byte[] Inventory(IEnumerable<IdTs> clips, IEnumerable<IdTs> dels) => Object(w =>
    {
        w.WriteString("t", "inv");
        w.WritePropertyName("clips"); WriteIdTs(w, clips);
        w.WritePropertyName("dels"); WriteIdTs(w, dels);
    });

    public static byte[] Want(IEnumerable<string> ids) => Object(w =>
    {
        w.WriteString("t", "want");
        w.WriteStartArray("ids");
        foreach (var id in ids) w.WriteStringValue(id);
        w.WriteEndArray();
    });

    public static byte[] ClipMessage(Clip c, bool live) => Object(w =>
    {
        w.WriteString("t", "clip");
        w.WriteBoolean("live", live);
        w.WritePropertyName("clip"); WriteClip(w, c);
    });

    public static byte[] Delete(IEnumerable<IdTs> items) => Object(w =>
    {
        w.WriteString("t", "del");
        w.WritePropertyName("items"); WriteIdTs(w, items);
    });

    public static byte[] Members(IEnumerable<MemberRecord> members) => Object(w =>
    {
        w.WriteString("t", "members");
        w.WritePropertyName("members"); WriteMembers(w, members);
    });

    public static byte[] PairRequest(MemberRecord device) => Object(w =>
    {
        w.WriteString("t", "pair_request");
        w.WritePropertyName("device"); WriteMember(w, device);
    });

    public static byte[] PairAccept(string groupId, byte[] groupKey, MemberRecord device, IEnumerable<MemberRecord> members) => Object(w =>
    {
        w.WriteString("t", "pair_accept");
        w.WriteStartObject("group"); w.WriteString("id", groupId); w.WriteString("key", B64u.Encode(groupKey)); w.WriteEndObject();
        w.WritePropertyName("device"); WriteMember(w, device);
        w.WritePropertyName("members"); WriteMembers(w, members);
    });

    public static void WriteMember(Utf8JsonWriter w, MemberRecord m)
    {
        w.WriteStartObject();
        w.WriteString("id", m.Id);
        w.WriteString("name", m.Name);
        w.WriteString("platform", m.Platform);
        if (m.Model is not null) w.WriteString("model", m.Model);
        if (m.App is not null) w.WriteString("app", m.App);
        w.WriteNumber("addedAt", m.AddedAt);
        w.WriteNumber("updatedAt", m.UpdatedAt);
        w.WriteBoolean("removed", m.Removed);
        w.WriteEndObject();
    }

    static void WriteMembers(Utf8JsonWriter w, IEnumerable<MemberRecord> members)
    {
        w.WriteStartArray();
        foreach (var m in members) WriteMember(w, m);
        w.WriteEndArray();
    }

    public static void WriteClip(Utf8JsonWriter w, Clip c)
    {
        w.WriteStartObject();
        w.WriteString("id", c.Id);
        w.WriteNumber("ts", c.Ts);
        w.WriteString("src", c.Src);
        w.WriteString("kind", c.Kind);
        if (c.Text is not null) w.WriteString("text", c.Text);
        if (c.Mime is not null) w.WriteString("mime", c.Mime);
        if (c.Size is { } size) w.WriteNumber("size", size);
        if (c.Sha is not null) w.WriteString("sha", c.Sha);
        if (c.W is { } width) w.WriteNumber("w", width);
        if (c.H is { } height) w.WriteNumber("h", height);
        w.WriteEndObject();
    }

    static void WriteIdTs(Utf8JsonWriter w, IEnumerable<IdTs> items)
    {
        w.WriteStartArray();
        foreach (var it in items) { w.WriteStartObject(); w.WriteString("id", it.Id); w.WriteNumber("ts", it.Ts); w.WriteEndObject(); }
        w.WriteEndArray();
    }

    // ---- tolerant readers ----

    public static JsonElement? Prop(JsonElement o, string key) =>
        o.ValueKind == JsonValueKind.Object && o.TryGetProperty(key, out var v) && v.ValueKind != JsonValueKind.Null ? v : null;

    public static string? Str(JsonElement o, string key) => Prop(o, key) is { ValueKind: JsonValueKind.String } v ? v.GetString() : null;

    public static long? Long(JsonElement o, string key)
    {
        if (Prop(o, key) is not { ValueKind: JsonValueKind.Number } v) return null;
        if (v.TryGetInt64(out var l)) return l;
        if (v.TryGetDouble(out var d) && double.IsFinite(d) && Math.Abs(d) < 9.2e18) return (long)d;
        return null;
    }

    public static bool? Bool(JsonElement o, string key) => Prop(o, key) switch
    {
        { ValueKind: JsonValueKind.True } => true,
        { ValueKind: JsonValueKind.False } => false,
        _ => null,
    };

    public static IEnumerable<JsonElement> Arr(JsonElement o, string key) =>
        Prop(o, key) is { ValueKind: JsonValueKind.Array } v ? v.EnumerateArray() : Enumerable.Empty<JsonElement>();

    public static MemberRecord? ReadMember(JsonElement e)
    {
        if (e.ValueKind != JsonValueKind.Object) return null;
        var id = Ids.Norm(Str(e, "id"));
        if (id.Length == 0) return null;
        return new MemberRecord(id, Str(e, "name") ?? "", Str(e, "platform") ?? "", Str(e, "model"), Str(e, "app"),
            Long(e, "addedAt") ?? 0, Long(e, "updatedAt") ?? 0, Bool(e, "removed") ?? false);
    }

    public static List<MemberRecord> ReadMembers(JsonElement o, string key) =>
        Arr(o, key).Select(ReadMember).Where(m => m is not null).Select(m => m!).ToList();

    public static Clip? ReadClip(JsonElement e)
    {
        if (e.ValueKind != JsonValueKind.Object) return null;
        var id = Ids.Norm(Str(e, "id"));
        var kind = Str(e, "kind");
        if (id.Length == 0 || kind is null) return null;
        return new Clip(id, Long(e, "ts") ?? 0, Ids.Norm(Str(e, "src")), kind, Str(e, "text"), Str(e, "mime"), Long(e, "size"),
            Str(e, "sha")?.ToLowerInvariant(), (int?)Long(e, "w"), (int?)Long(e, "h"));
    }

    public static List<IdTs> ReadIdTs(JsonElement o, string key) =>
        Arr(o, key).Where(x => x.ValueKind == JsonValueKind.Object && Str(x, "id") is { Length: > 0 })
            .Select(x => new IdTs(Ids.Norm(Str(x, "id")), Long(x, "ts") ?? 0)).ToList();

    public static List<Endpoint> ReadEndpoints(JsonElement o, string key) =>
        Arr(o, key).Select(x => new Endpoint(Str(x, "h") ?? "", (int)(Long(x, "p") ?? 0)))
            .Where(a => a.H.Length > 0 && a.P is > 0 and < 65536).ToList();
}
