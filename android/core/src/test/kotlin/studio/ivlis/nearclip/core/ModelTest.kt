package studio.ivlis.nearclip.core

import studio.ivlis.nearclip.core.model.Endpoint
import studio.ivlis.nearclip.core.model.MemberRecord
import studio.ivlis.nearclip.core.pairing.PairingUri
import studio.ivlis.nearclip.core.proto.Framing
import studio.ivlis.nearclip.core.proto.ProtocolException
import studio.ivlis.nearclip.core.proto.normalizeId
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

class ModelTest {
    private val base = MemberRecord("11111111-2222-4333-8444-555555555555", "Mac", "mac", addedAt = 1, updatedAt = 10)

    @Test
    fun memberLastWriterWins() {
        assertEquals(base, MemberRecord.merge(null, base))
        assertNull(MemberRecord.merge(base, base.copy(name = "Old", updatedAt = 9)))
        assertEquals("New", MemberRecord.merge(base, base.copy(name = "New", updatedAt = 11))?.name)
        assertEquals(true, MemberRecord.merge(base, base.copy(removed = true))?.removed)
        assertNull(MemberRecord.merge(base, base.copy(name = "Same time")))
        assertNull(MemberRecord.merge(base.copy(removed = true), base))
    }

    @Test
    fun idsAreNormalized() {
        assertEquals("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", normalizeId("AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"))
        assertNull(normalizeId("not-a-uuid"))
        assertNull(normalizeId("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeeg"))
    }

    @Test
    fun pairingUriEncodingAndDecoding() {
        val t = ByteArray(16) { it.toByte() }
        val uri = PairingUri("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "준서의 MacBook + Pro", "mac", listOf("192.168.0.12"), 45821, t)
        assertEquals(uri, PairingUri.parse(uri.build()))
        val p = PairingUri.parse("nearclip://pair?v=1&id=AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE&nm=A+B%2BC&pf=win&h=&p=1&s=AAECAwQFBgcICQoLDA0ODw")!!
        assertEquals("A+B+C", p.name)
        assertEquals(emptyList(), p.hosts)
        assertEquals("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", p.inviterId)
        assertNull(PairingUri.parse("nearclip://pair?v=2&id=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee&p=1&s=AAECAwQFBgcICQoLDA0ODw"))
        assertNull(PairingUri.parse("https://example.com/pair?v=1"))
        assertNull(PairingUri.parse("nearclip://pair?v=1&id=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee&p=1&s=AAEC"))
    }

    @Test
    fun endpointParsing() {
        assertEquals(Endpoint("192.168.0.12", 45821), Endpoint.parse("192.168.0.12:45821"))
        assertEquals(Endpoint("fe80::1", 5), Endpoint.parse("[fe80::1]:5"))
        assertEquals(Endpoint("host.local", 45821), Endpoint.parse("host.local", 45821))
        assertNull(Endpoint.parse("host:0"))
        assertNull(Endpoint.parse(""))
    }

    @Test
    fun framingRejectsBadLengths() {
        val out = ByteArrayOutputStream()
        Framing.Writer(out).write(byteArrayOf(1, 2, 3))
        assertContentEquals(byteArrayOf(0, 0, 0, 3, 1, 2, 3), out.toByteArray())
        assertContentEquals(byteArrayOf(1, 2, 3), Framing.Reader(ByteArrayInputStream(out.toByteArray())).read())
        assertFailsWith<ProtocolException> { Framing.Reader(ByteArrayInputStream(byteArrayOf(0, 0, 0, 0))).read() }
        assertFailsWith<ProtocolException> { Framing.Reader(ByteArrayInputStream(byteArrayOf(0x01, 0x10, 0, 1))).read() }
    }
}
