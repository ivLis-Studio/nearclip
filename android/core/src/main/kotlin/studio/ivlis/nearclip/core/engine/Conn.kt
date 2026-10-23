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
            require(endpoints.isNotEmpty())
            if (endpoints.size == 1) return connect(endpoints[0], timeoutMs) to endpoints[0]
            val winner = AtomicReference<Pair<Socket, Endpoint>?>(null)
            val closedOut = java.util.concurrent.atomic.AtomicBoolean(false)
            val done = CountDownLatch(1)
            val remaining = AtomicInteger(endpoints.size)
            for (ep in endpoints) {
                pool.execute {
                    try {
                        val s = connect(ep, timeoutMs)
                        synchronized(winner) {
                            if (closedOut.get() || winner.get() != null) s.close()
                            else { winner.set(s to ep); done.countDown() }
                        }
                    } catch (_: Exception) {
                    } finally {
                        if (remaining.decrementAndGet() == 0) done.countDown()
                    }
                }
            }
            done.await(timeoutMs.toLong() + 1_000, TimeUnit.MILLISECONDS)
            synchronized(winner) {
                closedOut.set(true)
                return winner.get() ?: throw IOException("no endpoint reachable")
            }
        }
    }
}
