using System.Security.Cryptography;
using System.Text.Json;
using static Nearclip.Core.WireJson;

namespace Nearclip.Core;

public sealed partial class NearclipNode
{
    // ================================================================ clips (PROTOCOL.md §6.1)

    StoredClip Produce(Clip c, byte[]? blob)
    {
        _newestLocalTs = c.Ts;
        _store.State.NewestLocalTs = c.Ts;
        var sc = new StoredClip(c, GroupId, false, Clock.NowMs(), DeviceName, Platform);
        _store.Add(sc, blob);
        var sent = 0;
        foreach (var s in _online.Values.ToList())
        {
            if (!s.IsMember) continue;
            if (c.IsImage && !_syncImages) continue;
            SendClip(c, blob, true, s);
            sent++;
        }
        Emit(new NodeEvent.ClipAdded(sc, true, false, true));
        Emit(new NodeEvent.Sent(c.Id, sent));
        Prune();
        return sc;
    }

    static void SendClip(Clip c, byte[]? blob, bool live, PeerSession s)
    {
        if (!s.IsMember) return;
        if (c.IsImage)
        {
            if (blob is null) return;
            s.SendJson(ClipMessage(c, live));
            uint index = 0;
            for (var offset = 0; offset < blob.Length; offset += Wire.ChunkSize, index++)
                s.SendChunk(c.Id, index, blob.AsSpan(offset, Math.Min(Wire.ChunkSize, blob.Length - offset)));
        }
        else
        {
            s.SendJson(ClipMessage(c, live));
        }
    }

    void HandleClip(Clip c, bool live, PeerSession s)
    {
        if (!c.IsText && !c.IsImage) return;
        if (_store.Has(c.Id) || _store.State.Tombstones.ContainsKey(c.Id))
        {
            if (c.IsImage) s.SkipBlobs.Add(c.Id);
            return;
        }
        if (c.IsText)
        {
            if (c.Text is not { } t || System.Text.Encoding.UTF8.GetByteCount(t) > Wire.MaxText) return;
            AcceptClip(c, null, live, s);
            return;
        }
        if (c.Size is not { } size || size <= 0 || size > Wire.MaxImage || c.Sha is not { Length: 64 } || !_syncImages)
        {
            if (!_syncImages) _declinedImages.Add(c.Id);
            s.SkipBlobs.Add(c.Id);
            return;
        }
        if (s.PendingBlobs.ContainsKey(c.Id)) return;
        s.PendingBlobs[c.Id] = new PendingBlob(c, live);
    }

    internal void SessionChunk(PeerSession s, string clipId, uint index, ReadOnlyMemory<byte> data)
    {
        if (s.SkipBlobs.Contains(clipId) || !s.PendingBlobs.TryGetValue(clipId, out var p)) return;
        var size = p.Clip.Size ?? 0;
        if (index != p.Next || data.Length == 0 || data.Length > Wire.ChunkSize || p.Data.Length + data.Length > size)
        {
            s.PendingBlobs.Remove(clipId);
            p.Data.Dispose();
            s.SkipBlobs.Add(clipId);
            LogMessage("bad chunk for " + clipId);
            return;
        }
        p.Data.Write(data.Span);
        p.Next++;
        if (p.Data.Length < size) return;
        s.PendingBlobs.Remove(clipId);
        var blob = p.Data.ToArray();
        p.Data.Dispose();
        if (Hex.Encode(SHA256.HashData(blob)) != p.Clip.Sha)
        {
            LogMessage("checksum mismatch for " + clipId);
            return;
        }
        if (_store.Has(clipId) || _store.State.Tombstones.ContainsKey(clipId)) return;
        AcceptClip(p.Clip, blob, p.Live, s);
    }

    void AcceptClip(Clip c, byte[]? blob, bool live, PeerSession? from)
    {
        _store.Members.TryGetValue(c.Src, out var src);
        var sc = new StoredClip(c, GroupId, false, Clock.NowMs(), src?.Name, src?.Platform);
        _store.Add(sc, blob);
        // Forward to every other open member session so partially connected meshes converge.
        foreach (var other in _online.Values.ToList())
            if (other != from) SendClip(c, blob, live, other);
        var apply = live && c.Src != DeviceId && c.Ts > _newestLocalTs;
        if (apply)
        {
            _newestLocalTs = c.Ts;
            _store.State.NewestLocalTs = c.Ts;
        }
        Emit(new NodeEvent.ClipAdded(sc, live, apply, false));
        Prune();
    }

    void Prune()
    {
        var removed = _store.Prune(Clock.NowMs());
        if (removed.Count > 0) Emit(new NodeEvent.ClipsDeleted(removed));
    }

    // ================================================================ inventory & catch-up (§6.2)

    void SendInventory(PeerSession s)
    {
        var now = Clock.NowMs();
        var gid = GroupId;
        var clips = _store.History
            .Where(c => c.GroupId == gid && !c.LocalOnly && c.Clip.Ts >= now - 7 * Wire.DayMs)
            .Take(200)
            .Select(c => new IdTs(c.Id, c.Clip.Ts))
            .ToList();
        var dels = _store.State.Tombstones.Where(t => t.Value >= now - 30 * Wire.DayMs).Select(t => new IdTs(t.Key, t.Value)).ToList();
        s.SendJson(Inventory(clips, dels));
    }

    void HandleInventory(JsonElement o, PeerSession s)
    {
        ApplyDeletes(ReadIdTs(o, "dels"), s);
        var cutoff = _store.RetentionDays > 0 ? Clock.NowMs() - _store.RetentionDays * Wire.DayMs : 0;
        var want = ReadIdTs(o, "clips")
            .Where(x => !_store.Has(x.Id) && !_store.State.Tombstones.ContainsKey(x.Id) && x.Ts >= cutoff && !_declinedImages.Contains(x.Id))
            .Select(x => x.Id)
            .Distinct()
            .ToList();
        if (want.Count > 0) s.SendJson(Want(want));
    }

    void HandleWant(JsonElement o, PeerSession s)
    {
        var gid = GroupId;
        foreach (var raw in Arr(o, "ids").Where(x => x.ValueKind == JsonValueKind.String).Take(500))
        {
            if (_store.Get(Ids.Norm(raw.GetString())) is not { } sc || sc.GroupId != gid || sc.LocalOnly) continue;
            if (sc.Clip.IsImage)
            {
                // Images larger than 16 MiB are skipped during catch-up.
                if ((sc.Clip.Size ?? 0) > Wire.MaxCatchUpImage || _store.ReadBlob(sc.Id) is not { } blob) continue;
                SendClip(sc.Clip, blob, false, s);
            }
            else
            {
                SendClip(sc.Clip, null, false, s);
            }
        }
    }

    // ================================================================ deletion (§6.3)

    void ApplyDeletes(IReadOnlyList<IdTs> items, PeerSession? from)
    {
        var fresh = new List<IdTs>();
        foreach (var it in items)
        {
            var id = Ids.Norm(it.Id);
            if (id.Length == 0 || _store.State.Tombstones.ContainsKey(id)) continue;
            _store.State.Tombstones[id] = it.Ts;
            _store.Remove(id);
            fresh.Add(new IdTs(id, it.Ts));
        }
        if (fresh.Count == 0) return;
        _store.SaveSoon();
        foreach (var other in _online.Values.ToList())
            if (other != from) other.SendJson(WireJson.Delete(fresh));
        Emit(new NodeEvent.ClipsDeleted(fresh.Select(f => f.Id).ToList()));
    }

    // ================================================================ members (§1.1, §6.4)

    void MergeMembers(IReadOnlyList<MemberRecord> incoming, PeerSession? source)
    {
        var changed = new List<MemberRecord>();
        var mustLeave = false;
        foreach (var raw in incoming)
        {
            var r = raw with { Id = Ids.Norm(raw.Id) };
            if (r.Id.Length == 0) continue;
            if (r.Id == DeviceId)
            {
                if (r.Removed && r.UpdatedAt >= OwnRecord.UpdatedAt) mustLeave = true;
                continue;
            }
            if (_store.Members.TryGetValue(r.Id, out var cur))
            {
                if (r.UpdatedAt > cur.UpdatedAt || (r.UpdatedAt == cur.UpdatedAt && r.Removed && !cur.Removed))
                {
                    _store.Members[r.Id] = r;
                    changed.Add(r);
                }
            }
            else
            {
                _store.Members[r.Id] = r;
                changed.Add(r);
            }
        }
        if (changed.Count > 0)
        {
            _store.SaveSoon();
            foreach (var r in changed.Where(r => r.Removed))
                if (_online.TryGetValue(r.Id, out var s)) s.Bye("removed");
            foreach (var (pid, s) in _online.ToList())
            {
                if (s == source) continue;
                if (_store.Members.TryGetValue(pid, out var m) && m.Removed) continue;
                s.SendJson(Members(changed));
            }
            Emit(new NodeEvent.MembersChanged(MemberList()));
        }
        if (mustLeave) Leave("removed", announce: false);
    }

    void SwitchGroup(string id, byte[] key)
    {
        var old = _store.State.GroupId;
        _o.SecretStore.Save(key, "group-key-" + id);
        if (old != id) _o.SecretStore.Delete("group-key-" + old);
        _store.State.GroupId = id;
        _store.State.JoinedAt = Clock.NowMs();
        SetGroupKey(key);
        _ticket = null;
    }

    /// <summary>Wipes the group key, starts a new solo group, keeps local history (PROTOCOL.md §1.1).</summary>
    void Leave(string reason, bool announce)
    {
        if (announce)
        {
            var me = OwnRecord with { Removed = true, UpdatedAt = Math.Max(Clock.NowMs(), OwnRecord.UpdatedAt + 1) };
            foreach (var s in _online.Values.ToList()) s.SendJson(Members([me]));
        }
        foreach (var s in _sessions.Where(x => x.Mode == PeerSession.SessionMode.Member).ToList())
        {
            s.Detached = true;
            s.Bye(reason == "removed" ? "shutdown" : "leaving");
        }
        _online.Clear();
        _dialing.Clear();
        _backoff.Clear();
        SwitchGroup(Ids.New(), NcCrypto.Random(32));
        var now = Clock.NowMs();
        _store.Members = new Dictionary<string, MemberRecord>
        {
            [DeviceId] = new MemberRecord(DeviceId, DeviceName, Platform, _o.Model, _o.AppVersion, now, now, false),
        };
        _store.State.Endpoints.Clear();
        _store.State.LastSeen.Clear();
        _store.SaveSoon();
        RefreshAdvertisement();
        Emit(new NodeEvent.Left(reason));
        Emit(new NodeEvent.MembersChanged(MemberList()));
        Emit(new NodeEvent.NearbyChanged(NearbyList()));
    }

    // ================================================================ pairing (§5)

    PairingTicket CreateTicketInternal()
    {
        var secret = NcCrypto.Random(16);
        var invite = new PairingInvite(DeviceId, DeviceName, Platform, _o.AddressProvider(), _port, secret);
        var t = new Ticket { Secret = secret, Expires = DateTimeOffset.UtcNow.AddMinutes(10) };
        _ticket = t;
        var pt = new PairingTicket(invite, t.Expires);
        Emit(new NodeEvent.TicketCreated(pt));
        return pt;
    }

    internal byte[]? CurrentTicketSecret() =>
        _ticket is { } t && t.Expires > DateTimeOffset.UtcNow ? t.Secret : null;

    internal void TicketDecryptFailed()
    {
        if (_ticket is not { } t) return;
        t.Failures++;
        if (t.Failures >= 10)
        {
            _ticket = null;
            Emit(new NodeEvent.TicketExpired());
        }
    }

    internal bool ReserveCodePairing(PeerSession s)
    {
        var now = DateTime.UtcNow;
        _codeAttempts.RemoveAll(t => now - t >= TimeSpan.FromMinutes(1));
        if (_codeSession is { IsClosed: false }) return false;
        if (_codeAttempts.Count >= 10) return false;
        _codeAttempts.Add(now);
        _codeSession = s;
        return true;
    }

    internal void InviterPrompt(PeerSession s)
    {
        if (_codeSession != s || s.PeerId is not { } pid)
        {
            s.Close();
            return;
        }
        var rec = s.PeerRecord;
        var name = !string.IsNullOrEmpty(rec?.Name) ? rec!.Name : s.PeerName ?? "";
        var pf = !string.IsNullOrEmpty(rec?.Platform) ? rec!.Platform : s.PeerPlatform ?? "";
        Emit(new NodeEvent.PairPromptShown(new PairPrompt(pid, name, pf, s.Sas ?? "")));
    }

    internal void InviterAccept(PeerSession s)
    {
        if (s.PeerId is not { } pid || s.PeerRecord is not { } rec)
        {
            s.Close();
            return;
        }
        var now = Clock.NowMs();
        var existing = _store.Members.GetValueOrDefault(pid);
        rec = rec with { Id = pid, AddedAt = now, UpdatedAt = Math.Max(now, (existing?.UpdatedAt ?? 0) + 1), Removed = false };
        _store.Members[pid] = rec;
        s.SendJson(PairAccept(GroupId, GroupKey, OwnRecord, MemberList()), thenClose: true);
        if (s.Mode == PeerSession.SessionMode.PairQr)
        {
            _ticket = null;
            Emit(new NodeEvent.TicketExpired());
        }
        if (_codeSession == s) _codeSession = null;
        _store.SaveSoon();
        foreach (var (opid, o) in _online.ToList())
            if (opid != pid) o.SendJson(Members([rec]));
        Emit(new NodeEvent.MembersChanged(MemberList()));
        Emit(new NodeEvent.Paired(GroupId, pid, rec.Name, rec.Platform, false));
    }

    internal void JoinerGotCode(PeerSession s) =>
        Emit(new NodeEvent.PairCode(s.Sas ?? "", s.PeerName ?? "", s.PeerPlatform ?? ""));

    void JoinInternal(PairingInvite invite)
    {
        if (_joining)
        {
            Emit(new NodeEvent.PairFailed("busy", invite.Name));
            return;
        }
        if (invite.InviterId == DeviceId)
        {
            Emit(new NodeEvent.PairFailed("self", invite.Name));
            return;
        }
        var targets = new List<Endpoint>();
        if (_discovered.TryGetValue(invite.InviterId, out var d)) targets.AddRange(d.Endpoints);
        targets.AddRange(invite.Hosts.Select(h => new Endpoint(h, invite.Port)));
        if (targets.Count == 0)
        {
            Emit(new NodeEvent.PairFailed("unreachable", invite.Name));
            return;
        }
        StartJoin(PeerSession.SessionMode.PairQr, invite.Secret, targets.Distinct().ToList(), invite.Name);
    }

    void StartCodeJoin(IReadOnlyList<Endpoint> targets, string? peerName)
    {
        if (_joining)
        {
            Emit(new NodeEvent.PairFailed("busy", peerName));
            return;
        }
        StartJoin(PeerSession.SessionMode.PairCode, null, targets, peerName);
    }

    void StartJoin(PeerSession.SessionMode mode, byte[]? secret, IReadOnlyList<Endpoint> targets, string? peerName)
    {
        _joining = true;
        var s = new PeerSession(this, mode, targets) { PairSecret = secret };
        s.OnPairResult = outcome =>
        {
            if (outcome.Accept is { } accept)
            {
                CompleteJoin(accept, s);
                return;
            }
            _joining = false;
            var e = outcome.Error ?? NearclipException.Io("closed");
            var reason = e.Kind == ErrorKind.Timeout ? "timeout" : e.Code;
            if (e.Kind == ErrorKind.Io)
            {
                // No address answered → unreachable. After the hello exchange in pair-qr mode the inviter closes
                // silently when it cannot decrypt our request: the ticket was wrong, used or expired → no_ticket.
                if (!s.GotPeerHello) reason = "unreachable";
                else if (mode == PeerSession.SessionMode.PairQr) reason = "no_ticket";
            }
            Emit(new NodeEvent.PairFailed(reason, s.PeerName ?? peerName));
        };
        _joinSession = s;
        _sessions.Add(s);
        s.Start();
    }

    void CompleteJoin(PairAcceptInfo accept, PeerSession s)
    {
        _joining = false;
        var inviter = accept.Device.Id;
        foreach (var o in _sessions.Where(x => x.Mode == PeerSession.SessionMode.Member).ToList())
        {
            o.Detached = true;
            o.Bye("leaving");
        }
        _online.Clear();
        _dialing.Clear();
        _backoff.Clear();
        SwitchGroup(accept.GroupId, accept.Key);
        var members = new Dictionary<string, MemberRecord>();
        foreach (var raw in accept.Members.Append(accept.Device))
        {
            var r = raw with { Id = Ids.Norm(raw.Id) };
            if (members.TryGetValue(r.Id, out var cur) && cur.UpdatedAt > r.UpdatedAt) continue;
            members[r.Id] = r;
        }
        var me = members.TryGetValue(DeviceId, out var m0) ? m0 : OwnRecord;
        me = me with
        {
            Name = DeviceName, Platform = Platform, Model = _o.Model, App = _o.AppVersion, Removed = false,
            UpdatedAt = Math.Max(Clock.NowMs(), me.UpdatedAt + 1),
        };
        members[DeviceId] = me;
        _store.Members = members;
        _store.State.Endpoints.Clear();
        if (s.DialedEndpoint is { } a) _store.State.Endpoints[inviter] = [a];
        _store.SaveSoon();
        RefreshAdvertisement();
        Emit(new NodeEvent.MembersChanged(MemberList()));
        Emit(new NodeEvent.NearbyChanged(NearbyList()));
        Emit(new NodeEvent.Paired(GroupId, inviter, accept.Device.Name, accept.Device.Platform, true));
        var targets = new List<Endpoint>();
        if (s.DialedEndpoint is { } ep) targets.Add(ep);
        if (_discovered.TryGetValue(inviter, out var d)) targets.AddRange(d.Endpoints);
        if (targets.Count > 0) DialMember(inviter, targets.Distinct().ToList());
        foreach (var d2 in _discovered.Values.Where(x => x.Gt == GroupTag && x.Id != inviter).ToList()) ConsiderDial(d2);
    }
}
