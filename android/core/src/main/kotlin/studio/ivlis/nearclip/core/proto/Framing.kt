package studio.ivlis.nearclip.core.proto

import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream

/** u32 length || payload framing (PROTOCOL §3). */
object Framing {
    const val MAX_FRAME = 17_825_792

    class Reader(input: InputStream) {
        private val data = DataInputStream(input)

        /** Reads one frame; throws [EOFException] at end of stream and [ProtocolException] on a bad length. */
        fun read(): ByteArray {
            val length = data.readInt().toLong() and 0xFFFFFFFFL
            if (length < 1 || length > MAX_FRAME) throw ProtocolException("frame length $length out of range")
            val payload = ByteArray(length.toInt())
            data.readFully(payload)
            return payload
        }
    }

    class Writer(output: OutputStream) {
        private val out = BufferedOutputStream(output, 64 * 1024)

        fun write(payload: ByteArray) {
            require(payload.size in 1..MAX_FRAME) { "frame length" }
            val n = payload.size
            out.write(byteArrayOf((n ushr 24).toByte(), (n ushr 16).toByte(), (n ushr 8).toByte(), n.toByte()))
            out.write(payload)
            out.flush()
        }
    }
}
