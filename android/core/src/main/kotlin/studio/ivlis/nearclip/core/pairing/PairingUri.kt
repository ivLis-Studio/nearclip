package studio.ivlis.nearclip.core.pairing

import studio.ivlis.nearclip.core.crypto.B64u
import studio.ivlis.nearclip.core.proto.normalizeId
import java.io.ByteArrayOutputStream

/** nearclip://pair?v=1&id=…&nm=…&pf=…&h=ip1,ip2&p=…&s=… (PROTOCOL §5.1). */
data class PairingUri(
    val inviterId: String,
    val name: String,
    val platform: String,
    val hosts: List<String>,
    val port: Int,
    val ticket: ByteArray,
) {
    fun build(): String = buildString {
        append("nearclip://pair?v=1")
        append("&id=").append(encode(inviterId))
        append("&nm=").append(encode(name))
        append("&pf=").append(encode(platform))
        append("&h=").append(hosts.joinToString(",") { encode(it) })
        append("&p=").append(port)
        append("&s=").append(B64u.encode(ticket))
    }

    override fun equals(other: Any?): Boolean = other is PairingUri && other.inviterId == inviterId &&
        other.name == name && other.platform == platform && other.hosts == hosts && other.port == port &&
        other.ticket.contentEquals(ticket)

    override fun hashCode(): Int = inviterId.hashCode() * 31 + ticket.contentHashCode()

    companion object {
        const val SCHEME = "nearclip"

        /** Parses a pairing link; returns null when it is not a valid v1 link. */
        fun parse(uri: String): PairingUri? {
            val text = uri.trim()
            val prefixEnd = text.indexOf('?')
            if (prefixEnd < 0) return null
            val head = text.substring(0, prefixEnd).lowercase().trimEnd('/')
            if (head != "nearclip://pair") return null
            val params = HashMap<String, String>()
            for (part in text.substring(prefixEnd + 1).substringBefore('#').split('&')) {
                if (part.isEmpty()) continue
                val eq = part.indexOf('=')
                val key = if (eq < 0) part else part.substring(0, eq)
                val raw = if (eq < 0) "" else part.substring(eq + 1)
                if (key == "h") {
                    params[key] = raw
                } else {
                    params[key] = decode(raw) ?: return null
                }
            }
            if (params["v"] != "1") return null
            val id = normalizeId(params["id"]) ?: return null
            val port = params["p"]?.toIntOrNull()?.takeIf { it in 1..65535 } ?: return null
            val ticket = B64u.decodeOrNull(params["s"]) ?: return null
            if (ticket.size != 16) return null
            val hosts = (params["h"] ?: "").split(',').mapNotNull { decode(it)?.trim()?.takeIf { h -> h.isNotEmpty() } }
            return PairingUri(id, params["nm"] ?: "", params["pf"] ?: "", hosts, port, ticket)
        }

        private const val UNRESERVED = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

        /** RFC 3986 percent-encoding of everything outside the unreserved set (space becomes %20). */
        fun encode(value: String): String {
            val out = StringBuilder()
            for (b in value.toByteArray(Charsets.UTF_8)) {
                val c = (b.toInt() and 0xFF).toChar()
                if (b >= 0 && UNRESERVED.indexOf(c) >= 0) out.append(c)
                else out.append('%').append("0123456789ABCDEF"[(b.toInt() shr 4) and 0xF]).append("0123456789ABCDEF"[b.toInt() and 0xF])
            }
            return out.toString()
        }

        /** Percent-decoding ('+' is kept literally, as RFC 3986 query components allow it raw). */
        fun decode(value: String): String? {
            val out = ByteArrayOutputStream()
            var i = 0
            val bytes = value.toByteArray(Charsets.UTF_8)
            while (i < bytes.size) {
                val b = bytes[i]
                if (b == '%'.code.toByte()) {
                    if (i + 2 >= bytes.size) return null
                    val hi = Character.digit(bytes[i + 1].toInt().toChar(), 16)
                    val lo = Character.digit(bytes[i + 2].toInt().toChar(), 16)
                    if (hi < 0 || lo < 0) return null
                    out.write((hi shl 4) or lo)
                    i += 3
                } else {
                    out.write(b.toInt())
                    i++
                }
            }
            return String(out.toByteArray(), Charsets.UTF_8)
        }
    }
}
