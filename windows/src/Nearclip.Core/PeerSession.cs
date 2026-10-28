using System.Buffers.Binary;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using static Nearclip.Core.WireJson;

namespace Nearclip.Core;

internal sealed class PendingBlob(Clip clip, bool live)
{
    public Clip Clip { get; } = clip;
    public bool Live { get; } = live;
    public MemoryStream Data { get; } = new((int)Math.Min(clip.Size ?? 0, Wire.MaxImage));
    public uint Next { get; set; }
}

internal sealed record PairAcceptInfo(string GroupId, byte[] Key, MemberRecord Device, List<MemberRecord> Members);

internal sealed record PairOutcome(PairAcceptInfo? Accept, NearclipException? Error);

/// <summary>One TCP connection: handshake (member / pair-qr / pair-code) and the encrypted message stream.
/// All state lives on the node queue; only socket reads/writes run elsewhere.</summary>
internal sealed class PeerSession
{
    public enum SessionRole { Client, Server }
    public enum SessionMode { None, Member, PairQr, PairCode }
    public enum SessionPhase { Connecting, AwaitHello, AwaitNonce, AwaitPairRequest, AwaitDecision, AwaitPairResult, Established, Closed }

    sealed record OutFrame(byte[] Bytes, bool CloseAfter);

    readonly NearclipNode _node;
    readonly IReadOnlyList<DialCandidate> _targets;
    readonly EphemeralKey _eph = new();
    readonly byte[] _myNonce = NcCrypto.Random(16);
    readonly Channel<OutFrame> _outbox = Channel.CreateUnbounded<OutFrame>(new UnboundedChannelOptions { SingleReader = true });
    readonly CancellationTokenSource _cts = new();
    readonly TaskCompletionSource _drained = new(TaskCreationOptions.RunContinuationsAsynchronously);
    byte[] _myHello = [];
    byte[] _peerHello = [];
    byte[] _peerEph = [];
    byte[]? _commitment;
    FrameCipher? _send;
    FrameCipher? _recv;
    Socket? _socket;
    Task _readTask = Task.CompletedTask;
    bool _closed;
    bool _closing;
    int _socketDisposed;

    public SessionRole Role { get; }
    public SessionMode Mode { get; private set; }
    public SessionPhase Phase { get; private set; }
    public DateTime Created { get; } = DateTime.UtcNow;
    public bool Retired { get; set; }
    public bool SupportsPolicies { get; set; }
    public bool SupportsRekey { get; set; }
    public string? PeerId { get; private set; }
    public string? PeerName { get; private set; }
    public string? PeerPlatform { get; private set; }
    public MemberRecord? PeerRecord { get; private set; }
    public string? ExpectedPeerId { get; init; }
    public Endpoint? DialedEndpoint { get; private set; }
    /// <summary>Accepted from the tailnet bridge's loopback forwarder (its remote address is meaningless).</summary>
    public bool ViaTailnet { get; }
    /// <summary>The session runs over the tailnet (PROTOCOL.md §10.3).</summary>
    public PeerRoute Route { get; private set; }
    public bool ReceivedWelcome { get; private set; }
    public bool GotPeerHello { get; private set; }
    public byte[]? PairSecret { get; set; }
    public string? Sas { get; private set; }
    public string? RemoteHost { get; private set; }
    public Action<PairOutcome>? OnPairResult { get; set; }
    public Dictionary<string, PendingBlob> PendingBlobs { get; } = new();
    public HashSet<string> SkipBlobs { get; } = new();
    public DateTime LastSent { get; private set; } = DateTime.UtcNow;
    public DateTime LastReceived { get; private set; } = DateTime.UtcNow;
    public NearclipException? CloseError { get; private set; }
    public Task Drained => _drained.Task;

    public bool IsClosed => _closed;
    public bool IsClosing => _closing || _closed;
    /// <summary>Set when this device switched groups: anything still arriving on the session belongs to the old group.</summary>
    public bool Detached { get; set; }
    public bool IsMember => Mode == SessionMode.Member && Phase == SessionPhase.Established && !_closed && !_closing;
    public bool IsPairing => Mode is SessionMode.PairQr or SessionMode.PairCode;
    public IEnumerable<Endpoint> Targets => _targets.Select(t => t.Address);

    /// <summary>Client (dialer).</summary>
    public PeerSession(NearclipNode node, SessionMode mode, IReadOnlyList<DialCandidate> targets)
    {
        _node = node;
        _targets = targets;
        Role = SessionRole.Client;
        Mode = mode;
        Phase = SessionPhase.Connecting;
    }

    /// <summary>Server (accepted connection).</summary>
    public PeerSession(NearclipNode node, Socket accepted, bool viaTailnet = false)
    {
        _node = node;
        _targets = [];
        _socket = accepted;
        Role = SessionRole.Server;
        Mode = SessionMode.None;
        Phase = SessionPhase.AwaitHello;
        RemoteHost = Dialer.RemoteHost(accepted);
        ViaTailnet = viaTailnet;
        Route = viaTailnet || TailnetAddress.Contains(RemoteHost) ? PeerRoute.Remote : PeerRoute.Lan;
        Dialer.Configure(accepted);
    }

    static string ModeName(SessionMode m) => m switch
    {
        SessionMode.Member => "member",
        SessionMode.PairQr => "pair-qr",
        SessionMode.PairCode => "pair-code",
        _ => "",
    };

    // ---------------------------------------------------------------- lifecycle (node queue)

    public void Start()
    {
        if (Role == SessionRole.Server)
        {
            StartIo();
            return;
        }
        _ = Task.Run(async () =>
        {
            try
            {
                var (socket, winner) = await Dialer.RaceAsync(_targets, TimeSpan.FromSeconds(6), _cts.Token).ConfigureAwait(false);
                _node.Q.Post(() =>
                {
                    if (_closed) { socket.Dispose(); return; }
                    _socket = socket;
                    DialedEndpoint = winner.Address;
                    Route = winner.Remote ? PeerRoute.Remote : PeerRoute.Lan;
                    RemoteHost = Dialer.RemoteHost(socket);
                    StartIo();
                    Connected();
                });
            }
            catch (NearclipException e) { _node.Q.Post(() => Finish(e)); }
            catch (Exception e) { _node.Q.Post(() => Finish(NearclipException.Io(e.Message))); }
        });
    }

    void StartIo()
    {
        var socket = _socket!;
        var stream = new NetworkStream(socket, ownsSocket: false);
        _readTask = Task.Run(() => ReadLoop(stream));
        _ = Task.Run(() => WriteLoop(socket, stream));
    }

    async Task ReadLoop(NetworkStream stream)
    {
        try
        {
            while (true)
            {
                var frame = await Framing.ReadAsync(stream, _cts.Token).ConfigureAwait(false);
                if (frame is null)
                {
                    _node.Q.Post(() => Finish(null));
                    return;
                }
                _node.Q.Post(() => Received(frame));
            }
        }
        catch (NearclipException e) { _node.Q.Post(() => Finish(e)); }
        catch (OperationCanceledException) { _node.Q.Post(() => Finish(null)); }
        catch (Exception e) { _node.Q.Post(() => Finish(NearclipException.Io(e.Message))); }
    }

    async Task WriteLoop(Socket socket, NetworkStream stream)
    {
        try
        {
            await foreach (var f in _outbox.Reader.ReadAllAsync().ConfigureAwait(false))
            {
                await stream.WriteAsync(f.Bytes).ConfigureAwait(false);
                if (f.CloseAfter) _node.Q.Post(() => Finish(null));
            }
            // Orderly close: FIN after everything queued, then wait briefly for the peer to close its side.
            try { socket.Shutdown(SocketShutdown.Send); } catch (Exception) { }
            await Task.WhenAny(_readTask, Task.Delay(2000)).ConfigureAwait(false);
        }
        catch (Exception e)
        {
            _node.Q.Post(() => Finish(NearclipException.Io(e.Message)));
        }
        finally
        {
            DisposeSocket();
            _drained.TrySetResult();
        }
    }

    void DisposeSocket()
    {
        if (Interlocked.Exchange(ref _socketDisposed, 1) != 0) return;
        try { _cts.Cancel(); } catch (ObjectDisposedException) { }
        try { _socket?.Dispose(); } catch (Exception) { }
    }

    /// <summary>Marks the session closed (queued frames are still flushed) and tells the node.</summary>
    void Finish(NearclipException? error)
    {
        if (_closed) return;
        _closed = true;
        CloseError ??= error;
        Phase = SessionPhase.Closed;
        _outbox.Writer.TryComplete();
        if (_socket is null)
        {
            DisposeSocket();
            _drained.TrySetResult();
        }
        else
        {
            _ = Task.Delay(4000).ContinueWith(_ => DisposeSocket(), TaskScheduler.Default);
        }
        _send?.Dispose();
        _eph.Dispose();
        foreach (var p in PendingBlobs.Values) p.Data.Dispose();
        PendingBlobs.Clear();
        if (OnPairResult is { } cb)
        {
            OnPairResult = null;
            cb(new PairOutcome(null, CloseError ?? NearclipException.Io("connection closed")));
        }
        _node.SessionClosed(this);
    }

    public void Close() => Finish(null);

    public void Fail(NearclipException error)
    {
        CloseError ??= error;
        Finish(error);
    }

    public void Tick(DateTime now)
    {
        if (_closed) return;
        if (Phase == SessionPhase.Established)
        {
            if (now - LastSent >= TimeSpan.FromSeconds(15)) SendJson(Simple("ping"));
            if (now - LastReceived >= TimeSpan.FromSeconds(45)) Fail(NearclipException.TimedOut());
        }
        else
        {
            var limit = IsPairing ? TimeSpan.FromSeconds(150) : TimeSpan.FromSeconds(15);
            if (now - Created >= limit) Fail(NearclipException.TimedOut());
        }
    }

    // ---------------------------------------------------------------- sending (node queue)

    void Enqueue(byte[] payload, bool thenClose)
    {
        if (_closed || _closing) return;
        byte[] frame;
        try { frame = Framing.Encode(payload); }
        catch (NearclipException e) { _node.LogMessage("dropping frame: " + e.Message); return; }
        LastSent = DateTime.UtcNow;
        if (thenClose) _closing = true;
        _outbox.Writer.TryWrite(new OutFrame(frame, thenClose));
    }

    public void SendPlain(byte[] bytes, bool thenClose = false) => Enqueue(bytes, thenClose);

    public void SendJson(byte[] json, bool thenClose = false)
    {
        if (_send is null) return;
        if (json.Length + 17 > Wire.MaxFrame) { _node.LogMessage("message too large to send"); return; }
        var plain = new byte[json.Length + 1];
        plain[0] = Wire.TypeJson;
        json.CopyTo(plain, 1);
        SendEncrypted(plain, thenClose);
    }

    public void SendChunk(string clipId, uint index, ReadOnlySpan<byte> data)
    {
        var plain = new byte[1 + 36 + 4 + data.Length];
        plain[0] = Wire.TypeChunk;
        Encoding.ASCII.GetBytes(clipId, plain.AsSpan(1, 36));
        BinaryPrimitives.WriteUInt32BigEndian(plain.AsSpan(37, 4), index);
        data.CopyTo(plain.AsSpan(41));
        SendEncrypted(plain, false);
    }

    void SendEncrypted(byte[] plain, bool thenClose)
    {
        if (_send is null || _closed || _closing) return;
        Enqueue(_send.Seal(plain), thenClose);
    }

    /// <summary>Sends <c>bye</c> (if keys exist) and closes after it is written.</summary>
    public void Bye(string reason)
    {
        if (_send is not null && !_closing && !_closed) SendJson(WireJson.Bye(reason), thenClose: true);
        else if (!_closing) Close();
    }

    // ---------------------------------------------------------------- handshake (node queue)

    void Connected()
    {
        if (Role != SessionRole.Client) return;
        var id = _node.DeviceId;
        _myHello = Mode switch
        {
            SessionMode.Member => HelloMember(id, _node.GroupTag, _eph.PublicX963, _myNonce),
            SessionMode.PairQr => HelloPairQr(id, _eph.PublicX963, _myNonce),
            _ => HelloPairCodeJoiner(id, _eph.PublicX963, _node.DeviceName, _node.Platform),
        };
        Phase = SessionPhase.AwaitHello;
        SendPlain(_myHello);
    }

    void Received(byte[] frame)
    {
        if (_closed || Detached) return;
        LastReceived = DateTime.UtcNow;
        try
        {
            if (_recv is not null) ReceivedEncrypted(frame);
            else ReceivedPlain(frame);
        }
        catch (NearclipException e) { Fail(e); }
        catch (Exception e) { Fail(NearclipException.Protocol(e.Message)); }
    }

    static JsonDocument ParseJson(ReadOnlyMemory<byte> bytes)
    {
        try { return JsonDocument.Parse(bytes); }
        catch (JsonException) { throw NearclipException.Protocol("bad json"); }
    }

    void ReceivedPlain(byte[] frame)
    {
        using var doc = ParseJson(frame);
        var o = doc.RootElement;
        var t = Str(o, "t") ?? throw NearclipException.Protocol("bad handshake frame");
        if (t == "error") throw NearclipException.Remote(Str(o, "code") ?? "error");
        switch (Role, Phase)
        {
            case (SessionRole.Client, SessionPhase.AwaitHello): ClientHello(o, frame); break;
            case (SessionRole.Server, SessionPhase.AwaitHello): ServerHello(o, frame); break;
            case (SessionRole.Client, SessionPhase.AwaitNonce): ClientNonce(o); break;
            case (SessionRole.Server, SessionPhase.AwaitNonce): ServerNonce(o); break;
            default: throw NearclipException.Protocol("unexpected " + t);
        }
    }

    (string Mode, string Id, byte[] E) ParseHello(JsonElement o)
    {
        if (Str(o, "t") != "hello") throw NearclipException.Protocol("expected hello");
        if (Long(o, "v") != 1) throw NearclipException.Remote("version");
        var mode = Str(o, "mode");
        var id = Ids.Norm(Str(o, "id"));
        var e = B64u.Decode(Str(o, "e"));
        if (mode is null || id.Length == 0 || e is null || !NcCrypto.IsValidPublicKey(e))
            throw NearclipException.Protocol("malformed hello");
        if (id == _node.DeviceId) throw NearclipException.Protocol("hello from self");
        return (mode, id, e);
    }

    void InstallKeys(byte[] okm)
    {
        var c2s = okm[..32];
        var s2c = okm[32..64];
        _send = new FrameCipher(Role == SessionRole.Client ? c2s : s2c);
        _recv = new FrameCipher(Role == SessionRole.Client ? s2c : c2s);
    }

    static byte[] Cat(params byte[][] parts) => parts.SelectMany(p => p).ToArray();

    void ClientHello(JsonElement o, byte[] frame)
    {
        var h = ParseHello(o);
        if (h.Mode != ModeName(Mode)) throw NearclipException.Protocol("mode mismatch");
        GotPeerHello = true;
        PeerId = h.Id;
        _peerHello = frame;
        _peerEph = h.E;
        switch (Mode)
        {
            case SessionMode.Member:
            {
                if (Str(o, "gt") != _node.GroupTag) throw NearclipException.Remote("group_mismatch");
                var th = NcCrypto.Sha256(_myHello, frame);
                var z = _eph.SharedSecret(h.E);
                InstallKeys(NcCrypto.Hkdf(z, _node.AuthKey, Cat(Utf8.Bytes("nearclip-session"), th), 64));
                Phase = SessionPhase.Established;
                _node.SessionEstablished(this);
                break;
            }
            case SessionMode.PairQr:
            {
                var secret = PairSecret ?? throw NearclipException.Protocol("no ticket secret");
                var th = NcCrypto.Sha256(_myHello, frame);
                var z = _eph.SharedSecret(h.E);
                InstallKeys(NcCrypto.Hkdf(z, secret, Cat(Utf8.Bytes("nearclip-pair-qr"), th), 64));
                Phase = SessionPhase.AwaitPairResult;
                SendJson(PairRequest(_node.OwnRecord));
                break;
            }
            default:
            {
                var c = B64u.Decode(Str(o, "c"));
                if (c is not { Length: 32 }) throw NearclipException.Protocol("missing commitment");
                _commitment = c;
                PeerName = Str(o, "nm");
                PeerPlatform = Str(o, "pf");
                Phase = SessionPhase.AwaitNonce;
                SendPlain(PairNonce(_myNonce));
                break;
            }
        }
    }

    void ClientNonce(JsonElement o)
    {
        var ns = Str(o, "t") == "pair_nonce" ? B64u.Decode(Str(o, "n")) : null;
        if (ns is null || ns.Length == 0) throw NearclipException.Protocol("expected pair_nonce");
        var expected = NcCrypto.Commitment(_peerEph, _eph.PublicX963, ns);
        if (_commitment is null || !CryptographicOperations.FixedTimeEquals(expected, _commitment))
            throw NearclipException.Remote("commit");
        var th = NcCrypto.Sha256(_myHello, _peerHello, _myNonce, ns);
        var z = _eph.SharedSecret(_peerEph);
        Sas = NcCrypto.Sas(th);
        InstallKeys(NcCrypto.Hkdf(z, Utf8.Bytes("nearclip-pair-code"), th, 64));
        Phase = SessionPhase.AwaitPairResult;
        _node.JoinerGotCode(this);
        SendJson(PairRequest(_node.OwnRecord));
    }

    void ServerHello(JsonElement o, byte[] frame)
    {
        if (Str(o, "t") == "hello" && Long(o, "v") != 1)
        {
            SendPlain(Error("version"), thenClose: true);
            return;
        }
        (string Mode, string Id, byte[] E) h;
        try { h = ParseHello(o); }
        catch (NearclipException e) when (e.Detail != "hello from self")
        {
            SendPlain(Error("bad_request"), thenClose: true);
            return;
        }
        GotPeerHello = true;
        PeerId = h.Id;
        _peerHello = frame;
        _peerEph = h.E;
        switch (h.Mode)
        {
            case "member":
            {
                Mode = SessionMode.Member;
                if (Str(o, "gt") != _node.GroupTag)
                {
                    SendPlain(Error("group_mismatch"), thenClose: true);
                    return;
                }
                _myHello = HelloMember(_node.DeviceId, _node.GroupTag, _eph.PublicX963, _myNonce);
                SendPlain(_myHello);
                var th = NcCrypto.Sha256(frame, _myHello);
                var z = _eph.SharedSecret(h.E);
                InstallKeys(NcCrypto.Hkdf(z, _node.AuthKey, Cat(Utf8.Bytes("nearclip-session"), th), 64));
                Phase = SessionPhase.Established;
                _node.SessionEstablished(this);
                break;
            }
            case "pair-qr":
            {
                Mode = SessionMode.PairQr;
                var secret = _node.CurrentTicketSecret();
                if (secret is null)
                {
                    SendPlain(Error("no_ticket"), thenClose: true);
                    return;
                }
                PairSecret = secret;
                _myHello = HelloPairQr(_node.DeviceId, _eph.PublicX963, _myNonce);
                SendPlain(_myHello);
                var th = NcCrypto.Sha256(frame, _myHello);
                var z = _eph.SharedSecret(h.E);
                InstallKeys(NcCrypto.Hkdf(z, secret, Cat(Utf8.Bytes("nearclip-pair-qr"), th), 64));
                Phase = SessionPhase.AwaitPairRequest;
                break;
            }
            case "pair-code":
            {
                Mode = SessionMode.PairCode;
                PeerName = Str(o, "nm");
                PeerPlatform = Str(o, "pf");
                if (!_node.ReserveCodePairing(this))
                {
                    SendPlain(Error("busy"), thenClose: true);
                    return;
                }
                var commit = NcCrypto.Commitment(_eph.PublicX963, h.E, _myNonce);
                _myHello = HelloPairCodeInviter(_node.DeviceId, _eph.PublicX963, commit, _node.DeviceName, _node.Platform);
                SendPlain(_myHello);
                Phase = SessionPhase.AwaitNonce;
                break;
            }
            default:
                SendPlain(Error("bad_request"), thenClose: true);
                break;
        }
    }

    void ServerNonce(JsonElement o)
    {
        var nc = Str(o, "t") == "pair_nonce" ? B64u.Decode(Str(o, "n")) : null;
        if (nc is null || nc.Length == 0) throw NearclipException.Protocol("expected pair_nonce");
        SendPlain(PairNonce(_myNonce));
        var th = NcCrypto.Sha256(_peerHello, _myHello, nc, _myNonce);
        var z = _eph.SharedSecret(_peerEph);
        Sas = NcCrypto.Sas(th);
        InstallKeys(NcCrypto.Hkdf(z, Utf8.Bytes("nearclip-pair-code"), th, 64));
        Phase = SessionPhase.AwaitPairRequest;
    }

    // ---------------------------------------------------------------- encrypted stream (node queue)

    void ReceivedEncrypted(byte[] frame)
    {
        byte[] plain;
        try { plain = _recv!.Open(frame); }
        catch (NearclipException)
        {
            if (Mode == SessionMode.PairQr && Role == SessionRole.Server) _node.TicketDecryptFailed();
            throw;
        }
        if (plain.Length == 0) return;
        switch (plain[0])
        {
            case Wire.TypeJson:
                HandleJson(plain.AsMemory(1));
                break;
            case Wire.TypeChunk:
                if (Phase != SessionPhase.Established || !ReceivedWelcome || plain.Length <= 41) return;
                var clipId = Encoding.ASCII.GetString(plain, 1, 36).ToLowerInvariant();
                var index = BinaryPrimitives.ReadUInt32BigEndian(plain.AsSpan(37, 4));
                _node.SessionChunk(this, clipId, index, plain.AsMemory(41));
                break;
        }
    }

    void HandleJson(ReadOnlyMemory<byte> json)
    {
        using var doc = ParseJson(json);
        var o = doc.RootElement;
        var t = Str(o, "t") ?? throw NearclipException.Protocol("message without t");
        switch (Phase)
        {
            case SessionPhase.AwaitPairRequest:
            {
                if (t != "pair_request" || ReadMember(Prop(o, "device") ?? default) is not { } rec)
                    throw NearclipException.Protocol("expected pair_request");
                PeerRecord = rec with { Id = PeerId ?? rec.Id };
                if (Mode == SessionMode.PairQr)
                {
                    _node.InviterAccept(this);
                }
                else
                {
                    Phase = SessionPhase.AwaitDecision;
                    _node.InviterPrompt(this);
                }
                break;
            }
            case SessionPhase.AwaitPairResult:
                switch (t)
                {
                    case "pair_accept":
                    {
                        var g = Prop(o, "group") ?? default;
                        var gid = Ids.Norm(Str(g, "id"));
                        var key = B64u.Decode(Str(g, "key"));
                        var dev = ReadMember(Prop(o, "device") ?? default);
                        if (gid.Length == 0 || key is not { Length: 32 } || dev is null) throw NearclipException.Protocol("bad pair_accept");
                        var info = new PairAcceptInfo(gid, key, dev with { Id = PeerId ?? dev.Id }, ReadMembers(o, "members"));
                        var cb = OnPairResult;
                        OnPairResult = null;
                        cb?.Invoke(new PairOutcome(info, null));
                        Close();
                        break;
                    }
                    case "pair_decline":
                        Fail(NearclipException.Remote("declined"));
                        break;
                    case "error":
                        Fail(NearclipException.Remote(Str(o, "code") ?? "error"));
                        break;
                    default:
                        throw NearclipException.Protocol("unexpected " + t);
                }
                break;
            case SessionPhase.Established:
                switch (t)
                {
                    case "ping": SendJson(Simple("pong")); return;
                    case "pong": return;
                    case "bye":
                        _node.SessionBye(this, Str(o, "reason") ?? "shutdown");
                        Close();
                        return;
                }
                if (!ReceivedWelcome)
                {
                    if (t != "welcome" || ReadMember(Prop(o, "device") ?? default) is not { } dev)
                        throw NearclipException.Protocol("expected welcome");
                    ReceivedWelcome = true;
                    PeerRecord = dev with { Id = PeerId ?? dev.Id };
                    SupportsPolicies = Arr(o, "features").Any(x => x.GetString() == "policy1");
                    SupportsRekey = Arr(o, "features").Any(x => x.GetString() == "rekey1");
                    _node.SessionWelcome(this, PeerRecord, ReadMembers(o, "members"), ReadEndpoints(o, "addrs"));
                    return;
                }
                _node.SessionMessage(this, t, o);
                break;
            default:
                throw NearclipException.Protocol("unexpected " + t);
        }
    }
}
