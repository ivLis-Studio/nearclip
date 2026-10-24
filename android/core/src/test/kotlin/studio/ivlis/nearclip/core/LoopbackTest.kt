package studio.ivlis.nearclip.core

import studio.ivlis.nearclip.core.crypto.Crypto
import studio.ivlis.nearclip.core.crypto.Hex
import studio.ivlis.nearclip.core.engine.EngineConfig
import studio.ivlis.nearclip.core.engine.EngineEvent
import studio.ivlis.nearclip.core.engine.NearclipEngine
import studio.ivlis.nearclip.core.model.Endpoint
import studio.ivlis.nearclip.core.model.Platform
import studio.ivlis.nearclip.core.pairing.PairingUri
import studio.ivlis.nearclip.core.store.FileStore
import studio.ivlis.nearclip.core.tailnet.PeerRoute
import studio.ivlis.nearclip.core.tailnet.TailnetAddress
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.random.Random
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/** In-process engines talking over 127.0.0.1 (real sockets, real crypto, real file stores). */
class LoopbackTest {
    private val nodes = ArrayList<Node>()

    inner class Node(val name: String, val dir: File = Files.createTempDirectory("nearclip-test-").toFile()) {
        val events = CopyOnWriteArrayList<EngineEvent>()
        @Volatile var cursor = 0
        lateinit var engine: NearclipEngine

        init {
            nodes.add(this)
            start()
        }

        fun start() {
            events.clear()
            cursor = 0
            engine = NearclipEngine(
                FileStore(dir),
                EngineConfig(
                    platform = Platform.CLI, defaultName = name, port = 0, tickMs = 200, dialIntervalMs = 500,
                    localAddresses = { listOf("127.0.0.1") },
                ),
            )
            engine.listener = { events.add(it) }
            engine.start()
            await<EngineEvent.Ready>("ready") { it is EngineEvent.Ready }
        }

        fun restart() {
            engine.shutdown()
            start()
        }

        val id: String get() = engine.deviceId
        val endpoint: Endpoint get() = Endpoint("127.0.0.1", engine.port)

        fun mark() { cursor = events.size }

        fun <T : EngineEvent> await(what: String, timeoutMs: Long = 15_000, pred: (EngineEvent) -> Boolean): T {
            val deadline = System.currentTimeMillis() + timeoutMs
            while (System.currentTimeMillis() < deadline) {
                for (i in cursor until events.size) {
                    val e = events[i]
                    if (pred(e)) {
                        @Suppress("UNCHECKED_CAST")
                        return e as T
                    }
                }
                Thread.sleep(20)
            }
            fail("${name}: no '${what}' within ${timeoutMs} ms; events: ${events.filter { it !is EngineEvent.Log }.takeLast(12)}; log: ${events.filterIsInstance<EngineEvent.Log>().takeLast(8)}")
        }

        fun clip(text: String, live: Boolean? = null): EngineEvent.ClipAdded = await("clip '${text}'") {
            it is EngineEvent.ClipAdded && !it.local && it.clip.text == text && (live == null || it.live == live)
        }
    }

    @AfterTest
    fun tearDown() {
        for (n in nodes) runCatching { n.engine.shutdown() }
        for (n in nodes) n.dir.deleteRecursively()
    }

    private fun pairQr(inviter: Node, joiner: Node) {
        inviter.mark(); joiner.mark()
        val ticket = inviter.engine.createTicket()
        joiner.engine.joinWithUri(PairingUri.parse(ticket.uri)!!)
        joiner.await<EngineEvent.Paired>("paired") { it is EngineEvent.Paired && it.peerId == inviter.id && it.joined }
        inviter.await<EngineEvent.Paired>("paired") { it is EngineEvent.Paired && it.peerId == joiner.id && !it.joined }
        joiner.await<EngineEvent.PeerUp>("peer_up") { it is EngineEvent.PeerUp && it.record.id == inviter.id }
        inviter.await<EngineEvent.PeerUp>("peer_up") { it is EngineEvent.PeerUp && it.record.id == joiner.id }
    }

    private fun pairCode(inviter: Node, joiner: Node, accept: Boolean) {
        inviter.mark(); joiner.mark()
        joiner.engine.pairWithCode(listOf(inviter.endpoint))
        val prompt = inviter.await<EngineEvent.PairPrompt>("pair_prompt") { it is EngineEvent.PairPrompt }
        val sas = joiner.await<EngineEvent.PairSas>("pair_sas") { it is EngineEvent.PairSas }
        assertEquals(prompt.prompt.sas, sas.sas)
        assertEquals(joiner.id, prompt.prompt.peerId)
        assertEquals(joiner.name, prompt.prompt.name)
        assertEquals(6, sas.sas.length)
        inviter.engine.answerPairPrompt(accept)
        if (!accept) {
            val f = joiner.await<EngineEvent.PairFailed>("pair_failed") { it is EngineEvent.PairFailed }
            assertEquals("declined", f.reason)
            return
        }
        joiner.await<EngineEvent.Paired>("paired") { it is EngineEvent.Paired && it.peerId == inviter.id }
        joiner.await<EngineEvent.PeerUp>("peer_up") { it is EngineEvent.PeerUp && it.record.id == inviter.id }
    }

    @Test
    fun qrPairingSyncDeleteCatchUpAndRemoval() {
        val a = Node("Alpha Mac")
        val b = Node("Beta Phone")
        pairQr(a, b)
        assertEquals(a.engine.snapshot().groupId, b.engine.snapshot().groupId)

        b.mark()
        a.engine.sendText("hello 안녕 ✓ 🎉")
        val got = b.clip("hello 안녕 ✓ 🎉", live = true)
        assertTrue(got.apply)
        assertEquals(a.id, got.clip.src)
        a.mark()
        val sent = b.engine.sendText("back at you")
        assertEquals(1, sent.peers)
        a.clip("back at you", live = true)

        val img = Random(7).nextBytes(2_621_440 + 123)
        val sha = Hex.encode(Crypto.sha256(img))
        b.mark()
        a.engine.sendImage(img, "image/png", 640, 480)
        val ie = b.await<EngineEvent.ClipAdded>("image", 30_000) { it is EngineEvent.ClipAdded && !it.local && it.clip.sha == sha }
        assertEquals(img.size.toLong(), ie.clip.size)
        assertEquals(640, ie.clip.w)
        assertContentEquals(img, b.engine.blobFile(ie.clip).readBytes())

        b.mark()
        a.engine.delete(listOf(ie.clip.id))
        b.await<EngineEvent.ClipsDeleted>("deleted") { it is EngineEvent.ClipsDeleted && ie.clip.id in it.ids }
        assertFalse(b.engine.snapshot().history.any { it.id == ie.clip.id })
        assertFalse(b.engine.blobFile(ie.clip).exists())

        b.engine.shutdown()
        a.mark()
        a.engine.sendText("while away")
        val img2 = Random(8).nextBytes(1_500_000)
        a.engine.sendImage(img2, "image/jpeg")
        b.restart()
        b.clip("while away", live = false)
        val ci = b.await<EngineEvent.ClipAdded>("catch-up image", 30_000) {
            it is EngineEvent.ClipAdded && it.clip.isImage && it.clip.sha == Hex.encode(Crypto.sha256(img2))
        }
        assertFalse(ci.live)
        assertFalse(ci.apply)
        a.await<EngineEvent.PeerUp>("peer back") { it is EngineEvent.PeerUp && it.record.id == b.id }
        assertFalse(b.engine.snapshot().history.any { it.id == ie.clip.id })

        b.mark()
        val oldGroup = b.engine.snapshot().groupId
        a.engine.removeMember(b.id)
        val left = b.await<EngineEvent.Left>("left") { it is EngineEvent.Left }
        assertEquals("removed", left.reason)
        assertNotEquals(oldGroup, b.engine.snapshot().groupId)
        assertTrue(b.engine.snapshot().history.isNotEmpty(), "history is kept after leaving")
        assertTrue(a.engine.snapshot().members.first { it.id == b.id }.removed)
    }

    @Test
    fun codePairingDeclineAcceptCatchUpAndRename() {
        val a = Node("Code Host")
        val b = Node("Code Joiner")
        a.engine.sendText("before pairing")
        pairCode(a, b, accept = false)
        pairCode(a, b, accept = true)
        b.clip("before pairing", live = false)
        a.mark()
        b.engine.rename("Joiner renamed")
        a.await<EngineEvent.MembersChanged>("rename gossip") {
            it is EngineEvent.MembersChanged && it.members.any { m -> m.id == b.id && m.name == "Joiner renamed" }
        }
    }

    @Test
    fun meshForwardsClipsAndDeletes() {
        val a = Node("Mesh A")
        val b = Node("Mesh B")
        val c = Node("Mesh C")
        pairQr(a, b)
        a.mark()
        pairCode(b, c, accept = true)
        a.await<EngineEvent.MembersChanged>("A learns C") { it is EngineEvent.MembersChanged && it.members.any { m -> m.id == c.id } }
        c.mark()
        a.engine.sendText("mesh a->c")
        assertEquals(a.id, c.clip("mesh a->c", live = true).clip.src)
        a.mark()
        c.engine.sendText("mesh c->a")
        val back = a.clip("mesh c->a", live = true)
        assertEquals(c.id, back.clip.src)
        assertFalse(a.engine.snapshot().online.contains(c.id), "A and C must not be directly connected")
        a.mark()
        c.engine.delete(listOf(back.clip.id))
        a.await<EngineEvent.ClipsDeleted>("forwarded delete") { it is EngineEvent.ClipsDeleted && back.clip.id in it.ids }
    }

    @Test
    fun duplicateSessionsCollapseToOne() {
        val a = Node("Dup A")
        val b = Node("Dup B")
        pairQr(a, b)
        repeat(3) {
            a.engine.connect(b.endpoint)
            b.engine.connect(a.endpoint)
        }
        Thread.sleep(1_500)
        assertTrue(b.id in a.engine.snapshot().online)
        assertTrue(a.id in b.engine.snapshot().online)
        b.mark()
        a.engine.sendText("exactly once")
        b.clip("exactly once")
        Thread.sleep(500)
        assertEquals(1, b.events.drop(b.cursor).count { it is EngineEvent.ClipAdded && it.clip.text == "exactly once" })
    }

    @Test
    fun ticketsAreSingleUseAndGroupsAreIsolated() {
        val a = Node("Ticket A")
        val b = Node("Ticket B")
        val c = Node("Ticket C")
        val ticket = a.engine.createTicket()
        b.engine.joinWithUri(PairingUri.parse(ticket.uri)!!)
        b.await<EngineEvent.Paired>("paired") { it is EngineEvent.Paired }
        c.mark()
        c.engine.joinWithUri(PairingUri.parse(ticket.uri)!!)
        assertEquals("no_ticket", c.await<EngineEvent.PairFailed>("pair_failed") { it is EngineEvent.PairFailed }.reason)
        c.engine.connect(a.endpoint)
        Thread.sleep(1_000)
        assertFalse(c.id in a.engine.snapshot().online)
        c.mark()
        a.engine.sendText("private")
        Thread.sleep(500)
        assertTrue(c.events.drop(c.cursor).none { it is EngineEvent.ClipAdded })
    }

    /** PROTOCOL §4.5: all addresses are tried at once, so an address that never answers costs nothing. */
    @Test
    fun deadAddressDoesNotDelayPairing() {
        val a = Node("Race A")
        val b = Node("Race B")
        val ticket = PairingUri.parse(a.engine.createTicket().uri)!!
        val started = System.currentTimeMillis()
        b.mark()
        b.engine.joinWithUri(ticket.copy(hosts = listOf("192.0.2.1", "127.0.0.1")))  // TEST-NET-1 never answers
        b.await<EngineEvent.Paired>("paired") { it is EngineEvent.Paired && it.joined }
        assertTrue(System.currentTimeMillis() - started < 3_000, "pairing waited for the dead address")
        val up = b.await<EngineEvent.PeerUp>("peer_up") { it is EngineEvent.PeerUp && it.record.id == a.id }
        assertEquals(PeerRoute.LAN, up.route)
        assertEquals(PeerRoute.LAN, b.engine.snapshot().routes[a.id])
    }

    @Test
    fun tailnetAddresses() {
        assertTrue(TailnetAddress.contains("100.64.0.1"))
        assertTrue(TailnetAddress.contains("100.127.255.254"))
        assertFalse(TailnetAddress.contains("100.63.255.255"))
        assertFalse(TailnetAddress.contains("100.128.0.1"))
        assertFalse(TailnetAddress.contains("192.168.0.2"))
        assertFalse(TailnetAddress.contains("127.0.0.1"))
        assertTrue(TailnetAddress.contains("fd7a:115c:a1e0::1"))
        assertFalse(TailnetAddress.contains("fe80::1"))
    }
}
