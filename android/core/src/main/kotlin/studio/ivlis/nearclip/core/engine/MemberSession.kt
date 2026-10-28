package studio.ivlis.nearclip.core.engine

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import studio.ivlis.nearclip.core.crypto.Hex
import studio.ivlis.nearclip.core.crypto.readU32
import studio.ivlis.nearclip.core.model.Clip
import studio.ivlis.nearclip.core.model.Endpoint
import studio.ivlis.nearclip.core.proto.Plain
import studio.ivlis.nearclip.core.proto.SecureChannel
import studio.ivlis.nearclip.core.proto.Wire
import java.io.BufferedOutputStream
import java.io.EOFException
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.ArrayDeque
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** An image transfer being received (PROTOCOL §6.1): chunks are streamed to a temp file and hashed. */
internal class BlobAssembly(val clip: Clip, val live: Boolean, val file: File) {
    private val out = BufferedOutputStream(FileOutputStream(file), 256 * 1024)
    private val digest = MessageDigest.getInstance("SHA-256")
    var next = 0L
        private set
    var received = 0L
        private set
    val size: Long = clip.size ?: 0

    fun append(data: ByteArray, offset: Int, length: Int) {
        out.write(data, offset, length)
        digest.update(data, offset, length)
        received += length
        next++
    }

    /** Closes the file and verifies size and checksum. */
    fun finish(): Boolean {
        out.close()
        return received == size && Hex.encode(digest.digest()) == clip.sha
    }

    fun discard() {
        try { out.close() } catch (_: Exception) {}
        file.delete()
    }
}

/**
 * An established member session (PROTOCOL §4, §6) with one reader and one writer thread.
 * JSON messages are handed to the engine thread synchronously, which keeps ordering intact and lets the
 * engine tell the reader which image transfers to expect. The writer always prefers JSON messages over
 * blob chunks, so pings and small messages interleave with large transfers.
 */
internal class MemberSession(
    private val engine: NearclipEngine,
    val conn: Conn,
    private val channel: SecureChannel,
    val peerId: String,
    val isClient: Boolean,
    /** deviceId of the TCP client of this session (used by the one-session-per-peer rule, §4.4). */
    val clientId: String,
    val groupId: String,
    val dialed: Endpoint?,
    /** Accepted from the tailnet bridge's loopback forwarder (its remote address is meaningless). */
    val viaTailnet: Boolean = false,
    /** The session runs over the tailnet (PROTOCOL §10.3). */
    val remote: Boolean = false,
) {
    private class Out(val plain: ByteArray, val final: Boolean)
    private class BlobJob(val clipId: String, val file: File, val size: Long)

    val sid: Long = counter.incrementAndGet()
    @Volatile var closed = false
        private set
    @Volatile var lastSent: Long = System.currentTimeMillis()
    @Volatile var lastReceived: Long = System.currentTimeMillis()

    // Engine-thread state.
    var welcomed = false
    var supportsPolicies = false
    var supportsRekey = false
    var registered = false
    val requested = HashSet<String>()

    // Reader-thread state.
    private val assemblies = HashMap<String, BlobAssembly>()

    private val lock = ReentrantLock()
    private val wake = lock.newCondition()
    private val control = ArrayDeque<Out>()
    private val blobs = ArrayDeque<BlobJob>()
    private var byeQueued = false
    private var started = false
    private var writerThread: Thread? = null

    val shortPeer: String get() = peerId.take(8)

    fun start() {
        lock.withLock {
            if (started) return
            started = true
        }
        writerThread = Thread({ writeLoop() }, "nearclip-w-${sid}").apply { isDaemon = true; start() }
        Thread({ readLoop() }, "nearclip-r-${sid}").apply { isDaemon = true; start() }
    }

    fun sendJson(obj: JsonObject) = enqueue(Out(Plain.json(obj), final = false))

    fun sendBlob(clipId: String, file: File, size: Long) {
        lock.withLock {
            if (closed || byeQueued) return
            blobs.addLast(BlobJob(clipId, file, size))
            wake.signalAll()
        }
    }

    /** Queues {"t":"bye"} after the JSON messages already queued, then closes. */
    fun bye(reason: String) {
        lock.withLock {
            if (closed || byeQueued) return
            byeQueued = true
            control.addLast(Out(Plain.json(buildJsonObject { put("t", "bye"); put("reason", reason) }), final = true))
            wake.signalAll()
        }
        start()
        engine.scheduleForceClose(this, 3_000)
    }

    fun close() {
        lock.withLock {
            closed = true
            wake.signalAll()
        }
        conn.close()
    }

    fun awaitWriter(ms: Long) {
        try { writerThread?.join(ms) } catch (_: InterruptedException) {}
    }

    private fun enqueue(out: Out) {
        lock.withLock {
            if (closed || byeQueued) return
            control.addLast(out)
            wake.signalAll()
        }
    }

    private fun writePlain(plain: ByteArray) {
        val payload = channel.seal(plain)
        conn.write(payload)
        lastSent = System.currentTimeMillis()
    }

    private inner class Cursor(val job: BlobJob) {
        private val input = FileInputStream(job.file)
        private val buffer = ByteArray(Plain.CHUNK_SIZE)
        private var index = 0
        private var sent = 0L

        /** Writes the next chunk; returns false once the blob is complete. */
        fun writeNext(): Boolean {
            if (sent >= job.size) return false
            val want = minOf(Plain.CHUNK_SIZE.toLong(), job.size - sent).toInt()
            var got = 0
            while (got < want) {
                val n = input.read(buffer, got, want - got)
                if (n < 0) throw EOFException("blob shorter than announced")
                got += n
            }
            writePlain(Plain.chunk(job.clipId, index, buffer, 0, got))
            index++
            sent += got
            return sent < job.size
        }

        fun close() {
            try { input.close() } catch (_: Exception) {}
        }
    }

    private fun writeLoop() {
        var cursor: Cursor? = null
        try {
            while (true) {
                var item: Out? = null
                var job: BlobJob? = null
                lock.withLock {
                    while (!closed && control.isEmpty() && cursor == null && blobs.isEmpty()) wake.await()
                    if (closed) return
                    item = control.pollFirst()
                    if (item == null && cursor == null) job = blobs.pollFirst()
                }
                val out = item
                val nextJob = job
                val cur = cursor
                if (out != null) {
                    writePlain(out.plain)
                    if (out.final) return
                } else if (nextJob != null) {
                    cursor = try { Cursor(nextJob) } catch (e: Exception) { null }
                } else if (cur != null) {
                    val more = try { cur.writeNext() } catch (e: EOFException) { false }
                    if (!more) {
                        cur.close()
                        cursor = null
                    }
                }
            }
        } catch (_: Exception) {
        } finally {
            cursor?.close()
            close()
        }
    }

    private fun readLoop() {
        try {
            while (!closed) {
                val frame = conn.read()
                lastReceived = System.currentTimeMillis()
                val plain = try {
                    channel.open(frame)
                } catch (e: Exception) {
                    engine.log("session ${shortPeer}: frame failed to decrypt, closing")
                    break
                }
                if (plain.isEmpty()) continue
                when (plain[0]) {
                    Plain.TYPE_JSON -> {
                        val obj = try {
                            Wire.parseObject(plain, 1)
                        } catch (e: Exception) {
                            engine.log("session ${shortPeer}: malformed JSON message, closing")
                            break
                        }
                        val expect = engine.onSessionMessage(this, obj) ?: continue
                        when {
                            assemblies.containsKey(expect.clip.id) -> expect.discard() // the first one keeps going
                            assemblies.size >= MAX_PARALLEL_BLOBS -> {
                                expect.discard()
                                engine.onBlobDropped(this, expect.clip.id, "corrupt")
                            }
                            else -> assemblies[expect.clip.id] = expect
                        }
                    }
                    Plain.TYPE_CHUNK -> onChunk(plain)
                    else -> Unit // unknown type bytes MUST be ignored
                }
            }
        } catch (_: Exception) {
        } finally {
            close()
            for (a in assemblies.values) a.discard()
            assemblies.clear()
            engine.onSessionClosed(this)
        }
    }

    private fun onChunk(p: ByteArray) {
        if (p.size <= Plain.CHUNK_HEADER) return
        val clipId = String(p, 1, 36, Charsets.US_ASCII).lowercase()
        val asm = assemblies[clipId] ?: return
        val index = readU32(p, 37)
        val length = p.size - Plain.CHUNK_HEADER
        if (index != asm.next || asm.received + length > asm.size || length > Plain.CHUNK_SIZE) {
            assemblies.remove(clipId)
            asm.discard()
            engine.log("unexpected chunk ${index} for ${clipId.take(8)}; transfer dropped")
            engine.onBlobDropped(this, clipId, "corrupt")
            return
        }
        asm.append(p, Plain.CHUNK_HEADER, length)
        if (asm.live) engine.onBlobProgress(this, clipId, asm.received)
        if (asm.received == asm.size) {
            assemblies.remove(clipId)
            if (asm.finish()) {
                engine.onBlobComplete(this, asm)
            } else {
                engine.log("checksum mismatch for ${clipId.take(8)}; transfer dropped")
                asm.discard()
                engine.onBlobDropped(this, clipId, "corrupt")
            }
        }
    }

    companion object {
        private val counter = AtomicLong()
        private const val MAX_PARALLEL_BLOBS = 16
    }
}
