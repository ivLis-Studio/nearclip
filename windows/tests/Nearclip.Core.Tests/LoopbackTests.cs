using Xunit;

namespace Nearclip.Core.Tests;

/// <summary>Real engines talking over localhost TCP: pairing, live sync, catch-up, deletion, removal, mesh forwarding.</summary>
public sealed class LoopbackTests : IDisposable
{
    readonly List<TestPeer> _peers = [];

    TestPeer Peer(string name)
    {
        var p = new TestPeer(name);
        _peers.Add(p);
        return p;
    }

    public void Dispose()
    {
        foreach (var p in _peers) p.Dispose();
    }

    static void PairQr(TestPeer inviter, TestPeer joiner)
    {
        _ = inviter.Port;
        inviter.Mark();
        joiner.Mark();
        var ticket = inviter.Node.CreateTicket();
        Assert.Equal(["127.0.0.1"], ticket.Invite.Hosts);
        joiner.Node.Join(PairingInvite.TryParse(ticket.Uri)!);
        joiner.Wait<NodeEvent.Paired>("paired (joiner)", e => e.PeerId == inviter.Id && e.Joined);
        inviter.Wait<NodeEvent.Paired>("paired (inviter)", e => e.PeerId == joiner.Id && !e.Joined);
        joiner.Wait<NodeEvent.PeerUp>("peer up (joiner)", e => e.Member.Id == inviter.Id);
        inviter.Wait<NodeEvent.PeerUp>("peer up (inviter)", e => e.Member.Id == joiner.Id);
    }

    static void PairCode(TestPeer inviter, TestPeer joiner, bool accept = true)
    {
        inviter.Mark();
        joiner.Mark();
        joiner.Node.PairWithCode("127.0.0.1", inviter.Port);
        var prompt = inviter.Wait<NodeEvent.PairPromptShown>("pair prompt").Prompt;
        var code = joiner.Wait<NodeEvent.PairCode>("pair code");
        Assert.Matches("^[0-9]{6}$", code.Code);
        Assert.Equal(prompt.Code, code.Code);
        Assert.Equal(joiner.Id, prompt.PeerId);
        Assert.Equal(joiner.Name, prompt.Name);
        Assert.Equal(inviter.Name, code.PeerName);
        if (!accept)
        {
            inviter.Node.AnswerPairPrompt(false, joiner.Id);
            Assert.Equal("declined", joiner.Wait<NodeEvent.PairFailed>("declined").Reason);
            return;
        }
        inviter.Node.AnswerPairPrompt(true, joiner.Id);
        joiner.Wait<NodeEvent.Paired>("paired (joiner)", e => e.PeerId == inviter.Id && e.Joined);
        inviter.Wait<NodeEvent.Paired>("paired (inviter)", e => e.PeerId == joiner.Id && !e.Joined);
        joiner.Wait<NodeEvent.PeerUp>("peer up", e => e.Member.Id == inviter.Id);
    }

    [Fact]
    public void QrPairing_LiveSync_MultiChunkImage_Delete_CatchUpAfterRestart_Removal()
    {
        var a = Peer("Alpha");
        var b = Peer("Bravo");
        PairQr(a, b);
        Assert.Equal(a.Node.Snapshot().GroupId, b.Node.Snapshot().GroupId);
        Assert.Equal(2, a.Node.Snapshot().Members.Count);

        // Live text, both ways.
        var hello = a.Node.SendText("hello from alpha · 안녕 👋")!;
        var got = b.Wait<NodeEvent.ClipAdded>("text clip", e => !e.Local && e.Clip.Id == hello.Id);
        Assert.True(got.Live);
        Assert.True(got.Apply);
        Assert.Equal("hello from alpha · 안녕 👋", got.Clip.Clip.Text);
        Assert.Equal(a.Id, got.Clip.Clip.Src);
        Assert.Equal("Alpha", got.Clip.SrcName);
        var reply = b.Node.SendText("reply from bravo")!;
        var back = a.Wait<NodeEvent.ClipAdded>("reply", e => !e.Local && e.Clip.Id == reply.Id);
        Assert.True(back.Live && back.Apply);

        // Multi-chunk image (3 chunks).
        var image = NcCrypto.Random(2_621_440 + 123);
        var img = a.Node.SendImage(image, "image/png", 64, 48)!;
        var gi = b.Wait<NodeEvent.ClipAdded>("image clip", e => !e.Local && e.Clip.Id == img.Id, 30);
        Assert.Equal(image.Length, gi.Clip.Clip.Size);
        Assert.Equal(64, gi.Clip.Clip.W);
        Assert.Equal(image, b.Node.ReadBlob(img.Id));

        // Deletion propagates.
        a.Node.Delete([img.Id]);
        b.Wait<NodeEvent.ClipsDeleted>("deleted", e => e.Ids.Contains(img.Id));
        Assert.DoesNotContain(b.Node.Snapshot().History, c => c.Id == img.Id);
        Assert.Null(b.Node.ReadBlob(img.Id));

        // Catch-up after restart: Bravo goes away, Alpha copies, Bravo comes back with the same state.
        a.Mark();
        b.Node.Stop();
        a.Wait<NodeEvent.PeerDown>("bravo down", e => e.Id == b.Id);
        var away = a.Node.SendText("while you were away")!;
        a.Mark();
        b.Restart();
        var catchUp = b.Wait<NodeEvent.ClipAdded>("catch-up", e => e.Clip.Id == away.Id, 30);
        Assert.False(catchUp.Live);
        Assert.False(catchUp.Apply);
        a.Wait<NodeEvent.PeerUp>("bravo back", e => e.Member.Id == b.Id, 30);
        // Deleted clips are not resurrected by catch-up.
        Assert.DoesNotContain(b.Node.Snapshot().History, c => c.Id == img.Id);

        // Removal: Alpha removes Bravo, Bravo leaves the group and keeps its history.
        b.Mark();
        a.Node.RemoveMember(b.Id);
        b.Wait<NodeEvent.Left>("left", e => e.Reason == "removed");
        Assert.NotEqual(a.Node.Snapshot().GroupId, b.Node.Snapshot().GroupId);
        Assert.Contains(b.Node.Snapshot().History, c => c.Id == away.Id);
        Assert.True(a.Node.Snapshot().Members.Single(m => m.Id == b.Id).Removed);
        Assert.Single(b.Node.Snapshot().Members);
    }

    [Fact]
    public void CodePairing_DeclineThenAccept_CatchUp_RenameGossip()
    {
        var x = Peer("Xavier");
        var y = Peer("Yankee 윤");
        var early = x.Node.SendText("before pairing")!;
        PairCode(x, y, accept: false);
        Assert.NotEqual(x.Node.Snapshot().GroupId, y.Node.Snapshot().GroupId);
        PairCode(x, y, accept: true);
        var ce = y.Wait<NodeEvent.ClipAdded>("catch-up of earlier clip", e => e.Clip.Id == early.Id);
        Assert.False(ce.Live);
        x.Mark();
        y.Node.Rename("Yankee renamed");
        x.Wait<NodeEvent.MembersChanged>("rename gossip", e => e.Members.Any(m => m.Id == y.Id && m.Name == "Yankee renamed"));
    }

    [Fact]
    public void QrPairing_WithWrongSecret_Fails()
    {
        var a = Peer("Alpha");
        var b = Peer("Bravo");
        _ = a.Port;
        var ticket = a.Node.CreateTicket();
        b.Node.Join(ticket.Invite with { Secret = NcCrypto.Random(16) });
        Assert.Equal("no_ticket", b.Wait<NodeEvent.PairFailed>("pair failed").Reason);
        Assert.NotEqual(a.Node.Snapshot().GroupId, b.Node.Snapshot().GroupId);
        // Without any ticket the inviter answers no_ticket.
        a.Node.CancelTicket();
        b.Mark();
        b.Node.Join(ticket.Invite);
        Assert.Equal("no_ticket", b.Wait<NodeEvent.PairFailed>("no ticket").Reason);
    }

    [Fact]
    public void QrTicket_IsSingleUse()
    {
        var a = Peer("Alpha");
        var b = Peer("Bravo");
        var c = Peer("Charlie");
        PairQr(a, b);
        // The ticket b used is consumed.
        var used = a.Node.Snapshot();
        Assert.Equal(2, used.Members.Count);
        c.Node.Join(new PairingInvite(a.Id, "Alpha", "cli", ["127.0.0.1"], a.Port, NcCrypto.Random(16)));
        Assert.Equal("no_ticket", c.Wait<NodeEvent.PairFailed>("used ticket").Reason);
    }

    [Fact]
    public void Pairing_WithNoAnsweringAddress_IsUnreachable()
    {
        var a = Peer("A");
        _ = a.Port;
        // A port nobody listens on: bind and release one.
        var probe = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        probe.Start();
        var dead = ((System.Net.IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        a.Node.PairWithCode("127.0.0.1", dead);
        Assert.Equal("unreachable", a.Wait<NodeEvent.PairFailed>("code pairing to a dead port").Reason);
        a.Mark();
        a.Node.Join(new PairingInvite(Ids.New(), "Ghost", "mac", ["127.0.0.1"], dead, NcCrypto.Random(16)));
        Assert.Equal("unreachable", a.Wait<NodeEvent.PairFailed>("qr pairing to a dead port").Reason);
    }

    [Fact]
    public void MeshForwarding_ThroughMiddleNode()
    {
        var a = Peer("A");
        var b = Peer("B");
        var c = Peer("C");
        PairQr(a, b);
        PairCode(b, c);
        a.Wait<NodeEvent.MembersChanged>("A learns C via gossip", e => e.Members.Any(m => m.Id == c.Id), 30);
        foreach (var (src, dst) in new[] { (a, c), (c, a) })
        {
            var text = $"mesh {src.Name}->{dst.Name} {Guid.NewGuid()}";
            var clip = src.Node.SendText(text)!;
            var ev = dst.Wait<NodeEvent.ClipAdded>("forwarded clip", e => e.Clip.Id == clip.Id, 30);
            Assert.Equal(src.Id, ev.Clip.Clip.Src);
            Assert.True(ev.Live);
        }
        Assert.DoesNotContain(c.Id, a.Node.Snapshot().Online);
        var cid = a.Node.Snapshot().History[0].Id;
        c.Node.Delete([cid]);
        a.Wait<NodeEvent.ClipsDeleted>("forwarded delete", e => e.Ids.Contains(cid), 30);
        // Forwarded image as well.
        var image = NcCrypto.Random(1_500_000);
        var img = a.Node.SendImage(image, "image/png")!;
        c.Wait<NodeEvent.ClipAdded>("forwarded image", e => e.Clip.Id == img.Id, 30);
        Assert.Equal(image, c.Node.ReadBlob(img.Id));
    }

    [Fact]
    public void SimultaneousSessions_KeepExactlyOnePerPeer()
    {
        var a = Peer("A");
        var b = Peer("B");
        PairQr(a, b);
        a.Mark();
        b.Mark();
        // Both directions at once: the rule of §4.4 must leave one agreed session.
        a.Node.Connect("127.0.0.1", b.Port);
        b.Node.Connect("127.0.0.1", a.Port);
        Thread.Sleep(2500);
        Assert.Equal(1, a.Node.MemberSessionCount(b.Id));
        Assert.Equal(1, b.Node.MemberSessionCount(a.Id));
        Assert.Contains(b.Id, a.Node.Snapshot().Online);
        var clip = a.Node.SendText("after dedup")!;
        b.Wait<NodeEvent.ClipAdded>("text after dedup", e => e.Clip.Id == clip.Id);
    }

    [Fact]
    public void MemberSession_FromAnotherGroup_IsRefused()
    {
        var a = Peer("A");
        var b = Peer("B");
        b.Node.Connect("127.0.0.1", a.Port);
        Thread.Sleep(1500);
        Assert.Empty(a.Node.Snapshot().Online);
        Assert.Empty(b.Node.Snapshot().Online);
        Assert.False(a.Saw<NodeEvent.PeerUp>());
    }

    [Fact]
    public void Pause_Disconnects_Resume_Reconnects_And_CatchesUp()
    {
        var a = Peer("A");
        var b = Peer("B");
        PairQr(a, b);
        a.Mark();
        b.Mark();
        a.Node.SetPaused(true);
        b.Wait<NodeEvent.PeerDown>("a paused", e => e.Id == a.Id);
        Assert.True(a.Node.Snapshot().Paused);
        var during = b.Node.SendText("sent while a was paused")!;
        a.Node.SetPaused(false);
        a.Wait<NodeEvent.PeerUp>("reconnected", e => e.Member.Id == b.Id, 20);
        var ev = a.Wait<NodeEvent.ClipAdded>("catch-up after resume", e => e.Clip.Id == during.Id, 20);
        Assert.False(ev.Live);
    }

    /// <summary>PROTOCOL.md §4.3: a device that was removed and added again must not be removed a second time by a
    /// member that was offline during the re-add and still holds the old tombstone (welcomes are merged first).</summary>
    [Fact]
    public void ReAddedDevice_IsNotRemovedAgain_ByMemberThatMissedTheReAdd()
    {
        var a = Peer("A");
        var b = Peer("B");
        var x = Peer("X");
        PairQr(a, b);
        PairQr(a, x);
        b.Wait<NodeEvent.MembersChanged>("b learns x", e => e.Members.Any(m => m.Id == x.Id && !m.Removed));
        x.Mark();
        b.Mark();
        a.Node.RemoveMember(x.Id);
        x.Wait<NodeEvent.Left>("x removed", e => e.Reason == "removed");
        b.Wait<NodeEvent.MembersChanged>("b gets the tombstone", e => e.Members.Any(m => m.Id == x.Id && m.Removed));

        // B is offline while X is added again; then only B (stale tombstone) and X are online and X dials B.
        b.Node.Stop();
        PairQr(a, x);
        Assert.False(a.Node.Snapshot().Members.Single(m => m.Id == x.Id).Removed);
        a.Node.Stop();
        b.Restart();
        x.Mark();
        x.Node.Connect("127.0.0.1", b.Port);
        b.Wait<NodeEvent.PeerUp>("x up at b", e => e.Member.Id == x.Id, 20);
        x.Wait<NodeEvent.PeerUp>("b up at x", e => e.Member.Id == b.Id, 20);
        Assert.False(x.Saw<NodeEvent.Left>());
        Assert.False(b.Node.Snapshot().Members.Single(m => m.Id == x.Id).Removed);
        Assert.Equal(b.Node.Snapshot().GroupId, x.Node.Snapshot().GroupId);

        // A device removed while it was offline still loses against the newer tombstone.
        x.Mark();
        b.Node.RemoveMember(x.Id);
        x.Wait<NodeEvent.Left>("x removed again", e => e.Reason == "removed");
    }

    [Fact]
    public void LeaveGroup_TombstonesSelfAtPeers_AndKeepsHistory()
    {
        var a = Peer("A");
        var b = Peer("B");
        PairQr(a, b);
        var clip = a.Node.SendText("shared")!;
        b.Wait<NodeEvent.ClipAdded>("shared", e => e.Clip.Id == clip.Id);
        a.Mark();
        b.Mark();
        b.Node.LeaveGroup();
        b.Wait<NodeEvent.Left>("left", e => e.Reason == "leaving");
        a.Wait<NodeEvent.MembersChanged>("b tombstoned", e => e.Members.Any(m => m.Id == b.Id && m.Removed));
        Thread.Sleep(500);
        // Only one Left: the stale session of the old group must not make b leave twice.
        Assert.False(b.Saw<NodeEvent.Left>(e => e.Reason == "removed"));
        Assert.Contains(b.Node.Snapshot().History, c => c.Id == clip.Id);
        Assert.NotEqual(a.Node.Snapshot().GroupId, b.Node.Snapshot().GroupId);
    }

    [Fact]
    public void History_IsPersisted_PinsAreLocal_AndRetentionPrunes()
    {
        var a = Peer("A");
        var b = Peer("B");
        PairQr(a, b);
        var t = a.Node.SendText("pin me")!;
        b.Wait<NodeEvent.ClipAdded>("clip", e => e.Clip.Id == t.Id);
        a.Node.SetPinned(t.Id, true);
        a.Wait<NodeEvent.ClipUpdated>("pinned", e => e.Clip.Id == t.Id && e.Clip.Pinned);
        Assert.False(b.Node.Snapshot().History.Single(c => c.Id == t.Id).Pinned);
        a.Restart();
        var after = a.Node.Snapshot().History.Single(c => c.Id == t.Id);
        Assert.True(after.Pinned);
        Assert.Equal("pin me", after.Clip.Text);
        // Item cap keeps pinned clips.
        for (var i = 0; i < 5; i++) a.Node.SendText("filler " + i);
        a.Node.SetRetention(30, maxItems: 2);
        Thread.Sleep(300);
        var h = a.Node.Snapshot().History;
        Assert.Contains(h, c => c.Id == t.Id);
        Assert.Equal(2, h.Count(c => !c.Pinned));
    }

    [Fact]
    public void LargeText_SurvivesRestart_AndLocalOnlyClipsAreNotAdvertised()
    {
        var a = Peer("A");
        var b = Peer("B");
        PairQr(a, b);
        var big = new string('가', 400_000); // ~1.2 MB UTF-8: stored in a side file
        var clip = a.Node.SendText(big)!;
        b.Wait<NodeEvent.ClipAdded>("big text", e => e.Clip.Id == clip.Id, 30);
        var local = a.Node.AddLocalOnly("text", "too big to sync", null, null)!;
        Assert.True(local.LocalOnly);
        b.Mark();
        b.Restart();
        Assert.Equal(big, b.Node.Snapshot().History.Single(c => c.Id == clip.Id).Clip.Text);
        b.Wait<NodeEvent.PeerUp>("b back", e => e.Member.Id == a.Id, 30);
        Thread.Sleep(800);
        Assert.DoesNotContain(b.Node.Snapshot().History, c => c.Id == local.Id);
    }
}
