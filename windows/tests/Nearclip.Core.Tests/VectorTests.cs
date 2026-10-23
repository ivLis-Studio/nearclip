using System.Buffers.Binary;
using System.Text;
using System.Text.Json;
using Xunit;

namespace Nearclip.Core.Tests;

/// <summary>Reproduces every value in spec/test-vectors.json.</summary>
public sealed class VectorTests
{
    static readonly JsonElement V = LoadVectors();

    static JsonElement LoadVectors()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "test-vectors.json");
        using var doc = JsonDocument.Parse(File.ReadAllBytes(path));
        return doc.RootElement.Clone();
    }

    static JsonElement Sec(string name) => V.GetProperty(name);
    static string S(JsonElement e, string key) => e.GetProperty(key).GetString()!;
    static byte[] H(JsonElement e, string key) => Convert.FromHexString(S(e, key));
    static byte[] U(string s) => Encoding.UTF8.GetBytes(s);
    static byte[] Cat(params byte[][] parts) => parts.SelectMany(p => p).ToArray();

    static EphemeralKey ClientKey() => new(H(Sec("ecdh"), "client_private"), H(Sec("ecdh"), "client_public_x963"));
    static EphemeralKey ServerKey() => new(H(Sec("ecdh"), "server_private"), H(Sec("ecdh"), "server_public_x963"));
    static string IdC => S(Sec("ids"), "client");
    static string IdS => S(Sec("ids"), "server");
    static byte[] NC => H(Sec("nonces"), "nc");
    static byte[] NS => H(Sec("nonces"), "ns");

    [Fact]
    public void Hkdf_Rfc5869_Case1()
    {
        var c = Sec("hkdf_rfc5869_case1");
        var okm = NcCrypto.Hkdf(H(c, "ikm"), H(c, "salt"), H(c, "info"), c.GetProperty("length").GetInt32());
        Assert.Equal(S(c, "okm"), Hex.Encode(okm));
    }

    [Fact]
    public void Group_TagAndAuthKey()
    {
        var g = Sec("group");
        var key = H(g, "key");
        Assert.Equal(S(g, "key_b64u"), B64u.Encode(key));
        Assert.Equal(S(g, "group_tag"), NcCrypto.GroupTag(key));
        Assert.Equal(S(g, "auth_key"), Hex.Encode(NcCrypto.AuthKey(key)));
    }

    [Fact]
    public void Ecdh_PublicKeysAndSharedSecret()
    {
        var e = Sec("ecdh");
        using var c = ClientKey();
        using var s = ServerKey();
        Assert.Equal(S(e, "client_public_x963"), Hex.Encode(c.PublicX963));
        Assert.Equal(S(e, "server_public_x963"), Hex.Encode(s.PublicX963));
        Assert.Equal(S(e, "client_public_b64u"), B64u.Encode(c.PublicX963));
        Assert.Equal(S(e, "server_public_b64u"), B64u.Encode(s.PublicX963));
        Assert.Equal(S(e, "shared_z"), Hex.Encode(c.SharedSecret(s.PublicX963)));
        Assert.Equal(S(e, "shared_z"), Hex.Encode(s.SharedSecret(c.PublicX963)));
    }

    [Fact]
    public void Ecdh_RejectsBadPublicKeys()
    {
        using var c = ClientKey();
        var good = H(Sec("ecdh"), "server_public_x963");
        Assert.True(NcCrypto.IsValidPublicKey(good));
        var offCurve = (byte[])good.Clone();
        offCurve[64] ^= 0x01;
        Assert.False(NcCrypto.IsValidPublicKey(offCurve));
        Assert.Throws<NearclipException>(() => c.SharedSecret(offCurve));
        Assert.Throws<NearclipException>(() => c.SharedSecret(good[..64]));
        var compressed = (byte[])good.Clone();
        compressed[0] = 0x03;
        Assert.Throws<NearclipException>(() => c.SharedSecret(compressed));
    }

    [Fact]
    public void MemberSession_HellosTranscriptKeysAndFrames()
    {
        var m = Sec("member_session");
        var gt = S(Sec("group"), "group_tag");
        var authKey = H(Sec("group"), "auth_key");
        using var c = ClientKey();
        using var s = ServerKey();
        // The builders produce the exact vector bytes.
        var helloC = WireJson.HelloMember(IdC, gt, c.PublicX963, NC);
        var helloS = WireJson.HelloMember(IdS, gt, s.PublicX963, NS);
        Assert.Equal(S(m, "hello_c_utf8"), Encoding.UTF8.GetString(helloC));
        Assert.Equal(S(m, "hello_s_utf8"), Encoding.UTF8.GetString(helloS));
        var th = NcCrypto.Sha256(helloC, helloS);
        Assert.Equal(S(m, "th"), Hex.Encode(th));
        var z = c.SharedSecret(s.PublicX963);
        var okm = NcCrypto.Hkdf(z, authKey, Cat(U("nearclip-session"), th), 64);
        Assert.Equal(S(m, "okm"), Hex.Encode(okm));
        Assert.Equal(S(m, "k_c2s"), Hex.Encode(okm[..32]));
        Assert.Equal(S(m, "k_s2c"), Hex.Encode(okm[32..]));

        foreach (var f in m.GetProperty("frames").EnumerateArray())
        {
            var key = S(f, "dir") == "c2s" ? okm[..32] : okm[32..];
            var counter = f.GetProperty("counter").GetUInt64();
            Assert.Equal(S(f, "nonce"), Hex.Encode(NcCrypto.Nonce(counter)));
            var plain = H(f, "plaintext");
            Assert.Equal(S(f, "payload"), Hex.Encode(NcCrypto.Seal(key, counter, plain)));
            Assert.Equal(S(f, "plaintext"), Hex.Encode(NcCrypto.Open(key, counter, H(f, "payload"))));
            // A wrong counter must not decrypt.
            Assert.Throws<NearclipException>(() => NcCrypto.Open(key, counter + 1, H(f, "payload")));
        }
    }

    [Fact]
    public void MemberSession_MessageBuildersMatchFramePlaintexts()
    {
        var frames = Sec("member_session").GetProperty("frames").EnumerateArray().ToList();
        // Frame 0: welcome.
        var device = new MemberRecord(IdC, "Vector Mac", "mac", null, null, 1792800000000, 1792800000000, false);
        var welcome = WireJson.Welcome(device, [], [new Endpoint("192.168.0.12", 45821)]);
        Assert.Equal(S(frames[0], "plaintext"), Hex.Encode(Cat([Wire.TypeJson], welcome)));
        // Frame 1: blob chunk (type byte, clip id, u32 index, data).
        var chunk = H(frames[1], "plaintext");
        Assert.Equal(Wire.TypeChunk, chunk[0]);
        Assert.Equal("0f0e0d0c-0b0a-4908-8706-050403020100", Encoding.ASCII.GetString(chunk, 1, 36));
        Assert.Equal(0u, BinaryPrimitives.ReadUInt32BigEndian(chunk.AsSpan(37, 4)));
        Assert.Equal("PNG-BYTES-FOR-VECTOR", Encoding.UTF8.GetString(chunk, 41, chunk.Length - 41));
        // Frames 2 and 3: ping.
        Assert.Equal(S(frames[2], "plaintext"), Hex.Encode(Cat([Wire.TypeJson], WireJson.Simple("ping"))));
    }

    [Fact]
    public void PairQr_HellosTranscriptKeysAndUri()
    {
        var q = Sec("pair_qr");
        using var c = ClientKey();
        using var s = ServerKey();
        var ticket = H(q, "ticket");
        Assert.Equal(S(q, "ticket_b64u"), B64u.Encode(ticket));
        var helloC = WireJson.HelloPairQr(IdC, c.PublicX963, NC);
        var helloS = WireJson.HelloPairQr(IdS, s.PublicX963, NS);
        Assert.Equal(S(q, "hello_c_utf8"), Encoding.UTF8.GetString(helloC));
        Assert.Equal(S(q, "hello_s_utf8"), Encoding.UTF8.GetString(helloS));
        var th = NcCrypto.Sha256(helloC, helloS);
        Assert.Equal(S(q, "th"), Hex.Encode(th));
        var okm = NcCrypto.Hkdf(c.SharedSecret(s.PublicX963), ticket, Cat(U("nearclip-pair-qr"), th), 64);
        Assert.Equal(S(q, "k_c2s"), Hex.Encode(okm[..32]));
        Assert.Equal(S(q, "k_s2c"), Hex.Encode(okm[32..]));

        var invite = new PairingInvite(IdS, "Vector Mac", "mac", ["192.168.0.12", "10.0.0.5"], 45821, ticket);
        Assert.Equal(S(q, "uri"), invite.ToUri());
        var parsed = PairingInvite.TryParse(S(q, "uri"));
        Assert.NotNull(parsed);
        Assert.Equal(IdS, parsed!.InviterId);
        Assert.Equal("Vector Mac", parsed.Name);
        Assert.Equal("mac", parsed.Platform);
        Assert.Equal(["192.168.0.12", "10.0.0.5"], parsed.Hosts);
        Assert.Equal(45821, parsed.Port);
        Assert.Equal(ticket, parsed.Secret);
    }

    [Fact]
    public void PairUri_RoundTripsUnicodeAndRejectsGarbage()
    {
        var secret = NcCrypto.Random(16);
        var invite = new PairingInvite(Ids.New(), "남준서의 PC & C++ 100%", "win", [], 50123, secret);
        var parsed = PairingInvite.TryParse(invite.ToUri());
        Assert.NotNull(parsed);
        Assert.Equal(invite.Name, parsed!.Name);
        Assert.Empty(parsed.Hosts);
        Assert.Null(PairingInvite.TryParse("https://example.com/pair?v=1"));
        Assert.Null(PairingInvite.TryParse("nearclip://pair?v=2&id=x&p=1&s=" + B64u.Encode(secret)));
        Assert.Null(PairingInvite.TryParse("nearclip://pair?v=1&id=x&p=0&s=" + B64u.Encode(secret)));
        Assert.Null(PairingInvite.TryParse("nearclip://pair?v=1&id=x&p=1&s=AAAA"));
        // Padding is accepted when decoding.
        Assert.NotNull(PairingInvite.TryParse("nearclip://pair?v=1&id=x&p=1&s=" + Convert.ToBase64String(secret).Replace('+', '-').Replace('/', '_')));
    }

    [Fact]
    public void PairCode_CommitTranscriptSasAndKeys()
    {
        var p = Sec("pair_code");
        using var c = ClientKey();
        using var s = ServerKey();
        var commit = NcCrypto.Commitment(s.PublicX963, c.PublicX963, NS);
        Assert.Equal(S(p, "commit"), Hex.Encode(commit));
        Assert.Equal(S(p, "commit_b64u"), B64u.Encode(commit));
        var helloC = WireJson.HelloPairCodeJoiner(IdC, c.PublicX963, "Vector PC", "win");
        var helloS = WireJson.HelloPairCodeInviter(IdS, s.PublicX963, commit, "Vector Mac", "mac");
        Assert.Equal(S(p, "hello_c_utf8"), Encoding.UTF8.GetString(helloC));
        Assert.Equal(S(p, "hello_s_utf8"), Encoding.UTF8.GetString(helloS));
        var th = NcCrypto.Sha256(helloC, helloS, NC, NS);
        Assert.Equal(S(p, "th"), Hex.Encode(th));
        Assert.Equal("231291", NcCrypto.Sas(th));
        Assert.Equal(S(p, "sas"), NcCrypto.Sas(th));
        var okm = NcCrypto.Hkdf(c.SharedSecret(s.PublicX963), U("nearclip-pair-code"), th, 64);
        Assert.Equal(S(p, "k_c2s"), Hex.Encode(okm[..32]));
        Assert.Equal(S(p, "k_s2c"), Hex.Encode(okm[32..]));
    }

    [Fact]
    public void Blob_Sha256()
    {
        var b = Sec("blob");
        Assert.Equal(S(b, "sha256"), Hex.Encode(NcCrypto.Sha256(U(S(b, "data_utf8")))));
    }

    [Fact]
    public void Base64Url_Cases()
    {
        foreach (var c in Sec("b64u").EnumerateArray())
        {
            var bytes = H(c, "bytes");
            var text = S(c, "b64u");
            Assert.Equal(text, B64u.Encode(bytes));
            Assert.Equal(bytes, B64u.Decode(text));
            var padded = text + new string('=', (4 - text.Length % 4) % 4);
            Assert.Equal(bytes, B64u.Decode(padded));
        }
        Assert.Null(B64u.Decode("A"));
        Assert.Null(B64u.Decode("!!!!"));
    }

    [Fact]
    public async Task Framing_RoundTripAndLimits()
    {
        var payload = NcCrypto.Random(1000);
        using var ms = new MemoryStream();
        ms.Write(Framing.Encode(payload));
        ms.Write(Framing.Encode([0x42]));
        ms.Position = 0;
        Assert.Equal(payload, await Framing.ReadAsync(ms, CancellationToken.None));
        Assert.Equal(new byte[] { 0x42 }, await Framing.ReadAsync(ms, CancellationToken.None));
        Assert.Null(await Framing.ReadAsync(ms, CancellationToken.None));
        Assert.Throws<NearclipException>(() => Framing.Encode([]));
        foreach (var bad in new uint[] { 0, Wire.MaxFrame + 1 })
        {
            var header = new byte[4];
            BinaryPrimitives.WriteUInt32BigEndian(header, bad);
            await Assert.ThrowsAsync<NearclipException>(() => Framing.ReadAsync(new MemoryStream(header), CancellationToken.None));
        }
    }

    [Fact]
    public void Json_ReaderIgnoresUnknownFieldsAndNulls()
    {
        using var doc = JsonDocument.Parse("""{"id":"AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE","name":"X","platform":"ios","model":null,"future":{"a":1},"addedAt":1,"updatedAt":2.0,"removed":null}""");
        var m = WireJson.ReadMember(doc.RootElement);
        Assert.NotNull(m);
        Assert.Equal("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", m!.Id);
        Assert.Null(m.Model);
        Assert.Equal(2, m.UpdatedAt);
        Assert.False(m.Removed);
    }
}
