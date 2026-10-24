using Microsoft.UI.Dispatching;
using Nearclip.App.Platform;
using Nearclip.Core;

namespace Nearclip.App.Model;

internal enum JoinPhase { Idle, Connecting, Confirm, Success, Failed }

internal sealed record JoinState(JoinPhase Phase, string Name = "", string Code = "", string Reason = "")
{
    public static readonly JoinState Idle = new(JoinPhase.Idle);
    public bool IsBusy => Phase is JoinPhase.Connecting or JoinPhase.Confirm;
}

internal enum NoticeTone { Info, Success, Warning }

internal sealed record Notice(string Text, NoticeTone Tone);

[Flags]
internal enum ModelChange
{
    None = 0, History = 1, Members = 2, Online = 4, Nearby = 8, Ticket = 16, Join = 32, Prompt = 64, Notice = 128,
    Settings = 256, Network = 512, Identity = 1024, Remote = 2048, All = 0x7FFF,
}

/// <summary>The UI-facing state of the engine (port of apple/Shared/AppModel.swift). UI thread only.</summary>
internal sealed class AppModel
{
    readonly NearclipNode _node;
    readonly DispatcherQueue _ui;
    readonly DispatcherQueueTimer _noticeTimer;
    int _ticketDemand;

    public AppSettings Settings { get; }
    public NearclipNode Node => _node;
    public event Action<ModelChange>? Changed;

    /// <summary>Writes a clip to the system clipboard (marked so it is not picked up again).</summary>
    public Func<Clip, byte[]?, Task>? WriteClipboard { get; set; }
    /// <summary>A live clip from another device was written to the clipboard.</summary>
    public Action<StoredClip>? OnReceive { get; set; }
    public Action<PairPrompt>? OnPairPrompt { get; set; }
    /// <summary>Something was sent or received (tray pulse).</summary>
    public Action? OnActivity { get; set; }
    public Action<string, bool>? OnPaired { get; set; }

    public string DeviceId { get; }
    public string DeviceName { get; private set; } = "";
    public string Platform { get; }
    public List<MemberRecord> Members { get; private set; } = [];
    public HashSet<string> Online { get; private set; } = [];
    public Dictionary<string, long> LastSeen { get; private set; } = [];
    public List<StoredClip> History { get; private set; } = [];
    public List<ClipItem> Items { get; private set; } = [];
    public List<NearbyDevice> Nearby { get; private set; } = [];
    public int Port { get; private set; }
    public List<string> Addresses { get; private set; } = [];
    public PairingTicket? Ticket { get; private set; }
    public PairPrompt? PairPrompt { get; private set; }
    public JoinState Join { get; private set; } = JoinState.Idle;
    public Notice? Notice { get; private set; }
    public string? JustJoined { get; private set; }
    /// <summary>Route of every connected device (same network / remote).</summary>
    public Dictionary<string, PeerRoute> Routes { get; private set; } = [];
    /// <summary>The embedded Tailscale node (remote connection).</summary>
    public TailnetStatus Tailnet { get; private set; } = TailnetStatus.Off;
    /// <summary>The Tailscale sign-in page was opened and the node is not running yet.</summary>
    public bool TailnetSigningIn { get; private set; }

    public AppModel(NearclipNode node, AppSettings settings, DispatcherQueue ui)
    {
        _node = node;
        _ui = ui;
        Settings = settings;
        _noticeTimer = ui.CreateTimer();
        _noticeTimer.Interval = TimeSpan.FromSeconds(3.5);
        _noticeTimer.IsRepeating = false;
        _noticeTimer.Tick += (_, _) => { Notice = null; Raise(ModelChange.Notice); };
        var snap = node.Snapshot();
        DeviceId = snap.DeviceId;
        Platform = snap.Platform;
        Apply(snap);
        node.Event += e => _ui.TryEnqueue(() => Handle(e));
    }

    public void Start()
    {
        _node.SetRetention(Settings.RetentionDays);
        _node.SetSyncImages(Settings.SyncImages);
        _node.SetPaused(Settings.Paused);
        _node.SetRemoteEnabled(Settings.RemoteEnabled);
        _node.Start();
    }

    public void Refresh()
    {
        Apply(_node.Snapshot());
        Raise(ModelChange.All);
    }

    void Apply(NodeSnapshot snap)
    {
        DeviceName = snap.DeviceName;
        Members = snap.Members.ToList();
        Online = snap.Online.ToHashSet();
        LastSeen = snap.LastSeen.ToDictionary();
        History = snap.History.ToList();
        Nearby = snap.Nearby.ToList();
        Port = snap.Port;
        Addresses = snap.Addresses.ToList();
        Routes = snap.Routes.ToDictionary();
        Tailnet = snap.Tailnet;
        RebuildItems();
    }

    void Raise(ModelChange change) => Changed?.Invoke(change);

    // ------------------------------------------------------------------ derived

    public MemberRecord? Me => Members.FirstOrDefault(m => m.Id == DeviceId);
    public IEnumerable<MemberRecord> OtherMembers => Members.Where(m => !m.Removed && m.Id != DeviceId);
    public int ConnectedCount => OtherMembers.Count(m => Online.Contains(m.Id));
    public bool IsOnline(string id) => Online.Contains(id);
    public string ThisDeviceLabel => Loc.S("ThisPC");

    public PeerRoute? Route(string id) => Online.Contains(id) && Routes.TryGetValue(id, out var r) ? r : null;

    /// <summary>"Connected · Same network" / "Connected · Remote" (DESIGN.md §4.7).</summary>
    public string ConnectionText(string id)
    {
        if (!Online.Contains(id)) return Format.LastSeen(LastSeen.TryGetValue(id, out var seen) ? seen : null);
        return Route(id) switch
        {
            PeerRoute.Remote => Loc.S("Connected_Remote"),
            PeerRoute.Lan => Loc.S("Connected_SameNetwork"),
            _ => Loc.S("Connected"),
        };
    }

    // ------------------------------------------------------------------ remote connection

    public bool RemoteAvailable => _node.TailnetAvailable;

    /// <summary>Remote connection is off and a device is out of reach: suggest turning it on.</summary>
    public bool SuggestsRemote => RemoteAvailable && !Settings.RemoteEnabled && OtherMembers.Any(m => !Online.Contains(m.Id));

    public void SetRemoteEnabled(bool on)
    {
        Settings.RemoteEnabled = on;
        SaveSettings();
        _node.SetRemoteEnabled(on);
        if (!on)
        {
            Tailnet = TailnetStatus.Off;
            TailnetSigningIn = false;
        }
        Raise(ModelChange.Remote);
    }

    /// <summary>Opens Tailscale's sign-in page in the default browser (asks the node for one first when needed).</summary>
    public async Task SignInToTailscaleAsync()
    {
        TailnetSigningIn = true;
        Raise(ModelChange.Remote);
        var url = Tailnet.AuthUrl;
        if (url is null)
        {
            var st = await _node.TailnetLoginAsync();
            Tailnet = st;
            url = st.AuthUrl;
        }
        if (url is not null && Uri.TryCreate(url, UriKind.Absolute, out var uri))
        {
            try { await Windows.System.Launcher.LaunchUriAsync(uri); } catch (Exception e) { Log.Write("open sign-in page failed: " + e.Message); }
        }
        else
        {
            TailnetSigningIn = false;
        }
        Raise(ModelChange.Remote);
    }

    public void SignOutOfTailscale()
    {
        TailnetSigningIn = false;
        _node.TailnetLogout();
        Raise(ModelChange.Remote);
    }

    /// <summary>Restarts the node after an error.</summary>
    public void RetryRemote()
    {
        _node.SetRemoteEnabled(false);
        _node.SetRemoteEnabled(true);
    }

    public string StatusLine
    {
        get
        {
            if (Settings.Paused) return Loc.S("Status_Paused");
            if (!OtherMembers.Any()) return Loc.S("Status_NoDevices");
            var n = ConnectedCount;
            if (n == 0) return Loc.S("Status_Waiting");
            return n == 1 ? Loc.S("Status_Connected1") : Loc.F("Status_ConnectedN", n);
        }
    }

    public string SourceName(StoredClip sc)
    {
        if (sc.Clip.Src == DeviceId) return ThisDeviceLabel;
        var m = Members.FirstOrDefault(x => x.Id == sc.Clip.Src);
        if (m is { Name.Length: > 0 }) return m.Name;
        return sc.SrcName ?? Loc.S("AnotherDevice");
    }

    public string SourceGlyph(StoredClip sc)
    {
        if (sc.Clip.Src == DeviceId) return Format.PlatformGlyph(Platform, Me?.Model);
        var m = Members.FirstOrDefault(x => x.Id == sc.Clip.Src);
        return Format.PlatformGlyph(m?.Platform ?? sc.SrcPlatform ?? "", m?.Model);
    }

    public List<ClipItem> Filtered(HistoryFilter filter, string query)
    {
        var q = query.Trim();
        return Items.Where(item =>
        {
            if (!item.Matches(filter)) return false;
            if (q.Length == 0) return true;
            if (item.Text.Contains(q, StringComparison.CurrentCultureIgnoreCase)) return true;
            if (SourceName(item.Clip).Contains(q, StringComparison.CurrentCultureIgnoreCase)) return true;
            return item.Kind == ClipKind.Image && Loc.S("Kind_Image").Contains(q, StringComparison.CurrentCultureIgnoreCase);
        }).ToList();
    }

    void RebuildItems()
    {
        var index = new Dictionary<string, ClipItem>();
        var output = new List<ClipItem>(History.Count);
        foreach (var sc in History)
        {
            var key = sc.Clip.IsImage ? "i:" + (sc.Clip.Sha ?? sc.Id) : "t:" + (sc.Clip.Text ?? "");
            if (index.TryGetValue(key, out var existing))
            {
                existing.Ids.Add(sc.Id);
                if (sc.Pinned) existing.Pinned = true;
                continue;
            }
            var item = new ClipItem { Clip = sc, Pinned = sc.Pinned };
            item.Ids.Add(sc.Id);
            index[key] = item;
            output.Add(item);
        }
        Items = output;
    }

    // ------------------------------------------------------------------ clip actions

    /// <summary>Copies an item from history: it becomes the clipboard here and the newest clip everywhere.</summary>
    public async Task CopyAsync(ClipItem item)
    {
        var c = item.Clip.Clip;
        var blob = c.IsImage ? _node.ReadBlob(c.Id) : null;
        if (c.IsImage && blob is null) return;
        if (WriteClipboard is { } write) await write(c, blob);
        if (Settings.Paused || item.Clip.LocalOnly) return;
        if (c.IsText && c.Text is { } t) _node.SendText(t);
        else if (blob is not null && Settings.SyncImages) _node.SendImage(blob, c.Mime ?? "image/png", c.W, c.H);
        OnActivity?.Invoke();
    }

    /// <summary>Something was copied on this PC.</summary>
    public void LocalCopy(CopiedContent content)
    {
        if (Settings.Paused) return;
        switch (content)
        {
            case CopiedContent.Text t:
                if (System.Text.Encoding.UTF8.GetByteCount(t.Value) > Wire.MaxText)
                {
                    _node.AddLocalOnly("text", t.Value, null, null);
                    Show(Loc.S("TooLarge"), NoticeTone.Warning);
                    return;
                }
                if (_node.SendText(t.Value) is not null) OnActivity?.Invoke();
                break;
            case CopiedContent.Image img:
                if (!Settings.SyncImages) return;
                if (img.TooLarge)
                {
                    _node.AddLocalOnly("image", null, img.Data, img.Mime, img.Width, img.Height);
                    Show(Loc.S("TooLarge"), NoticeTone.Warning);
                    return;
                }
                if (_node.SendImage(img.Data, img.Mime, img.Width, img.Height) is not null) OnActivity?.Invoke();
                break;
        }
    }

    public void TogglePin(ClipItem item)
    {
        foreach (var id in item.Ids) _node.SetPinned(id, !item.Pinned);
    }

    public void Delete(ClipItem item) => _node.Delete(item.Ids);

    public void ClearHistory() => _node.ClearHistory();

    // ------------------------------------------------------------------ devices & settings

    public void Rename(string name)
    {
        var t = name.Trim();
        if (t.Length == 0 || t == DeviceName) return;
        DeviceName = t;
        _node.Rename(t);
        Raise(ModelChange.Identity);
    }

    public void Remove(MemberRecord member) => _node.RemoveMember(member.Id);

    public void LeaveGroup() => _node.LeaveGroup();

    public void SetPaused(bool paused)
    {
        Settings.Paused = paused;
        Settings.Save();
        _node.SetPaused(paused);
        if (paused) Online = [];
        Raise(ModelChange.Settings | ModelChange.Online);
    }

    public void SetRetention(int days)
    {
        Settings.RetentionDays = days;
        Settings.Save();
        _node.SetRetention(days);
        Raise(ModelChange.Settings);
    }

    public void SetSyncImages(bool on)
    {
        Settings.SyncImages = on;
        Settings.Save();
        _node.SetSyncImages(on);
        Raise(ModelChange.Settings);
    }

    public void SaveSettings()
    {
        Settings.Save();
        Raise(ModelChange.Settings);
    }

    // ------------------------------------------------------------------ pairing

    /// <summary>Call while an Add-device surface is visible: keeps a fresh QR ticket and advertises pairing mode.</summary>
    public void BeginAddDevice()
    {
        _ticketDemand++;
        _node.SetPairingMode(true);
        if (Ticket is null || Ticket.ExpiresAt < DateTimeOffset.UtcNow.AddSeconds(30)) RequestTicket();
    }

    public void EndAddDevice()
    {
        _ticketDemand = Math.Max(0, _ticketDemand - 1);
        if (_ticketDemand > 0) return;
        _node.SetPairingMode(false);
        _node.CancelTicket();
        Ticket = null;
        Raise(ModelChange.Ticket);
    }

    void RequestTicket()
    {
        if (Port <= 0) return;
        Ticket = _node.CreateTicket();
        Raise(ModelChange.Ticket);
    }

    public bool JoinLink(string link)
    {
        if (PairingInvite.TryParse(link) is not { } invite) return false;
        SetJoin(new JoinState(JoinPhase.Connecting, invite.Name.Length > 0 ? invite.Name : Loc.S("AnotherDevice")));
        _node.Join(invite);
        return true;
    }

    public void PairWith(NearbyDevice device)
    {
        SetJoin(new JoinState(JoinPhase.Connecting, device.Name));
        _node.PairWithCode(device.Id);
    }

    public void PairWithAddress(string host, int port)
    {
        SetJoin(new JoinState(JoinPhase.Connecting, host));
        _node.PairWithCode(host, port);
    }

    public void CancelJoin()
    {
        _node.CancelJoin();
        SetJoin(JoinState.Idle);
    }

    public void DismissJoin() => SetJoin(JoinState.Idle);

    public void FailJoin(string reason) => SetJoin(new JoinState(JoinPhase.Failed, Reason: reason));

    void SetJoin(JoinState s)
    {
        Join = s;
        Raise(ModelChange.Join);
    }

    public void AnswerPrompt(bool accept)
    {
        if (PairPrompt is { } p) _node.AnswerPairPrompt(accept, p.PeerId);
        if (!accept)
        {
            PairPrompt = null;
            Raise(ModelChange.Prompt);
        }
    }

    public static string FailureText(string reason) => reason switch
    {
        "declined" => Loc.S("Fail_Declined"),
        "no_ticket" => Loc.S("Fail_Expired"),
        "unreachable" or "io" => Loc.S("Fail_Unreachable"),
        "timeout" => Loc.S("Fail_Timeout"),
        "busy" => Loc.S("Fail_Busy"),
        "self" => Loc.S("Fail_Self"),
        "bad_uri" => Loc.S("Fail_BadLink"),
        _ => Loc.S("Fail_Generic"),
    };

    public void Show(string text, NoticeTone tone)
    {
        Notice = new Notice(text, tone);
        _noticeTimer.Stop();
        _noticeTimer.Start();
        Raise(ModelChange.Notice);
    }

    // ------------------------------------------------------------------ engine events

    void Insert(StoredClip sc)
    {
        if (History.Any(c => c.Id == sc.Id)) return;
        var i = History.FindIndex(c => c.Clip.Ts < sc.Clip.Ts);
        History.Insert(i < 0 ? History.Count : i, sc);
        RebuildItems();
    }

    async void Handle(NodeEvent e)
    {
        try { await HandleAsync(e); }
        catch (Exception ex) { Log.Write("event handling failed: " + ex); }
    }

    async Task HandleAsync(NodeEvent e)
    {
        switch (e)
        {
            case NodeEvent.Ready r:
                Port = r.Port;
                Addresses = _node.Snapshot().Addresses.ToList();
                if (_ticketDemand > 0) RequestTicket();
                Raise(ModelChange.Network);
                break;
            case NodeEvent.TicketCreated t:
                Ticket = t.Ticket;
                Raise(ModelChange.Ticket);
                break;
            case NodeEvent.TicketExpired:
                Ticket = null;
                if (_ticketDemand > 0) RequestTicket();
                Raise(ModelChange.Ticket);
                break;
            case NodeEvent.PairCode c:
                if (!Join.IsBusy) break; // the user already cancelled this attempt
                SetJoin(new JoinState(JoinPhase.Confirm, c.PeerName.Length > 0 ? c.PeerName : Join.Name, c.Code));
                break;
            case NodeEvent.PairPromptShown p:
                PairPrompt = p.Prompt;
                Raise(ModelChange.Prompt);
                OnPairPrompt?.Invoke(p.Prompt);
                break;
            case NodeEvent.PairPromptDismissed:
                PairPrompt = null;
                Raise(ModelChange.Prompt);
                break;
            case NodeEvent.Paired p:
                if (p.Joined)
                {
                    SetJoin(new JoinState(JoinPhase.Success, p.PeerName));
                }
                else
                {
                    PairPrompt = null;
                    JustJoined = p.PeerName;
                    Show(Loc.F("Pair_Joined", p.PeerName), NoticeTone.Success);
                    Raise(ModelChange.Prompt);
                }
                OnPaired?.Invoke(p.PeerName, p.Joined);
                Refresh();
                break;
            case NodeEvent.PairFailed f:
                // A failure that arrives after the user cancelled (e.g. the other side declines a moment later) must
                // not resurface as a stale "Couldn't connect" the next time Add device opens.
                if (!Join.IsBusy) break;
                SetJoin(new JoinState(JoinPhase.Failed, f.PeerName ?? Join.Name, Reason: f.Reason));
                break;
            case NodeEvent.PeerUp u:
                Online.Add(u.Member.Id);
                Routes[u.Member.Id] = u.Route;
                var idx = Members.FindIndex(m => m.Id == u.Member.Id);
                if (idx >= 0) Members[idx] = u.Member; else Members.Add(u.Member);
                Raise(ModelChange.Online | ModelChange.Members);
                break;
            case NodeEvent.PeerDown d:
                Online.Remove(d.Id);
                Routes.Remove(d.Id);
                LastSeen[d.Id] = Clock.NowMs();
                Raise(ModelChange.Online);
                break;
            case NodeEvent.ClipAdded a:
                Insert(a.Clip);
                Raise(ModelChange.History);
                if (a.Local) break;
                OnActivity?.Invoke();
                var clip = a.Clip.Clip;
                if (a.Apply && Settings.AutoApply && !Settings.Paused && !(clip.IsImage && !Settings.SyncImages))
                {
                    var blob = clip.IsImage ? _node.ReadBlob(clip.Id) : null;
                    if (!clip.IsImage || blob is not null)
                    {
                        if (WriteClipboard is { } write) await write(clip, blob);
                        OnReceive?.Invoke(a.Clip);
                    }
                }
                break;
            case NodeEvent.ClipsDeleted d:
                var set = d.Ids.ToHashSet();
                History.RemoveAll(x => set.Contains(x.Id));
                RebuildItems();
                Raise(ModelChange.History);
                break;
            case NodeEvent.ClipUpdated u:
                var i = History.FindIndex(x => x.Id == u.Clip.Id);
                if (i >= 0) History[i] = u.Clip;
                RebuildItems();
                Raise(ModelChange.History);
                break;
            case NodeEvent.MembersChanged m:
                Members = m.Members.ToList();
                Raise(ModelChange.Members);
                break;
            case NodeEvent.NearbyChanged n:
                Nearby = n.Nearby.ToList();
                Raise(ModelChange.Nearby);
                break;
            case NodeEvent.Left l:
                Refresh();
                Online = [];
                Routes = [];
                if (l.Reason == "removed") Show(Loc.S("Removed_Notice"), NoticeTone.Warning);
                Raise(ModelChange.All);
                break;
            case NodeEvent.TooLarge:
                Show(Loc.S("TooLarge"), NoticeTone.Warning);
                break;
            case NodeEvent.PausedChanged:
                Raise(ModelChange.Settings);
                break;
            case NodeEvent.TailnetChanged tc:
                Tailnet = tc.Status;
                if (tc.Status.IsRunning || tc.Status.State == "off") TailnetSigningIn = false;
                Raise(ModelChange.Remote);
                break;
            case NodeEvent.Log l:
                Log.Write("engine: " + l.Message);
                break;
        }
    }
}
