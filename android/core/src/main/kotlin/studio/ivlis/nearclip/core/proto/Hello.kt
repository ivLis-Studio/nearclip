package studio.ivlis.nearclip.core.proto

import kotlinx.serialization.json.JsonObject
import studio.ivlis.nearclip.core.crypto.B64u
import studio.ivlis.nearclip.core.crypto.utf8

/**
 * Builders for the plaintext hello frames. The field order matches spec/test-vectors.json exactly,
 * although only the exact sent/received bytes matter for the transcript hash.
 */
object Hello {
    private fun q(s: String) = Wire.quote(s)

    fun member(id: String, groupTag: String, e: ByteArray, n: ByteArray): ByteArray =
        ("{\"t\":\"hello\",\"v\":1,\"mode\":\"member\",\"id\":" + q(id) + ",\"gt\":" + q(groupTag) +
            ",\"e\":" + q(B64u.encode(e)) + ",\"n\":" + q(B64u.encode(n)) + "}").utf8

    fun pairQr(id: String, e: ByteArray, n: ByteArray): ByteArray =
        ("{\"t\":\"hello\",\"v\":1,\"mode\":\"pair-qr\",\"id\":" + q(id) +
            ",\"e\":" + q(B64u.encode(e)) + ",\"n\":" + q(B64u.encode(n)) + "}").utf8

    fun pairCodeJoiner(id: String, e: ByteArray, name: String, platform: String): ByteArray =
        ("{\"t\":\"hello\",\"v\":1,\"mode\":\"pair-code\",\"id\":" + q(id) + ",\"e\":" + q(B64u.encode(e)) +
            ",\"nm\":" + q(name) + ",\"pf\":" + q(platform) + "}").utf8

    fun pairCodeInviter(id: String, e: ByteArray, commit: ByteArray, name: String, platform: String): ByteArray =
        ("{\"t\":\"hello\",\"v\":1,\"mode\":\"pair-code\",\"id\":" + q(id) + ",\"e\":" + q(B64u.encode(e)) +
            ",\"c\":" + q(B64u.encode(commit)) + ",\"nm\":" + q(name) + ",\"pf\":" + q(platform) + "}").utf8

    fun error(code: String, msg: String? = null): ByteArray =
        ("{\"t\":\"error\",\"code\":" + q(code) + (if (msg != null) ",\"msg\":" + q(msg) else "") + "}").utf8
}

/** A received plaintext handshake frame together with its exact bytes. */
class HelloFrame(val raw: ByteArray) {
    val obj: JsonObject = Wire.parseObject(raw)
    val t: String? get() = obj.str("t")
    val version: Long? get() = obj.long("v")
    val mode: String? get() = obj.str("mode")
    val id: String? get() = normalizeId(obj.str("id"))
    val groupTag: String? get() = obj.str("gt")?.lowercase()
    val ephemeral: ByteArray? get() = B64u.decodeOrNull(obj.str("e"))
    val nonce: ByteArray? get() = B64u.decodeOrNull(obj.str("n"))
    val commit: ByteArray? get() = B64u.decodeOrNull(obj.str("c"))
    val name: String? get() = obj.str("nm")
    val platform: String? get() = obj.str("pf")
    val code: String? get() = obj.str("code")
}
