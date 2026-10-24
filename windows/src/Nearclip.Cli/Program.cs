// Headless Nearclip peer for cross-implementation tests (PROTOCOL.md §9).
//   Nearclip.Cli --state <dir> --name <name> [--port <n>] [--tailnet <dir> [--tailnet-control <url>]]
// One JSON event per line on stdout, one JSON command per line on stdin, free-form log on stderr.
using System.Buffers;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using Nearclip.Core;

string? stateDir = null;
var name = "Nearclip CLI";
var port = 0;
string? tailnetDir = null;
string? tailnetControl = null;
for (var i = 0; i < args.Length; i++)
{
    switch (args[i])
    {
        case "--state" when i + 1 < args.Length: stateDir = args[++i]; break;
        case "--name" when i + 1 < args.Length: name = args[++i]; break;
        case "--port" when i + 1 < args.Length: port = int.TryParse(args[++i], out var p) ? p : 0; break;
        case "--tailnet" when i + 1 < args.Length: tailnetDir = args[++i]; break;
        case "--tailnet-control" when i + 1 < args.Length: tailnetControl = args[++i]; break;
        default: Usage(); break;
    }
}
if (stateDir is null) Usage();

var stdout = Console.OpenStandardOutput();
var outLock = new object();
var writerOptions = new JsonWriterOptions { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

void Emit(Action<Utf8JsonWriter> body)
{
    var buffer = new ArrayBufferWriter<byte>();
    using (var w = new Utf8JsonWriter(buffer, writerOptions))
    {
        w.WriteStartObject();
        body(w);
        w.WriteEndObject();
    }
    lock (outLock)
    {
        stdout.Write(buffer.WrittenSpan);
        stdout.WriteByte((byte)'\n');
        stdout.Flush();
    }
}

void Log(string s) => Console.Error.WriteLine(s);

void WriteClip(Utf8JsonWriter w, Clip c, bool? live)
{
    w.WriteString("id", c.Id);
    w.WriteString("src", c.Src);
    w.WriteString("kind", c.Kind);
    if (live is { } l) w.WriteBoolean("live", l);
    w.WriteNumber("ts", c.Ts);
    if (c.Text is not null) w.WriteString("text", c.Text);
    if (c.Size is { } size) w.WriteNumber("size", size);
    if (c.Sha is not null) w.WriteString("sha", c.Sha);
    if (c.Mime is not null) w.WriteString("mime", c.Mime);
}

void WriteMembers(Utf8JsonWriter w, IEnumerable<MemberRecord> members)
{
    w.WriteStartArray("members");
    foreach (var m in members) WireJson.WriteMember(w, m);
    w.WriteEndArray();
}

NearclipNode node;
try
{
    node = new NearclipNode(new NearclipNode.Options
    {
        StateDirectory = Path.GetFullPath(stateDir!),
        DeviceName = name,
        Platform = "cli",
        AppVersion = "1.0.0",
        Model = "dotnet",
        Port = port,
        SecretStore = new FileSecretStore(Path.Combine(Path.GetFullPath(stateDir!), "secrets")),
        Tailnet = tailnetDir is null ? null : new TailnetOptions(Path.GetFullPath(tailnetDir), tailnetControl,
            Path.Combine(Path.GetFullPath(tailnetDir), "tailnet.log"), TestMode: tailnetControl is not null),
    });
}
catch (Exception e)
{
    Log("init failed: " + e);
    return 1;
}

void EmitTailnet(TailnetStatus st) => Emit(w =>
{
    w.WriteString("ev", "tailnet"); w.WriteString("state", st.State); w.WriteString("ip", st.Ip ?? ""); w.WriteNumber("peers", st.Peers.Count);
});
var lastTailnet = "";

node.Event += ev =>
{
    switch (ev)
    {
        case NodeEvent.Ready r:
            Emit(w => { w.WriteString("ev", "ready"); w.WriteString("id", node.DeviceId); w.WriteNumber("port", r.Port); w.WriteString("group", r.GroupId); w.WriteString("gt", r.GroupTag); });
            break;
        case NodeEvent.TicketCreated t:
            Emit(w => { w.WriteString("ev", "ticket"); w.WriteString("uri", t.Ticket.Uri); });
            break;
        case NodeEvent.PairCode c:
            Emit(w => { w.WriteString("ev", "pair_sas"); w.WriteString("sas", c.Code); });
            break;
        case NodeEvent.PairPromptShown p:
            Emit(w => { w.WriteString("ev", "pair_prompt"); w.WriteString("peer", p.Prompt.PeerId); w.WriteString("name", p.Prompt.Name); w.WriteString("sas", p.Prompt.Code); });
            break;
        case NodeEvent.Paired p:
            Emit(w => { w.WriteString("ev", "paired"); w.WriteString("group", p.GroupId); w.WriteString("peer", p.PeerId); });
            break;
        case NodeEvent.PairFailed f:
            Emit(w => { w.WriteString("ev", "pair_failed"); w.WriteString("reason", f.Reason); });
            break;
        case NodeEvent.PeerUp u:
            Emit(w =>
            {
                w.WriteString("ev", "peer_up"); w.WriteString("id", u.Member.Id); w.WriteString("name", u.Member.Name);
                w.WriteString("route", u.Route == PeerRoute.Remote ? "remote" : "lan");
            });
            break;
        case NodeEvent.PeerDown d:
            Emit(w => { w.WriteString("ev", "peer_down"); w.WriteString("id", d.Id); });
            break;
        case NodeEvent.ClipAdded { Local: false } a:
            Emit(w => { w.WriteString("ev", "clip"); WriteClip(w, a.Clip.Clip, a.Live); });
            break;
        case NodeEvent.ClipsDeleted d:
            foreach (var id in d.Ids) Emit(w => { w.WriteString("ev", "deleted"); w.WriteString("id", id); });
            break;
        case NodeEvent.MembersChanged m:
            Emit(w => { w.WriteString("ev", "members"); WriteMembers(w, m.Members); });
            break;
        case NodeEvent.Left l:
            Emit(w => { w.WriteString("ev", "left"); w.WriteString("reason", l.Reason); });
            break;
        case NodeEvent.TooLarge t:
            Emit(w => { w.WriteString("ev", "error"); w.WriteString("msg", "too large: " + t.Kind); });
            break;
        case NodeEvent.TailnetChanged tc:
        {
            var key = $"{tc.Status.State}|{tc.Status.Ip}|{tc.Status.Peers.Count}";
            if (key != lastTailnet)
            {
                lastTailnet = key;
                EmitTailnet(tc.Status);
            }
            break;
        }
        case NodeEvent.Log l:
            Log(l.Message);
            break;
    }
};

if (node.Snapshot().DeviceName != name) node.Rename(name);
if (tailnetDir is not null) node.SetRemoteEnabled(true);
node.Start();

var quitting = 0;
void Quit()
{
    if (Interlocked.Exchange(ref quitting, 1) != 0) return;
    node.Stop();
    Thread.Sleep(200);
    Environment.Exit(0);
}

void Handle(string cmd, JsonElement o)
{
    switch (cmd)
    {
        case "ticket":
            node.CreateTicket();
            break;
        case "pair_qr":
            if (PairingInvite.TryParse(WireJson.Str(o, "uri")) is { } invite) node.Join(invite);
            else Emit(w => { w.WriteString("ev", "pair_failed"); w.WriteString("reason", "bad_uri"); });
            break;
        case "pair_code":
            if (WireJson.Str(o, "host") is { } host && WireJson.Long(o, "port") is { } pc) node.PairWithCode(host, (int)pc);
            else Emit(w => { w.WriteString("ev", "error"); w.WriteString("msg", "pair_code needs host and port"); });
            break;
        case "accept":
            node.AnswerPairPrompt(true, WireJson.Str(o, "peer"));
            break;
        case "decline":
            node.AnswerPairPrompt(false, WireJson.Str(o, "peer"));
            break;
        case "connect":
            if (WireJson.Str(o, "host") is { } h && WireJson.Long(o, "port") is { } cp) node.Connect(h, (int)cp);
            else Emit(w => { w.WriteString("ev", "error"); w.WriteString("msg", "connect needs host and port"); });
            break;
        case "send_text":
            if (WireJson.Str(o, "text") is { } text) node.SendText(text);
            break;
        case "send_image":
        {
            var path = WireJson.Str(o, "path");
            byte[]? data = null;
            try { if (path is not null) data = File.ReadAllBytes(path); } catch (Exception) { }
            if (data is null) { Emit(w => { w.WriteString("ev", "error"); w.WriteString("msg", "cannot read image"); }); break; }
            node.SendImage(data, WireJson.Str(o, "mime") ?? "image/png");
            break;
        }
        case "delete":
            if (WireJson.Str(o, "id") is { } did) node.Delete([did]);
            break;
        case "remove":
            if (WireJson.Str(o, "peer") is { } peer) node.RemoveMember(peer);
            break;
        case "rename":
            if (WireJson.Str(o, "name") is { } n) node.Rename(n);
            break;
        case "list":
        {
            var snap = node.Snapshot();
            var clips = snap.History.Where(c => c.GroupId == snap.GroupId && !c.LocalOnly).ToList();
            Emit(w =>
            {
                w.WriteString("ev", "history");
                w.WriteStartArray("clips");
                foreach (var c in clips) { w.WriteStartObject(); WriteClip(w, c.Clip, null); w.WriteEndObject(); }
                w.WriteEndArray();
            });
            break;
        }
        case "members":
        {
            var snap = node.Snapshot();
            Emit(w => { w.WriteString("ev", "members"); WriteMembers(w, snap.Members); });
            break;
        }
        case "tailnet":
            EmitTailnet(node.Snapshot().Tailnet);
            break;
        case "quit":
            Quit();
            break;
        default:
            Emit(w => { w.WriteString("ev", "error"); w.WriteString("msg", "unknown command " + cmd); });
            break;
    }
}

Console.CancelKeyPress += (_, e) => { e.Cancel = true; Quit(); };
var stdin = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false));
while (stdin.ReadLine() is { } line)
{
    var trimmed = line.Trim();
    if (trimmed.Length == 0) continue;
    try
    {
        using var doc = JsonDocument.Parse(trimmed);
        if (WireJson.Str(doc.RootElement, "cmd") is not { } cmd)
        {
            Emit(w => { w.WriteString("ev", "error"); w.WriteString("msg", "bad command"); });
            continue;
        }
        Handle(cmd, doc.RootElement);
    }
    catch (JsonException)
    {
        Emit(w => { w.WriteString("ev", "error"); w.WriteString("msg", "bad command"); });
    }
}
Quit();
return 0;

static void Usage()
{
    Console.Error.WriteLine("usage: Nearclip.Cli --state <dir> --name <name> [--port <n>]");
    Environment.Exit(2);
}
