package studio.ivlis.nearclip.core.crypto

import java.util.Base64

/** Lowercase hexadecimal (PROTOCOL §0 "hex"). */
object Hex {
    private const val DIGITS = "0123456789abcdef"

    fun encode(bytes: ByteArray): String {
        val out = StringBuilder(bytes.size * 2)
        for (b in bytes) {
            val v = b.toInt() and 0xFF
            out.append(DIGITS[v ushr 4]).append(DIGITS[v and 0x0F])
        }
        return out.toString()
    }

    fun decode(text: String): ByteArray {
        require(text.length % 2 == 0) { "odd hex length" }
        return ByteArray(text.length / 2) { i ->
            val hi = Character.digit(text[2 * i], 16)
            val lo = Character.digit(text[2 * i + 1], 16)
            require(hi >= 0 && lo >= 0) { "invalid hex" }
            ((hi shl 4) or lo).toByte()
        }
    }

    fun isLowerHex(text: String, length: Int): Boolean =
        text.length == length && text.all { it in '0'..'9' || it in 'a'..'f' }
}

/** base64url without padding; decoding accepts input with or without padding (PROTOCOL §0). */
object B64u {
    private val encoder = Base64.getUrlEncoder().withoutPadding()
    private val decoder = Base64.getUrlDecoder()

    fun encode(bytes: ByteArray): String = encoder.encodeToString(bytes)

    fun decode(text: String): ByteArray = decoder.decode(text.trim().trimEnd('='))

    fun decodeOrNull(text: String?): ByteArray? =
        if (text == null) null else try { decode(text) } catch (_: IllegalArgumentException) { null }
}

val String.utf8: ByteArray get() = toByteArray(Charsets.UTF_8)

fun u32(value: Long): ByteArray = byteArrayOf(
    (value ushr 24).toByte(), (value ushr 16).toByte(), (value ushr 8).toByte(), value.toByte(),
)

fun u64(value: Long): ByteArray = ByteArray(8) { i -> (value ushr (56 - 8 * i)).toByte() }

fun readU32(bytes: ByteArray, offset: Int): Long =
    ((bytes[offset].toLong() and 0xFF) shl 24) or
        ((bytes[offset + 1].toLong() and 0xFF) shl 16) or
        ((bytes[offset + 2].toLong() and 0xFF) shl 8) or
        (bytes[offset + 3].toLong() and 0xFF)

fun concat(vararg parts: ByteArray): ByteArray {
    val out = ByteArray(parts.sumOf { it.size })
    var pos = 0
    for (p in parts) {
        System.arraycopy(p, 0, out, pos, p.size)
        pos += p.size
    }
    return out
}
