using System.Security.Cryptography;
using System.Text;
using Xunit;

namespace Nearclip.Core.Tests;

public sealed class PrivacyTests
{
    [Fact]
    public void VaultMigratesLegacyFilesAndAuthenticatesContentAndFilename()
    {
        var dir = Path.Combine(Path.GetTempPath(), "nearclip-vault-test-" + Guid.NewGuid());
        Directory.CreateDirectory(dir);
        try {
            var secrets = new FileSecretStore(Path.Combine(dir, "keys"));
            var vault = new LocalVault(secrets);
            var path = Path.Combine(dir, "history.json");
            var plain = Encoding.UTF8.GetBytes("private history 482915 · 비공개 👋");
            File.WriteAllBytes(path, plain);
            Assert.Equal(plain, vault.Read(path));
            var encrypted = File.ReadAllBytes(path);
            Assert.True(encrypted.AsSpan().StartsWith("NCV1"u8));
            Assert.DoesNotContain("private history", Encoding.UTF8.GetString(encrypted));
            Assert.Equal(plain, new LocalVault(secrets).Read(path));
            var swapped = Path.Combine(dir, "another.json");
            File.WriteAllBytes(swapped, encrypted);
            Assert.ThrowsAny<CryptographicException>(() => vault.Read(swapped));
            encrypted[^1] ^= 1;
            File.WriteAllBytes(path, encrypted);
            Assert.ThrowsAny<CryptographicException>(() => vault.Read(path));
            Assert.Equal(encrypted, File.ReadAllBytes(path)); // corrupt files are never overwritten
        } finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public void CiphertextCannotBeOpenedWithAnotherDevicesLocalKey()
    {
        var dir = Path.Combine(Path.GetTempPath(), "nearclip-vault-key-test-" + Guid.NewGuid());
        Directory.CreateDirectory(dir);
        try {
            var a = new LocalVault(new FileSecretStore(Path.Combine(dir,"a")));
            var b = new LocalVault(new FileSecretStore(Path.Combine(dir,"b")));
            var path = Path.Combine(dir, "history.json"); a.Write(path, "secret"u8.ToArray());
            Assert.ThrowsAny<CryptographicException>(() => b.Read(path));
        } finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public void CodeExpiresEvenWhenPinnedAndDoesNotResurrectOnRestart()
    {
        using var peer = new TestPeer("Expiry");
        var gid = peer.Node.Snapshot().GroupId;
        peer.Node.Dispose();
        using (var queue = new SerialQueue("test-seed")) {
            using var store = new NodeStore(peer.Dir, "Expiry", queue, new FileSecretStore(Path.Combine(peer.Dir,"secrets")));
            var clip = new Clip(Ids.New(), Clock.NowMs() - 180_001, peer.Id, "text", Text:"482915", Otp:true);
            store.Add(new StoredClip(clip,gid,true,Clock.NowMs(),null,null),null);
            store.SaveNow();
        }
        peer.Restart();
        Assert.DoesNotContain(peer.Node.Snapshot().History, c => c.Clip.IsCode);
        peer.Restart();
        Assert.DoesNotContain(peer.Node.Snapshot().History, c => c.Clip.IsCode);
    }

    [Theory]
    [InlineData(-180001, true)] [InlineData(-179999, false)]
    [InlineData(60001, true)] [InlineData(0, false)]
    public void CodeLifetimeHasStrictBoundaries(long delta, bool expired) {
        var now = 1_800_000_000_000L;
        Assert.Equal(expired, new Clip(Ids.New(), now+delta, Ids.New(), "text", Text:"1234",Otp:true).IsExpired(now));
        Assert.False(new Clip(Ids.New(), 0, Ids.New(), "text", Text:"ordinary").IsExpired(now));
    }

    [Theory]
    [InlineData("../escape")]
    [InlineData("not-a-device-id")]
    public void IncomingClipCannotUseAPathAsAnIdentifier(string id) {
        using var doc=System.Text.Json.JsonDocument.Parse(System.Text.Json.JsonSerializer.Serialize(new { id,src=Ids.New(),ts=Clock.NowMs(),kind="text",text="x" }));
        Assert.Null(WireJson.ReadClip(doc.RootElement));
    }

    [Fact]
    public void ExplicitSharingPreservesTheOriginalDevicesHistory() {
        var source=Ids.New();var recipient=Ids.New();
        var clip=new Clip(Ids.New(),Clock.NowMs(),source,"text",Text:"shared URL",Recipients:[recipient]);
        Assert.True(clip.IsAddressedTo(source));Assert.True(clip.IsAddressedTo(recipient));Assert.False(clip.IsAddressedTo(Ids.New()));
    }

    static void Pair(TestPeer a, TestPeer b) {
        _ = a.Port; b.Node.Join(a.Node.CreateTicket().Invite);
        b.Wait<NodeEvent.PeerUp>("paired", e => e.Member.Id == a.Id);
        a.Wait<NodeEvent.PeerUp>("paired", e => e.Member.Id == b.Id);
    }
    static void Until(Func<bool> condition) {
        var end = DateTime.UtcNow.AddSeconds(15);
        while (!condition() && DateTime.UtcNow < end) Thread.Sleep(20);
        Assert.True(condition());
    }
    [Fact]
    public void PolicySurvivesRestartAndPreventsRelayAndHistoryLeak() {
        using var a=new TestPeer("PolicyA"); using var b=new TestPeer("PolicyB"); using var c=new TestPeer("PolicyC");
        Pair(a,b); Pair(a,c);
        a.Node.SetPolicy(b.Id,new SyncPolicy(Send:false));
        var clip=a.Node.SendText("only C should receive this")!;
        c.Wait<NodeEvent.ClipAdded>("allowed recipient",e=>e.Clip.Id==clip.Id);
        Assert.Equal(new[]{c.Id},clip.Clip.Recipients);
        Thread.Sleep(500);
        Assert.DoesNotContain(b.Node.Snapshot().History,x=>x.Id==clip.Id);
        b.Restart(); b.Node.Connect("127.0.0.1",c.Port);
        Thread.Sleep(700);
        Assert.DoesNotContain(b.Node.Snapshot().History,x=>x.Id==clip.Id);
        a.Restart(); Assert.False(a.Node.PolicyFor(b.Id).Send);
        a.Node.SetPolicy(c.Id,new SyncPolicy(Receive:false));
        a.Node.Connect("127.0.0.1",c.Port);
        Until(()=>c.Node.Snapshot().Online.Contains(a.Id));
        var denied=c.Node.SendText("A must not import this")!;
        Thread.Sleep(500);
        Assert.DoesNotContain(a.Node.Snapshot().History,x=>x.Id==denied.Id);
    }
    [Fact]
    public void RemovalRotatesOnlinePeersAndOldOfflineKeyCannotReconnect() {
        using var a=new TestPeer("KeyA"); using var b=new TestPeer("KeyB"); using var c=new TestPeer("KeyC");
        Pair(a,b); Pair(a,c);
        var gid=a.Node.Snapshot().GroupId;
        byte[] Key(TestPeer p)=>new FileSecretStore(Path.Combine(p.Dir,"secrets")).Load("group-key-"+gid)!;
        var old=Key(a); c.Node.Stop(); a.Node.RemoveMember(c.Id);
        Until(()=>!Key(a).SequenceEqual(old) && Key(a).SequenceEqual(Key(b)));
        b.Node.Connect("127.0.0.1",a.Port);
        Until(()=>a.Node.Snapshot().Online.Contains(b.Id));
        c.Restart(); c.Node.Connect("127.0.0.1",a.Port); c.Node.Connect("127.0.0.1",b.Port);
        var clip=a.Node.SendText("after key rotation")!;
        b.Wait<NodeEvent.ClipAdded>("new-key sync",e=>e.Clip.Id==clip.Id);
        Thread.Sleep(500);
        Assert.DoesNotContain(c.Node.Snapshot().History,x=>x.Id==clip.Id);
        Assert.Equal(old, Key(c));
    }
}
