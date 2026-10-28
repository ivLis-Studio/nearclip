using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text.Json;
using static Nearclip.Core.WireJson;

namespace Nearclip.Core;

/// <summary>The Nearclip engine: listener, discovery, sessions, pairing, gossip and history.
/// Everything runs on one serial queue; events are delivered in order on a separate event thread.</summary>
public sealed partial class NearclipNode : IDisposable
{
    public sealed class Options
    {
        public required string StateDirectory { get; init; }
        public required string DeviceName { get; init; }
        public required string Platform { get; init; }
        public string? Model { get; init; }
        public string? AppVersion { get; init; }
        /// <summary>Preferred listener port; 0 = OS-assigned. Falls back to any free port when taken.</summary>
        public int Port { get; init; } = Wire.DefaultPort;
        public required ISecretStore SecretStore { get; init; }
        public IDiscovery? Discovery { get; init; }
        public Func<IReadOnlyList<string>> AddressProvider { get; init; } = LocalAddresses.Ipv4;
        /// <summary>Embedded Tailscale node for remote connection (PROTOCOL.md §10). null = not available.</summary>
        public TailnetOptions? Tailnet { get; init; }
    }

    sealed record Discovered(string Id, string Name, string Platform, string Gt, bool Pm, IReadOnlyList<Endpoint> Endpoints);

    sealed class Ticket
    {
        public required byte[] Secret { get; init; }
        public required DateTimeOffset Expires { get; init; }
        public int Failures { get; set; }
    }

    internal readonly SerialQueue Q = new("nearclip-node");
    readonly SerialQueue _events = new("nearclip-events");
    readonly Options _o;
    readonly NodeStore _store;
    readonly HashSet<PeerSession> _sessions = new();
    readonly Dictionary<string, PeerSession> _online = new();
    readonly Dictionary<string, DateTime> _dialing = new();
    readonly Dictionary<string, (DateTime Next, double Delay)> _backoff = new();
    readonly List<DateTime> _codeAttempts = new();
    readonly HashSet<string> _declinedImages = new();
    /// <summary>Live images arriving from other devices (PROTOCOL.md §6.6), by clip id. The same clip can come through
    /// several sessions (forwarding); a transfer ends when one of them delivers it or all of them are gone.</summary>
    readonly Dictionary<string, Transfer> _transfers = new();
    /// <summary>Images this device announced and has not sent or cancelled yet.</summary>
    readonly Dictionary<string, DateTime> _announced = new();
    Dictionary<string, Discovered> _discovered = new();
    Socket? _listener;
    CancellationTokenSource? _listenCts;
    int _port;
    Ticket? _ticket;
    PeerSession? _codeSession;
    PeerSession? _joinSession;
    bool _joining;
    bool _pairingMode;
    bool _paused;
    bool _running;
    bool _disposed;
    bool _syncImages = true;
    bool _discoveryStarted;
    Timer? _timer;
    long _tick;
    long _newestLocalTs;

    // Remote connection (embedded Tailscale node, PROTOCOL.md §10).
    /// <summary>Tailnet port every Nearclip node accepts connections on.</summary>
    internal const int TailnetPort = 45821;
    /// <summary>Tailnet candidates start this much later than LAN candidates (§10.3).</summary>
    static readonly TimeSpan TailnetDelay = TimeSpan.FromMilliseconds(400);
    readonly SerialQueue _tq = new("nearclip-tailnet");
    bool _remoteEnabled;
    TailnetStatus _tailnet = TailnetStatus.Off;
    Socket? _tailnetListener;
    CancellationTokenSource? _tailnetCts;
    int _tailnetGeneration;
    string _tailnetReach = "";

    public string DeviceId { get; }
    internal string DeviceName { get; private set; }
    internal string Platform => _o.Platform;
    internal byte[] GroupKey { get; private set; } = [];
    internal string GroupTag { get; private set; } = "";
    internal byte[] AuthKey { get; private set; } = [];
    string GroupId => _store.State.GroupId;

    /// <summary>Raised on the event thread, in order.</summary>
    public event Action<NodeEvent>? Event;

    public NearclipNode(Options options)
    {
        _o = options;
        Directory.CreateDirectory(options.StateDirectory);
        Q.OnError = e => Emit(new NodeEvent.Log("engine error: " + e));
        _events.OnError = e => Console.Error.WriteLine("event handler error: " + e);
        _store = new NodeStore(options.StateDirectory, options.DeviceName, Q, options.SecretStore);
        DeviceId = _store.State.DeviceId;
        DeviceName = _store.State.DeviceName;
        var key = options.SecretStore.Load("group-key-" + _store.State.GroupId);
        if (key is not { Length: 32 })
        {
            // First launch (or the key is gone): start a fresh solo group.
            key = NcCrypto.Random(32);
            _store.State.GroupId = Ids.New();
            _store.State.JoinedAt = Clock.NowMs();
            _store.Members.Clear();
            _store.State.Endpoints.Clear();
            options.SecretStore.Save(key, "group-key-" + _store.State.GroupId);
        }
        SetGroupKey(key);
        _newestLocalTs = _store.State.NewestLocalTs;
        EnsureOwnRecord();
        _store.SaveNow();
    }

    void SetGroupKey(byte[] key)
    {
        GroupKey = key;
        GroupTag = NcCrypto.GroupTag(key);
        AuthKey = NcCrypto.AuthKey(key);
    }

    // ================================================================ public API (thread-safe)

    public void Start() => Q.Post(StartInternal);

    /// <summary>Sends <c>bye</c> to every peer, flushes state and waits (briefly) until the byes are on the wire.</summary>
    public void Stop()
    {
        if (_disposed) return;
        var drains = Q.Invoke(() =>
        {
            var pending = _sessions.Select(s => s.Drained).ToList();
            if (_running)
            {
                _running = false;
                StopNetworking("shutdown");
                _timer?.Dispose();
                _timer = null;
            }
            _store.SaveNow();
            return pending;
        });
        try { Task.WaitAll(drains.ToArray(), TimeSpan.FromSeconds(1.5)); } catch (AggregateException) { }
        // Let the embedded node shut down cleanly (bounded by the bridge's own timeout).
        try { _tq.InvokeAsync(() => 0).Wait(TimeSpan.FromSeconds(10)); } catch (Exception) { }
    }

    public void Dispose()
    {
        if (_disposed) return;
        Stop();
        _disposed = true;
        Q.Invoke(() => _store.Dispose());
        Q.Dispose();
        _events.Dispose();
        _tq.Dispose();
    }

    public NodeSnapshot Snapshot() => Q.Invoke(SnapshotInternal);

    public string BlobPath(string id) => _store.BlobPath(Ids.Norm(id));

    public byte[]? ReadBlob(string id) => _store.ReadBlob(Ids.Norm(id));

    /// <param name="otp">A verification code found in a message (PROTOCOL.md §6.7).</param>
    public StoredClip? SendText(string text, bool otp = false) => Q.Invoke(() =>
    {
        if (string.IsNullOrEmpty(text)) return null;
        if (System.Text.Encoding.UTF8.GetByteCount(text) > Wire.MaxText)
        {
            Emit(new NodeEvent.TooLarge("text"));
            return null;
        }
        var c = new Clip(Ids.New(), NextLocalTs(), DeviceId, "text", Text: text, Otp: otp ? true : null);
        return Produce(c, null);
    });

    /// <param name="id">From <see cref="AnnounceImage"/> (PROTOCOL.md §6.6), or null.</param>
    public StoredClip? SendImage(byte[] data, string mime, int? width = null, int? height = null, string? id = null) => Q.Invoke(() =>
    {
        var announcedId = id is null ? null : Ids.Norm(id);
        var wasAnnounced = announcedId is not null && _announced.Remove(announcedId);
        if (data.Length == 0)
        {
            if (wasAnnounced) SendCancel(announcedId!);
            return null;
        }
        if (data.Length > Wire.MaxImage)
        {
            if (wasAnnounced) SendCancel(announcedId!);
            Emit(new NodeEvent.TooLarge("image"));
            return null;
        }
        var cid = announcedId is not null && Guid.TryParseExact(announcedId, "D", out _) && !_store.Has(announcedId)
            && !_store.State.Tombstones.ContainsKey(announcedId) ? announcedId : Ids.New();
        var c = new Clip(cid, NextLocalTs(), DeviceId, "image", Mime: mime, Size: data.Length,
            Sha: Hex.Encode(SHA256.HashData(data)), W: width, H: height);
        return Produce(c, data);
    });

    /// <summary>Tells the other devices that an image was just copied here, before it is encoded (PROTOCOL.md §6.6), so
    /// they can show it arriving right away. Pass the returned id to <see cref="SendImage"/>, or to
    /// <see cref="CancelImage"/> if it is not sent after all.</summary>
    public string AnnounceImage()
    {
        var id = Ids.New();
        Q.Post(() =>
        {
            if (!_running || _paused || !_syncImages) return;
            _announced[id] = DateTime.UtcNow;
            foreach (var s in _online.Values.ToList())
                if (s.IsMember && (_store.State.Policies.GetValueOrDefault(s.PeerId ?? "") ?? new SyncPolicy()) is { Send: true, Images: true }) s.SendJson(WireJson.Incoming(id));
        });
        return id;
    }

    /// <summary>The announced image will not be sent after all (unreadable, too large, replaced by a newer copy).</summary>
    public void CancelImage(string id) => Q.Post(() =>
    {
        var key = Ids.Norm(id);
        if (_announced.Remove(key)) SendCancel(key);
    });

    void SendCancel(string id)
    {
        foreach (var s in _online.Values.ToList())
            if (s.IsMember) s.SendJson(WireJson.IncomingCancel(id));
    }

    /// <summary>Records a clip that stays on this device (too large to sync). Shown in history, never advertised.</summary>
    public StoredClip? AddLocalOnly(string kind, string? text, byte[]? blob, string? mime, int? width = null, int? height = null) => Q.Invoke(() =>
    {
        var c = new Clip(Ids.New(), NextLocalTs(), DeviceId, kind, Text: text, Mime: mime, Size: blob?.Length,
            Sha: blob is null ? null : Hex.Encode(SHA256.HashData(blob)), W: width, H: height);
        _newestLocalTs = c.Ts;
        _store.State.NewestLocalTs = c.Ts;
        var sc = new StoredClip(c, GroupId, false, Clock.NowMs(), DeviceName, Platform, LocalOnly: true);
        _store.Add(sc, blob);
        Emit(new NodeEvent.ClipAdded(sc, true, false, true));
        Prune();
        return sc;
    });

    /// <summary>Tells the engine that the app wrote a clip to the system clipboard (keeps "newest" ordering right).</summary>
    public void NoteApplied(Clip clip) => Q.Post(() =>
    {
        if (clip.Ts <= _newestLocalTs) return;
        _newestLocalTs = clip.Ts;
        _store.State.NewestLocalTs = clip.Ts;
        _store.SaveSoon();
    });

    public void Delete(IEnumerable<string> ids)
    {
        var now = Clock.NowMs();
        var items = ids.Select(i => new IdTs(Ids.Norm(i), now)).ToList();
        Q.Post(() => ApplyDeletes(items, null));
    }

    public void ClearHistory() => Q.Post(() =>
    {
        var now = Clock.NowMs();
        ApplyDeletes(_store.History.Select(c => new IdTs(c.Id, now)).ToList(), null);
    });

    public void SetPinned(string id, bool pinned) => Q.Post(() =>
    {
        if (_store.Get(Ids.Norm(id)) is not { } sc || sc.Pinned == pinned) return;
        var updated = _store.Replace(sc with { Pinned = pinned });
        if (updated is not null) Emit(new NodeEvent.ClipUpdated(updated));
    });

    /// <summary><paramref name="days"/> = 0 keeps history forever.</summary>
    public void SetRetention(int days, int maxItems = 1000) => Q.Post(() =>
    {
        _store.RetentionDays = Math.Max(0, days);
        _store.MaxItems = Math.Max(1, maxItems);
        Prune();
    });

    public void SetSyncImages(bool on) => Q.Post(() => _syncImages = on);

    public void Rename(string name)
    {
        var trimmed = Utf8.TruncateChars(name.Trim(), 64);
        if (trimmed.Length == 0) return;
        Q.Post(() =>
        {
            if (trimmed == DeviceName && OwnRecord.Name == trimmed) return;
            DeviceName = trimmed;
            _store.State.DeviceName = trimmed;
            var me = OwnRecord with { Name = trimmed };
            me = me with { UpdatedAt = Math.Max(Clock.NowMs(), OwnRecord.UpdatedAt + 1) };
            _store.Members[DeviceId] = me;
            _store.SaveSoon();
            foreach (var s in _online.Values.ToList()) s.SendJson(Members([me]));
            RefreshAdvertisement();
            Emit(new NodeEvent.MembersChanged(MemberList()));
        });
    }

    public void RemoveMember(string id) => Q.Post(() =>
    {
        id = Ids.Norm(id);
        if (id == DeviceId || !_store.Members.TryGetValue(id, out var r)) return;
        r = r with { Removed = true, UpdatedAt = Math.Max(Clock.NowMs(), r.UpdatedAt + 1) };
        _store.Members[id] = r;
        if (_online.TryGetValue(id, out var s)) s.Bye("removed");
        foreach (var (pid, o) in _online.ToList()) if (pid != id && !o.SupportsRekey) o.SendJson(Members([r]));
        RotateAfterRemoval();
        Emit(new NodeEvent.MembersChanged(MemberList()));
    });

    /// <summary>This device leaves its group and starts a new, empty one (history is kept).</summary>
    public void LeaveGroup() => Q.Post(() => Leave("leaving", announce: true));

    public void SetPaused(bool value) => Q.Post(() =>
    {
        if (_paused == value) return;
        _paused = value;
        Emit(new NodeEvent.PausedChanged(value));
        if (!_running) return;
        if (value) StopNetworking("shutdown");
        else StartNetworking();
    });

    /// <summary>Advertise <c>pm=1</c> while the Add-device UI is visible.</summary>
    public void SetPairingMode(bool on) => Q.Post(() =>
    {
        if (_pairingMode == on) return;
        _pairingMode = on;
        RefreshAdvertisement();
    });

    public PairingTicket CreateTicket() => Q.Invoke(CreateTicketInternal);

    public void CancelTicket() => Q.Post(() => _ticket = null);

    /// <summary>Joiner: QR / link pairing.</summary>
    public void Join(PairingInvite invite) => Q.Post(() => JoinInternal(invite));

    /// <summary>Joiner: numeric-comparison pairing with a device found nearby.</summary>
    public void PairWithCode(string nearbyId) => Q.Post(() =>
    {
        if (!_discovered.TryGetValue(Ids.Norm(nearbyId), out var d))
        {
            Emit(new NodeEvent.PairFailed("unreachable", null));
            return;
        }
        StartCodeJoin(d.Endpoints, d.Name);
    });

    /// <summary>Joiner: numeric-comparison pairing with an explicit address.</summary>
    public void PairWithCode(string host, int port) => Q.Post(() =>
    {
        if (port is < 1 or > 65535 || string.IsNullOrWhiteSpace(host))
        {
            Emit(new NodeEvent.PairFailed("unreachable", null));
            return;
        }
        StartCodeJoin([new Endpoint(host.Trim(), port)], null);
    });

    public void CancelJoin() => Q.Post(() =>
    {
        if (_joinSession is { } s)
        {
            s.OnPairResult = null;
            s.Close();
        }
        _joinSession = null;
        _joining = false;
    });

    /// <summary>Inviter: answer the pending code-pairing prompt (optionally only if it is from <paramref name="peerId"/>).</summary>
    public void AnswerPairPrompt(bool accept, string? peerId = null) => Q.Post(() =>
    {
        if (_codeSession is not { Phase: PeerSession.SessionPhase.AwaitDecision } s) return;
        if (peerId is not null && s.PeerId != Ids.Norm(peerId)) return;
        if (accept)
        {
            InviterAccept(s);
        }
        else
        {
            _codeSession = null;
            s.SendJson(Simple("pair_decline"), thenClose: true);
        }
    });

    /// <summary>Dial a member session at an explicit address.</summary>
    public void Connect(string host, int port) => Q.Post(() =>
    {
        if (port is < 1 or > 65535 || string.IsNullOrWhiteSpace(host)) return;
        DialMember(null, CandidatesFor([new Endpoint(host.Trim(), port)], fallback: true));
    });

    // ================================================================ remote connection (public)

    /// <summary>Whether this build can run the embedded Tailscale node.</summary>
    public bool TailnetAvailable => _o.Tailnet is not null && TailnetBridge.Available;

    /// <summary>Remote connection on/off (the app persists the choice). The node runs only while networking runs.</summary>
    public void SetRemoteEnabled(bool on) => Q.Post(() =>
    {
        if (_remoteEnabled == on) return;
        _remoteEnabled = on;
        if (on) StartTailnetIfNeeded();
        else StopTailnet();
    });

    /// <summary>Makes sure a Tailscale sign-in URL exists; completes with the fresh status.</summary>
    public Task<TailnetStatus> TailnetLoginAsync()
    {
        var tcs = new TaskCompletionSource<TailnetStatus>(TaskCreationOptions.RunContinuationsAsynchronously);
        Q.Post(() =>
        {
            if (_tailnetListener is null) { tcs.TrySetResult(_tailnet); return; }
            var gen = _tailnetGeneration;
            _tq.Post(() =>
            {
                var st = TailnetBridge.Login();
                Q.Post(() => { if (gen == _tailnetGeneration) ApplyTailnet(st); });
                tcs.TrySetResult(st);
            });
        });
        return tcs.Task;
    }

    /// <summary>Signs this device out of Tailscale (remote connection then needs a new sign-in).</summary>
    public void TailnetLogout() => Q.Post(() =>
    {
        if (_tailnetListener is null) return;
        var gen = _tailnetGeneration;
        _tq.Post(() =>
        {
            var st = TailnetBridge.Logout();
            Q.Post(() => { if (gen == _tailnetGeneration) ApplyTailnet(st); });
        });
    });

    /// <summary>The device's network changed (wake, interface up/down): drop sessions that went silent, forget back-off
    /// and redial now (PROTOCOL.md §4.5, §10.4).</summary>
    public void NetworkChanged() => Q.Post(() =>
    {
        if (_tailnetListener is not null) _tq.Post(TailnetBridge.NetworkChanged);
        if (!_running || _paused) return;
        var now = DateTime.UtcNow;
        foreach (var s in _online.Values.ToList()) if ((now - s.LastReceived).TotalSeconds > 20) s.Close();
        _backoff.Clear();
        foreach (var s in _online.Values.ToList()) s.SendJson(Simple("ping"));
        RedialDisconnected(now);
    });

    // ================================================================ internal state

    internal MemberRecord OwnRecord
    {
        get
        {
            if (_store.Members.TryGetValue(DeviceId, out var r)) return r;
            var now = Clock.NowMs();
            return new MemberRecord(DeviceId, DeviceName, Platform, _o.Model, _o.AppVersion, now, now, false);
        }
    }

    void EnsureOwnRecord()
    {
        var now = Clock.NowMs();
        var rec = _store.Members.TryGetValue(DeviceId, out var r) ? r : new MemberRecord(DeviceId, DeviceName, Platform, _o.Model, _o.AppVersion, now, now, false);
        if (rec.Name != DeviceName || rec.Platform != Platform || rec.App != _o.AppVersion || rec.Model != _o.Model || rec.Removed)
        {
            rec = rec with
            {
                Name = DeviceName, Platform = Platform, App = _o.AppVersion, Model = _o.Model, Removed = false,
                UpdatedAt = Math.Max(now, rec.UpdatedAt + 1),
            };
        }
        _store.Members[DeviceId] = rec;
    }

    long NextLocalTs() => Math.Max(Clock.NowMs(), _newestLocalTs + 1);

    List<MemberRecord> MemberList() =>
        _store.Members.Values.OrderBy(m => m.AddedAt).ThenBy(m => m.Id, StringComparer.Ordinal).ToList();

    NodeSnapshot SnapshotInternal() => new(
        DeviceId, DeviceName, Platform, GroupId, GroupTag, MemberList(), _online.Keys.ToHashSet(),
        new Dictionary<string, long>(_store.State.LastSeen), _store.History.ToList(), NearbyList(), _port, _paused,
        _pairingMode, _o.AddressProvider(), _online.ToDictionary(kv => kv.Key, kv => kv.Value.Route), _remoteEnabled, _tailnet);

    void Emit(NodeEvent e)
    {
        _events.Post(() => Event?.Invoke(e));
    }

    internal void LogMessage(string s) => Emit(new NodeEvent.Log(s));

    // ================================================================ networking

    void StartInternal()
    {
        if (_running) return;
        _running = true;
        Prune();
        if (_o.Discovery is { } d) d.Changed += OnDiscoveryChanged;
        if (!_paused) StartNetworking();
        _timer = new Timer(_ => Q.Post(Tick), null, TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(1));
    }

    void StartNetworking()
    {
        if (_listener is null) StartListener(_o.Port);
        StartDiscovery();
        if (_running) Q.After(TimeSpan.FromMilliseconds(300), () => { if (_running && !_paused) RedialDisconnected(DateTime.UtcNow); });
    }

    void StopNetworking(string reason)
    {
        _listenCts?.Cancel();
        try { _listener?.Dispose(); } catch (Exception) { }
        _listener = null;
        _listenCts = null;
        StopDiscovery();
        StopTailnet();
        foreach (var s in _sessions.ToList())
        {
            if (s.IsMember) s.Bye(reason);
            else s.Close();
        }
        _discovered = new();
        Emit(new NodeEvent.NearbyChanged([]));
    }

    static Socket Bind(int port)
    {
        Socket s;
        try
        {
            s = new Socket(AddressFamily.InterNetworkV6, SocketType.Stream, ProtocolType.Tcp) { DualMode = true };
            try
            {
                if (!OperatingSystem.IsWindows()) s.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                s.Bind(new IPEndPoint(IPAddress.IPv6Any, port));
            }
            catch (SocketException e) when (e.SocketErrorCode != SocketError.AddressAlreadyInUse)
            {
                s.Dispose();
                s = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
                if (!OperatingSystem.IsWindows()) s.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                s.Bind(new IPEndPoint(IPAddress.Any, port));
            }
        }
        catch (NotSupportedException)
        {
            s = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
            s.Bind(new IPEndPoint(IPAddress.Any, port));
        }
        s.Listen(64);
        return s;
    }

    void StartListener(int preferred)
    {
        Socket listener;
        try
        {
            listener = Bind(preferred);
        }
        catch (SocketException e) when (preferred != 0)
        {
            LogMessage($"port {preferred} unavailable ({e.SocketErrorCode}); using any free port");
            try { listener = Bind(0); }
            catch (SocketException e2)
            {
                LogMessage("listener failed: " + e2.Message);
                Q.After(TimeSpan.FromSeconds(2), () => { if (_running && !_paused && _listener is null) StartListener(preferred); });
                return;
            }
        }
        catch (SocketException e)
        {
            LogMessage("listener failed: " + e.Message);
            Q.After(TimeSpan.FromSeconds(2), () => { if (_running && !_paused && _listener is null) StartListener(preferred); });
            return;
        }
        _listener = listener;
        _port = ((IPEndPoint)listener.LocalEndPoint!).Port;
        var cts = new CancellationTokenSource();
        _listenCts = cts;
        _ = Task.Run(() => AcceptLoop(listener, false, cts.Token));
        Emit(new NodeEvent.Ready(_port, GroupId, GroupTag));
        StartTailnetIfNeeded();
    }

    async Task AcceptLoop(Socket listener, bool viaTailnet, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            Socket client;
            try { client = await listener.AcceptAsync(ct).ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }
            catch (ObjectDisposedException) { return; }
            catch (SocketException)
            {
                if (ct.IsCancellationRequested) return;
                await Task.Delay(200, CancellationToken.None).ConfigureAwait(false);
                continue;
            }
            Q.Post(() => Accept(client, viaTailnet));
        }
    }

    void Accept(Socket client, bool viaTailnet)
    {
        if (!_running || _paused)
        {
            client.Dispose();
            return;
        }
        var s = new PeerSession(this, client, viaTailnet);
        _sessions.Add(s);
        s.Start();
    }

    // ================================================================ embedded Tailscale node

    void StartTailnetIfNeeded()
    {
        if (_o.Tailnet is not { } opts || !_remoteEnabled || !_running || _paused || _port <= 0) return;
        if (_tailnetListener is null)
        {
            // Inbound tailnet connections arrive here from the bridge (loopback only).
            try
            {
                var l = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
                l.Bind(new IPEndPoint(IPAddress.Loopback, 0));
                l.Listen(64);
                _tailnetListener = l;
                var cts = new CancellationTokenSource();
                _tailnetCts = cts;
                _ = Task.Run(() => AcceptLoop(l, true, cts.Token));
            }
            catch (SocketException e)
            {
                ApplyTailnet(new TailnetStatus { State = "error", Error = e.Message });
                return;
            }
        }
        var forward = ((IPEndPoint)_tailnetListener.LocalEndPoint!).Port;
        var cfg = new Dictionary<string, object>
        {
            ["dir"] = opts.Directory, ["deviceId"] = DeviceId, ["deviceName"] = DeviceName,
            ["ports"] = new[] { _port }, ["forward"] = $"127.0.0.1:{forward}",
        };
        if (opts.ControlUrl is { } c) cfg["controlURL"] = c;
        if (opts.LogPath is { } lp) cfg["logPath"] = lp;
        if (opts.TestMode) cfg["testMode"] = true;
        var json = JsonSerializer.Serialize(cfg);
        var gen = ++_tailnetGeneration;
        if (!_tailnet.IsRunning) ApplyTailnet(new TailnetStatus { State = "starting" });
        _tq.Post(() =>
        {
            Directory.CreateDirectory(opts.Directory);
            var st = TailnetBridge.Start(json);
            Q.Post(() =>
            {
                if (gen != _tailnetGeneration) return;
                ApplyTailnet(st);
                ScheduleTailnetPoll(gen);
            });
        });
    }

    void StopTailnet()
    {
        var active = _tailnetListener is not null || _tailnet.State != "off";
        _tailnetCts?.Cancel();
        try { _tailnetListener?.Dispose(); } catch (Exception) { }
        _tailnetListener = null;
        _tailnetCts = null;
        _tailnetGeneration++;
        if (!active) return;
        _tq.Post(() => TailnetBridge.Stop());
        ApplyTailnet(TailnetStatus.Off);
    }

    void ScheduleTailnetPoll(int gen)
    {
        var delay = _tailnet.IsRunning ? TimeSpan.FromSeconds(5) : TimeSpan.FromSeconds(1.5);
        Q.After(delay, () =>
        {
            if (gen != _tailnetGeneration || _tailnetListener is null) return;
            _tq.Post(() =>
            {
                var st = TailnetBridge.Status();
                Q.Post(() =>
                {
                    if (gen != _tailnetGeneration) return;
                    ApplyTailnet(st);
                    ScheduleTailnetPoll(gen);
                });
            });
        });
    }

    void ApplyTailnet(TailnetStatus st)
    {
        var old = _tailnet;
        _tailnet = st;
        if (!old.SameEssentials(st)) Emit(new NodeEvent.TailnetChanged(st));
        // New ways to reach members (node came up, other nodes appeared): dial at once.
        var reach = st.IsRunning ? st.Ip + "|" + string.Join(",", st.Peers.Select(p => $"{p.IdPrefix}@{p.Ip}")) : "";
        if (reach == _tailnetReach) return;
        _tailnetReach = reach;
        if (!st.IsRunning) return;
        _backoff.Clear();
        if (_running && !_paused) RedialDisconnected(DateTime.UtcNow);
    }

    /// <summary>All ways to reach a member: the discovered service, remembered endpoints and its tailnet node.</summary>
    List<DialCandidate> DialCandidates(string id)
    {
        var eps = new List<Endpoint>();
        if (_discovered.TryGetValue(id, out var d) && d.Gt == GroupTag) eps.AddRange(d.Endpoints);
        if (_store.State.Endpoints.TryGetValue(id, out var known)) eps.AddRange(known);
        if (_tailnet.IsRunning)
        {
            var id8 = id.Replace("-", "")[..Math.Min(8, id.Replace("-", "").Length)];
            eps.AddRange(_tailnet.Peers.Where(p => p.IdPrefix == id8).Select(p => new Endpoint(p.Ip, TailnetPort)));
        }
        return CandidatesFor(eps);
    }

    /// <summary>Direct candidates for LAN endpoints; tailnet endpoints go through the bridge proxy (and through the OS when
    /// the Tailscale app itself is connected) and start a little later (PROTOCOL.md §10.3).</summary>
    List<DialCandidate> CandidatesFor(IEnumerable<Endpoint> eps, bool fallback = false)
    {
        var list = eps.Distinct().ToList();
        var outList = new List<DialCandidate>();
        var ts = _tailnet;
        bool? osTailnet = null;
        foreach (var e in list)
        {
            if (!TailnetAddress.Contains(e.H))
            {
                outList.Add(DialCandidate.Direct(e));
                continue;
            }
            if (e.H == ts.Ip) continue;
            if (ts.IsRunning && ts.ProxyPort is { } pp && ts.Token is { } token)
                outList.Add(new DialCandidate(new Endpoint("127.0.0.1", pp), e, $"NCTN1 {token} {e.H}:{e.P}\n", TailnetDelay, true));
            osTailnet ??= _o.AddressProvider().Any(TailnetAddress.Contains);
            if (osTailnet == true) outList.Add(new DialCandidate(e, e, null, TailnetDelay, true));
        }
        if (outList.Count == 0 && fallback && list.Count > 0) outList.Add(DialCandidate.Direct(list[0]));
        return outList;
    }

    ServiceAdvertisement MakeAdvertisement()
    {
        var txt = new Dictionary<string, string>
        {
            ["v"] = "1",
            ["id"] = DeviceId,
            ["nm"] = Utf8.Truncate(DeviceName, 60),
            ["pf"] = Platform,
            ["gt"] = GroupTag,
        };
        if (_pairingMode) txt["pm"] = "1";
        return new ServiceAdvertisement(Utf8.Truncate(DeviceName.Length == 0 ? "Nearclip" : DeviceName, 63), _port, txt);
    }

    void StartDiscovery()
    {
        if (_o.Discovery is not { } d || _port <= 0 || _discoveryStarted) return;
        try
        {
            d.Start(MakeAdvertisement());
            _discoveryStarted = true;
        }
        catch (Exception e) { LogMessage("discovery failed: " + e.Message); }
    }

    void StopDiscovery()
    {
        if (_o.Discovery is not { } d || !_discoveryStarted) return;
        _discoveryStarted = false;
        try { d.Stop(); } catch (Exception e) { LogMessage("discovery stop failed: " + e.Message); }
    }

    void RefreshAdvertisement()
    {
        if (_o.Discovery is not { } d || !_discoveryStarted || !_running || _paused) return;
        try { d.Update(MakeAdvertisement()); } catch (Exception e) { LogMessage("advertisement update failed: " + e.Message); }
    }

    void OnDiscoveryChanged(IReadOnlyList<DiscoveredService> list) => Q.Post(() => UpdateDiscovered(list));

    void UpdateDiscovered(IReadOnlyList<DiscoveredService> results)
    {
        if (!_running || _paused) return;
        var map = new Dictionary<string, Discovered>();
        foreach (var r in results)
        {
            if (r.Txt.GetValueOrDefault("v") != "1" || r.Endpoints.Count == 0) continue;
            var id = Ids.Norm(r.Txt.GetValueOrDefault("id"));
            if (id.Length == 0 || id == DeviceId) continue;
            var name = r.Txt.GetValueOrDefault("nm");
            if (string.IsNullOrEmpty(name)) name = r.InstanceName;
            var eps = map.TryGetValue(id, out var existing) ? existing.Endpoints.Concat(r.Endpoints).Distinct().ToList() : r.Endpoints;
            map[id] = new Discovered(id, name, r.Txt.GetValueOrDefault("pf") ?? "", r.Txt.GetValueOrDefault("gt") ?? "",
                r.Txt.GetValueOrDefault("pm") == "1", eps);
        }
        var previous = _discovered;
        _discovered = map;
        foreach (var d in map.Values.Where(d => d.Gt == GroupTag))
        {
            if (!previous.ContainsKey(d.Id)) _backoff.Remove(d.Id);
            ConsiderDial(d);
        }
        var before = NearbyListOf(previous);
        var after = NearbyList();
        if (!before.SequenceEqual(after)) Emit(new NodeEvent.NearbyChanged(after));
    }

    List<NearbyDevice> NearbyListOf(Dictionary<string, Discovered> map) =>
        map.Values.Where(d => d.Gt != GroupTag)
            .Select(d => new NearbyDevice(d.Id, d.Name, d.Platform, d.Pm))
            .OrderBy(d => d.PairingMode ? 0 : 1).ThenBy(d => d.Name, StringComparer.CurrentCultureIgnoreCase).ToList();

    List<NearbyDevice> NearbyList() => NearbyListOf(_discovered);

    void ConsiderDial(Discovered d)
    {
        if (!_running || _paused || _online.ContainsKey(d.Id) || _dialing.ContainsKey(d.Id)) return;
        if (_store.Members.TryGetValue(d.Id, out var m) && m.Removed) return;
        if (string.CompareOrdinal(DeviceId, d.Id) < 0)
        {
            DialMember(d.Id, DialCandidates(d.Id));
        }
        else
        {
            Q.After(TimeSpan.FromSeconds(3), () =>
            {
                if (_discovered.TryGetValue(d.Id, out var d2) && d2.Gt == GroupTag && !_online.ContainsKey(d.Id) && !_dialing.ContainsKey(d.Id))
                    DialMember(d2.Id, DialCandidates(d2.Id));
            });
        }
    }

    void DialMember(string? peerId, IReadOnlyList<DialCandidate> targets)
    {
        if (!_running || _paused || targets.Count == 0) return;
        if (peerId is not null)
        {
            if (_online.ContainsKey(peerId) || _dialing.ContainsKey(peerId)) return;
            if (_store.Members.TryGetValue(peerId, out var m) && m.Removed) return;
            _dialing[peerId] = DateTime.UtcNow;
        }
        else if (_sessions.Any(x => x.Role == PeerSession.SessionRole.Client && x.Mode == PeerSession.SessionMode.Member &&
                                    !x.IsClosing && x.Targets.Intersect(targets.Select(t => t.Address)).Any()))
        {
            return; // already dialing / connected to that address
        }
        var s = new PeerSession(this, PeerSession.SessionMode.Member, targets) { ExpectedPeerId = peerId };
        _sessions.Add(s);
        s.Start();
    }

    IReadOnlyList<Endpoint> OwnEndpoints()
    {
        if (_port <= 0) return [];
        var eps = _o.AddressProvider().Select(a => new Endpoint(a, _port)).ToList();
        if (_tailnet.IsRunning && _tailnet.Ip is { } ip) eps.Add(new Endpoint(ip, TailnetPort));
        return eps;
    }

    /// <summary>Keeps up to 6 LAN and 2 tailnet endpoints per member, newest first (PROTOCOL.md §4.5).</summary>
    void RememberEndpoints(string peerId, IEnumerable<Endpoint> eps)
    {
        var all = eps.Concat(_store.State.Endpoints.GetValueOrDefault(peerId) ?? []).Distinct().ToList();
        var merged = all.Where(e => !TailnetAddress.Contains(e.H)).Take(6).Concat(all.Where(e => TailnetAddress.Contains(e.H)).Take(2)).ToList();
        _store.State.Endpoints[peerId] = merged;
        _store.SaveSoon();
    }

    void Tick()
    {
        if (!_running) return;
        var now = DateTime.UtcNow;
        foreach (var s in _sessions.ToList()) s.Tick(now);
        if (_ticket is { } t && t.Expires <= DateTimeOffset.UtcNow)
        {
            _ticket = null;
            Emit(new NodeEvent.TicketExpired());
        }
        ExpireTransfers(now);
        Prune();
        if (_tick++ % 5 != 0 || _paused) return;
        RedialDisconnected(now);
    }

    /// <summary>Redials disconnected members at their discovered / remembered endpoints with back-off (PROTOCOL.md §4.5).</summary>
    void RedialDisconnected(DateTime now)
    {
        foreach (var (id, rec) in _store.Members.ToList())
        {
            if (id == DeviceId || rec.Removed || _online.ContainsKey(id) || _dialing.ContainsKey(id)) continue;
            var b = _backoff.TryGetValue(id, out var bb) ? bb : (Next: DateTime.MinValue, Delay: 20.0);
            if (now < b.Next) continue;
            // Every known way to reach the member at once; the first connection wins (PROTOCOL.md §4.5).
            var targets = DialCandidates(id);
            if (targets.Count == 0) continue;
            _backoff[id] = (now.AddSeconds(b.Delay), Math.Min(b.Delay * 2, 300));
            DialMember(id, targets);
        }
    }

    // ================================================================ session callbacks (node queue)

    internal void SessionEstablished(PeerSession s)
    {
        if (s.Retired) { s.Close(); return; }
        if (s.PeerId is null)
        {
            s.Close();
            return;
        }
        // Removal is decided only after the peer's welcome has been merged (PROTOCOL.md §4.3, see SessionWelcome):
        // a device that was removed and re-added while this device was offline carries a newer record of itself
        // than our tombstone, so answering "bye removed" here would wrongly remove it again.
        s.SendJson(Welcome(OwnRecord, MemberList(), OwnEndpoints(), extended: true));
    }

    internal void SessionWelcome(PeerSession s, MemberRecord device, List<MemberRecord> members, List<Endpoint> addrs)
    {
        if (s.Retired) { s.Close(); return; }
        if (s.PeerId is not { } pid) return;
        if (s.ExpectedPeerId is { } expected && expected != pid) _dialing.Remove(expected);
        _dialing.Remove(pid);
        var eps = new List<Endpoint>();
        if (s.Role == PeerSession.SessionRole.Client && s.DialedEndpoint is { } a) eps.Add(a);
        // Never remember the loopback address of connections relayed by the tailnet bridge (§10.1).
        else if (s.Role == PeerSession.SessionRole.Server && !s.ViaTailnet && s.RemoteHost is { } host && addrs.Count > 0) eps.Add(new Endpoint(host, addrs[0].P));
        eps.AddRange(addrs);
        RememberEndpoints(pid, eps);
        members.Add(device);
        MergeMembers(members, s);
        if (s.IsClosed || s.Phase != PeerSession.SessionPhase.Established) return;
        // Still a tombstone after merging its welcome (its own record is older than the removal): it stays removed.
        if (_store.Members.TryGetValue(pid, out var rec) && rec.Removed)
        {
            s.Bye("removed");
            return;
        }
        if (!RegisterOnline(s)) return;
        _backoff.Remove(pid);
        SendInventory(s);
    }

    /// <summary>One session per peer (PROTOCOL.md §4.4): keep the one whose client has the smaller deviceId.</summary>
    bool RegisterOnline(PeerSession s)
    {
        var pid = s.PeerId!;
        if (_online.TryGetValue(pid, out var existing) && existing != s)
        {
            var newClient = s.Role == PeerSession.SessionRole.Client ? DeviceId : pid;
            var oldClient = existing.Role == PeerSession.SessionRole.Client ? DeviceId : pid;
            if (string.CompareOrdinal(newClient, oldClient) < 0)
            {
                _online[pid] = s;
                existing.Bye("duplicate");
                return true;
            }
            s.Bye("duplicate");
            return false;
        }
        _online[pid] = s;
        _store.State.LastSeen[pid] = Clock.NowMs();
        _store.SaveSoon();
        if (_store.Members.TryGetValue(pid, out var rec)) Emit(new NodeEvent.PeerUp(rec, s.Route));
        return true;
    }

    internal void SessionMessage(PeerSession s, string type, JsonElement o)
    {
        if (s.Retired) return;
        switch (type)
        {
            case "rekey":
                ApplyRekey(o, s);
                break;
            case "clip":
                if (Prop(o, "clip") is { } ce && ReadClip(ce) is { } clip) HandleClip(clip, Bool(o, "live") ?? false, s);
                break;
            case "inv":
                HandleInventory(o, s);
                break;
            case "want":
                HandleWant(o, s);
                break;
            case "del":
                ApplyDeletes(ReadIdTs(o, "items"), s);
                break;
            case "members":
                MergeMembers(ReadMembers(o, "members"), s);
                break;
            case "incoming":
                HandleIncoming(o, s);
                break;
            case "error":
                LogMessage($"peer error {Str(o, "code")} {Str(o, "msg")}");
                break;
        }
    }

    internal void SessionBye(PeerSession s, string reason)
    {
        if (s.Retired) return;
        if (reason == "removed" && s.Mode == PeerSession.SessionMode.Member) Leave("removed", announce: false);
    }

    internal void SessionClosed(PeerSession s)
    {
        _sessions.Remove(s);
        foreach (var id in _transfers.Where(kv => kv.Value.Sessions.Contains(s)).Select(kv => kv.Key).ToList())
            DropTransfer(id, s, "disconnected");
        if (s.Role == PeerSession.SessionRole.Client && s.Mode == PeerSession.SessionMode.Member)
        {
            if (s.ExpectedPeerId is { } e) _dialing.Remove(e);
            if (s.PeerId is { } p) _dialing.Remove(p);
        }
        if (s.PeerId is { } pid && _online.TryGetValue(pid, out var cur) && cur == s)
        {
            _online.Remove(pid);
            _store.State.LastSeen[pid] = Clock.NowMs();
            _store.SaveSoon();
            Emit(new NodeEvent.PeerDown(pid));
        }
        if (_codeSession == s)
        {
            _codeSession = null;
            Emit(new NodeEvent.PairPromptDismissed());
        }
        if (_joinSession == s) _joinSession = null;
    }

    internal int MemberSessionCount(string peerId) =>
        Q.Invoke(() => _sessions.Count(s => s.IsMember && s.PeerId == Ids.Norm(peerId)));
}
