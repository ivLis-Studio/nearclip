package studio.ivlis.nearclip.core.engine

import studio.ivlis.nearclip.core.model.Endpoint
import studio.ivlis.nearclip.core.proto.Framing
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** One way to reach a peer during a dial race (PROTOCOL §4.5, §10.3). */
internal data class DialCandidate(
    /** TCP target: the peer itself, or the tailnet bridge proxy (127.0.0.1:proxyPort). */
    val connectTo: Endpoint,
    /** The peer address this candidate stands for (remembered when it wins). */
    val address: Endpoint,
    /** "NCTN1 <token> <ip>:<port>\n" when dialing through the tailnet bridge. */
    val proxyRequest: String? = null,
    /** Tailnet candidates start after the LAN candidates. */
    val delayMs: Long = 0,
    val remote: Boolean = false,
)

/** A TCP connection with u32-length framing. Reads happen on one thread, writes are serialized. */
internal class Conn(val socket: Socket) {
    private val reader = Framing.Reader(socket.getInputStream())
    private val writer = Framing.Writer(socket.getOutputStream())
    private val writeLock = Any()
    @Volatile var closed = false
        private set

    val remoteHost: String? = socket.inetAddress?.hostAddress?.let(::cleanHost)

    fun read(): ByteArray = reader.read()

    fun write(payload: ByteArray) {
        synchronized(writeLock) {
            if (closed) throw IOException("connection closed")
            writer.write(payload)
        }
    }

    fun setReadTimeout(ms: Int) {
        try { socket.soTimeout = ms } catch (_: Exception) {}
    }

    fun close() {
        if (closed) return
        closed = true
        try { socket.close() } catch (_: Exception) {}
    }

    companion object {
        fun cleanHost(raw: String): String {
            var s = raw
            val pct = s.indexOf('%')
            if (pct >= 0) s = s.substring(0, pct)
            if (s.startsWith("::ffff:")) s = s.substring(7)
            return s
        }

        fun tune(socket: Socket) {
            try {
                socket.tcpNoDelay = true
                socket.keepAlive = true
            } catch (_: Exception) {}
        }

        fun connect(endpoint: Endpoint, timeoutMs: Int): Socket {
            val s = Socket()
            try {
                tune(s)
                s.connect(InetSocketAddress(endpoint.host, endpoint.port), timeoutMs)
                return s
            } catch (e: Exception) {
                try { s.close() } catch (_: Exception) {}
                throw e
            }
        }

        /**
         * Connects to all endpoints in parallel and returns the first that succeeds; the others are closed.
         * Throws [IOException] when none is reachable.
         */
        fun connectFirst(endpoints: List<Endpoint>, timeoutMs: Int, pool: ExecutorService): Pair<Socket, Endpoint> {
            val (s, c) = race(endpoints.map { DialCandidate(it, it) }, timeoutMs, pool)
            return s to c.address
        }

        private const val PROXY_TIMEOUT_MS = 15_000

        /**
         * Starts every candidate (after its delay) in parallel and returns the first connection that opens —
         * for proxied candidates, once the tailnet bridge answered 0. The others are closed.
         * Throws [IOException] when none is reachable.
         */
        fun race(candidates: List<DialCandidate>, timeoutMs: Int, pool: ExecutorService): Pair<Socket, DialCandidate> {
            require(candidates.isNotEmpty())
            val winner = AtomicReference<Pair<Socket, DialCandidate>?>(null)
            val closedOut = java.util.concurrent.atomic.AtomicBoolean(false)
            val done = CountDownLatch(1)
            val remaining = AtomicInteger(candidates.size)
            val lastError = AtomicReference<String?>(null)
            for (c in candidates) {
                pool.execute {
                    try {
                        if (c.delayMs > 0) Thread.sleep(c.delayMs)
                        if (winner.get() != null || closedOut.get()) return@execute
                        val s = connect(c.connectTo, timeoutMs)
                        if (c.proxyRequest != null) {
                            try {
                                s.soTimeout = PROXY_TIMEOUT_MS
                                s.getOutputStream().apply { write(c.proxyRequest.toByteArray(Charsets.US_ASCII)); flush() }
                                val status = s.getInputStream().read()
                                if (status != 0) throw IOException("tailnet dial failed ($status)")
                                s.soTimeout = 0
                            } catch (e: Exception) {
                                try { s.close() } catch (_: Exception) {}
                                throw e
                            }
                        }
                        synchronized(winner) {
                            if (closedOut.get() || winner.get() != null) s.close()
                            else { winner.set(s to c); done.countDown() }
                        }
                    } catch (e: Exception) {
                        lastError.set(e.message ?: e.javaClass.simpleName)
                    } finally {
                        if (remaining.decrementAndGet() == 0) done.countDown()
                    }
                }
            }
            val maxDelay = candidates.maxOf { it.delayMs }
            val proxyWait = if (candidates.any { it.proxyRequest != null }) PROXY_TIMEOUT_MS.toLong() else 0L
            done.await(maxDelay + timeoutMs + proxyWait + 1_000, TimeUnit.MILLISECONDS)
            synchronized(winner) {
                closedOut.set(true)
                return winner.get() ?: throw IOException(lastError.get() ?: "no endpoint reachable")
            }
        }
    }
}
