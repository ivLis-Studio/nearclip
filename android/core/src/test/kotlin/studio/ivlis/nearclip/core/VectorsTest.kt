package studio.ivlis.nearclip.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import studio.ivlis.nearclip.core.crypto.AesGcm
import studio.ivlis.nearclip.core.crypto.B64u
import studio.ivlis.nearclip.core.crypto.Crypto
import studio.ivlis.nearclip.core.crypto.Hex
import studio.ivlis.nearclip.core.crypto.P256
import studio.ivlis.nearclip.core.crypto.concat
import studio.ivlis.nearclip.core.crypto.utf8
import studio.ivlis.nearclip.core.engine.Sas
import studio.ivlis.nearclip.core.model.Group
import studio.ivlis.nearclip.core.model.MemberRecord
import studio.ivlis.nearclip.core.pairing.PairingUri
import studio.ivlis.nearclip.core.proto.Hello
import studio.ivlis.nearclip.core.proto.HelloFrame
import studio.ivlis.nearclip.core.proto.Plain
import studio.ivlis.nearclip.core.proto.SecureChannel
import studio.ivlis.nearclip.core.proto.Wire
import studio.ivlis.nearclip.core.proto.arr
import studio.ivlis.nearclip.core.proto.int
import studio.ivlis.nearclip.core.proto.long
import studio.ivlis.nearclip.core.proto.obj
import studio.ivlis.nearclip.core.proto.str
import java.io.File
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/** Reproduces every value in spec/test-vectors.json (generated with Apple CryptoKit). */
class VectorsTest {
    private val v: JsonObject = Wire.parseObject(File(System.getProperty("nearclip.vectors") ?: "../../spec/test-vectors.json").readText())

    private fun JsonObject.hex(key: String): ByteArray = Hex.decode(str(key) ?: error("missing ${key}"))
    private fun section(name: String) = v.obj(name) ?: error("missing section ${name}")

    private val ids = section("ids")
    private val idC = ids.str("client")!!
    private val idS = ids.str("server")!!
    private val ecdh = section("ecdh")
    private val ec = ecdh.hex("client_public_x963")
    private val es = ecdh.hex("server_public_x963")
    private val nonces = section("nonces")
    private val nc = nonces.hex("nc")
    private val ns = nonces.hex("ns")
    private val groupKey = section("group").hex("key")
    private val groupTag = section("group").str("group_tag")!!

    @Test
    fun hkdfRfc5869Case1() {
        val c = section("hkdf_rfc5869_case1")
        val okm = Crypto.hkdf(c.hex("ikm"), c.hex("salt"), c.hex("info"), c.int("length")!!)
        assertEquals(c.str("okm"), Hex.encode(okm))
    }

    @Test
    fun groupTagAuthKeyAndKeyEncoding() {
        val g = section("group")
        val group = Group(g.str("id")!!, groupKey, 0)
        assertEquals(g.str("group_tag"), group.tag)
        assertEquals(g.str("auth_key"), Hex.encode(group.authKey))
        assertEquals(g.str("key_b64u"), B64u.encode(groupKey))
        assertContentEquals(groupKey, B64u.decode(g.str("key_b64u")!!))
    }

    @Test
    fun ecdhKeysAndSharedSecret() {
        val dC = ecdh.hex("client_private")
        val dS = ecdh.hex("server_private")
        assertEquals(ecdh.str("client_public_x963"), Hex.encode(EcMath.publicFromPrivate(dC)))
        assertEquals(ecdh.str("server_public_x963"), Hex.encode(EcMath.publicFromPrivate(dS)))
        assertEquals(ecdh.str("client_public_b64u"), B64u.encode(ec))
        assertEquals(ecdh.str("server_public_b64u"), B64u.encode(es))
        assertContentEquals(ec, B64u.decode(ecdh.str("client_public_b64u")!!))
        val z1 = P256.ecdh(P256.privateFromScalar(dC), es)
        val z2 = P256.ecdh(P256.privateFromScalar(dS), ec)
        assertEquals(ecdh.str("shared_z"), Hex.encode(z1))
        assertEquals(ecdh.str("shared_z"), Hex.encode(z2))
    }

    @Test
    fun rejectsInvalidPublicKeys() {
        assertFailsWith<Exception> { P256.decode(ec.copyOf(64)) }
        val offCurve = ec.copyOf().also { it[64] = (it[64].toInt() xor 1).toByte() }
        assertFailsWith<Exception> { P256.decode(offCurve) }
        val compressed = ec.copyOf().also { it[0] = 2 }
        assertFailsWith<Exception> { P256.decode(compressed) }
    }

    @Test
    fun memberSessionTranscriptAndKeys() {
        val m = section("member_session")
        val helloC = Hello.member(idC, groupTag, ec, nc)
        val helloS = Hello.member(idS, groupTag, es, ns)
        assertEquals(m.str("hello_c_utf8"), String(helloC, Charsets.UTF_8))
        assertEquals(m.str("hello_s_utf8"), String(helloS, Charsets.UTF_8))
        val th = Crypto.sha256(m.str("hello_c_utf8")!!.utf8, m.str("hello_s_utf8")!!.utf8)
        assertEquals(m.str("th"), Hex.encode(th))
        val z = ecdh.hex("shared_z")
        val authKey = Group(section("group").str("id")!!, groupKey, 0).authKey
        val okm = Crypto.hkdf(z, authKey, concat("nearclip-session".utf8, th), 64)
        assertEquals(m.str("okm"), Hex.encode(okm))
        assertEquals(m.str("k_c2s"), Hex.encode(okm.copyOfRange(0, 32)))
        assertEquals(m.str("k_s2c"), Hex.encode(okm.copyOfRange(32, 64)))
        val parsed = HelloFrame(helloS)
        assertEquals("member", parsed.mode)
        assertEquals(idS, parsed.id)
        assertEquals(groupTag, parsed.groupTag)
        assertContentEquals(es, parsed.ephemeral)
        assertContentEquals(ns, parsed.nonce)
    }

    @Test
    fun everyEncryptedFramePayload() {
        val m = section("member_session")
        val kC2S = m.hex("k_c2s")
        val kS2C = m.hex("k_s2c")
        val frames = m["frames"]!!.jsonArray.map { it.jsonObject }
        assertEquals(4, frames.size)
        for (f in frames) {
            val key = if (f.str("dir") == "c2s") kC2S else kS2C
            val counter = f.long("counter")!!
            val nonce = AesGcm.nonce(counter)
            assertEquals(f.str("nonce"), Hex.encode(nonce))
            val pt = f.hex("plaintext")
            val payload = AesGcm.seal(key, nonce, pt)
            assertEquals(f.str("payload"), Hex.encode(payload), "frame ${f.str("dir")} ${counter}")
            assertContentEquals(pt, AesGcm.open(key, nonce, f.hex("payload")))
        }
        // The same frames through the stateful channels (counters start at 0, one per direction).
        val okm = m.hex("okm")
        val client = SecureChannel.fromOkm(okm, isClient = true)
        val server = SecureChannel.fromOkm(okm, isClient = false)
        val f0 = client.seal(frames[0].hex("plaintext"))
        val f1 = client.seal(frames[1].hex("plaintext"))
        assertEquals(frames[0].str("payload"), Hex.encode(f0))
        assertEquals(frames[1].str("payload"), Hex.encode(f1))
        assertContentEquals(frames[0].hex("plaintext"), server.open(f0))
        assertContentEquals(frames[1].hex("plaintext"), server.open(f1))
        val p0 = server.seal(frames[2].hex("plaintext"))
        assertEquals(frames[2].str("payload"), Hex.encode(p0))
        assertContentEquals(frames[2].hex("plaintext"), client.open(p0))
        // A tampered frame must not decrypt.
        val bad = f0.copyOf().also { it[3] = (it[3].toInt() xor 0x40).toByte() }
        assertFailsWith<Exception> { SecureChannel.fromOkm(okm, isClient = false).open(bad) }
    }

    @Test
    fun framePlaintextLayouts() {
        val frames = section("member_session")["frames"]!!.jsonArray.map { it.jsonObject }
        val welcome = frames[0].hex("plaintext")
        assertEquals(Plain.TYPE_JSON, welcome[0])
        val w = Wire.parseObject(welcome, 1)
        assertEquals("welcome", w.str("t"))
        val device = MemberRecord.fromJson(w.obj("device"))
        assertNotNull(device)
        assertEquals(idC, device.id)
        assertEquals("Vector Mac", device.name)
        assertEquals(1792800000000L, device.updatedAt)
        assertEquals(45821, w.arr("addrs")!![0].jsonObject.int("p"))
        val chunk = Plain.chunk("0f0e0d0c-0b0a-4908-8706-050403020100", 0, "PNG-BYTES-FOR-VECTOR".utf8)
        assertEquals(frames[1].str("plaintext"), Hex.encode(chunk))
        assertEquals(frames[2].str("plaintext"), Hex.encode(byteArrayOf(1) + "{\"t\":\"ping\"}".utf8))
    }

    @Test
    fun qrPairing() {
        val q = section("pair_qr")
        val ticket = q.hex("ticket")
        assertEquals(q.str("ticket_b64u"), B64u.encode(ticket))
        val helloC = Hello.pairQr(idC, ec, nc)
        val helloS = Hello.pairQr(idS, es, ns)
        assertEquals(q.str("hello_c_utf8"), String(helloC, Charsets.UTF_8))
        assertEquals(q.str("hello_s_utf8"), String(helloS, Charsets.UTF_8))
        val th = Crypto.sha256(helloC, helloS)
        assertEquals(q.str("th"), Hex.encode(th))
        val okm = Crypto.hkdf(ecdh.hex("shared_z"), ticket, concat("nearclip-pair-qr".utf8, th), 64)
        assertEquals(q.str("k_c2s"), Hex.encode(okm.copyOfRange(0, 32)))
        assertEquals(q.str("k_s2c"), Hex.encode(okm.copyOfRange(32, 64)))
        val uri = PairingUri(idS, "Vector Mac", "mac", listOf("192.168.0.12", "10.0.0.5"), 45821, ticket)
        assertEquals(q.str("uri"), uri.build())
        assertEquals(uri, PairingUri.parse(q.str("uri")!!))
    }

    @Test
    fun codePairing() {
        val c = section("pair_code")
        val commit = Crypto.sha256("nearclip-commit".utf8, es, ec, ns)
        assertEquals(c.str("commit"), Hex.encode(commit))
        assertEquals(c.str("commit_b64u"), B64u.encode(commit))
        val helloC = Hello.pairCodeJoiner(idC, ec, "Vector PC", "win")
        val helloS = Hello.pairCodeInviter(idS, es, commit, "Vector Mac", "mac")
        assertEquals(c.str("hello_c_utf8"), String(helloC, Charsets.UTF_8))
        assertEquals(c.str("hello_s_utf8"), String(helloS, Charsets.UTF_8))
        val th = Crypto.sha256(helloC, helloS, nc, ns)
        assertEquals(c.str("th"), Hex.encode(th))
        assertEquals("231291", c.str("sas"))
        assertEquals(c.str("sas"), Sas.compute(th))
        assertEquals("231 291", Sas.display(Sas.compute(th)))
        val okm = Crypto.hkdf(ecdh.hex("shared_z"), "nearclip-pair-code".utf8, th, 64)
        assertEquals(c.str("k_c2s"), Hex.encode(okm.copyOfRange(0, 32)))
        assertEquals(c.str("k_s2c"), Hex.encode(okm.copyOfRange(32, 64)))
    }

    @Test
    fun base64UrlCases() {
        for (case in v["b64u"]!!.jsonArray.map { it.jsonObject }) {
            val bytes = case.hex("bytes")
            assertEquals(case.str("b64u"), B64u.encode(bytes))
            assertContentEquals(bytes, B64u.decode(case.str("b64u")!!))
        }
        assertContentEquals(Hex.decode("00"), B64u.decode("AA=="))
        assertContentEquals(Hex.decode("fbff"), B64u.decode("-_8="))
    }

    @Test
    fun blobChecksum() {
        val b = section("blob")
        assertEquals(b.str("sha256"), Hex.encode(Crypto.sha256(b.str("data_utf8")!!.utf8)))
    }

    @Test
    fun vectorsAreComplete() {
        assertTrue(v.keys.containsAll(listOf("hkdf_rfc5869_case1", "group", "ecdh", "member_session", "pair_qr", "pair_code", "b64u", "blob")))
    }
}
