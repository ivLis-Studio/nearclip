package studio.ivlis.nearclip.core.engine

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import studio.ivlis.nearclip.core.crypto.B64u
import studio.ivlis.nearclip.core.crypto.Crypto
import studio.ivlis.nearclip.core.crypto.readU32
import studio.ivlis.nearclip.core.crypto.utf8
import studio.ivlis.nearclip.core.model.Clip
import studio.ivlis.nearclip.core.model.Endpoint
import studio.ivlis.nearclip.core.model.MemberRecord
import studio.ivlis.nearclip.core.model.Tombstone
import studio.ivlis.nearclip.core.proto.Wire
import java.util.Locale

/** Builders for the JSON messages of PROTOCOL §4–§6. */
internal object Msg {
    val PING: JsonObject = buildJsonObject { put("t", "ping") }
    val PONG: JsonObject = buildJsonObject { put("t", "pong") }
    val PAIR_DECLINE: JsonObject = buildJsonObject { put("t", "pair_decline") }

    fun welcome(device: MemberRecord, members: List<MemberRecord>, addrs: List<Endpoint>) = buildJsonObject {
        put("t", "welcome")
        put("device", device.toJson())
        putJsonArray("members") { members.forEach { add(it.toJson()) } }
        putJsonArray("addrs") { addrs.forEach { add(it.toJson()) } }
    }

    fun members(list: List<MemberRecord>) = buildJsonObject {
        put("t", "members")
        putJsonArray("members") { list.forEach { add(it.toJson()) } }
    }

    fun clip(c: Clip, live: Boolean) = buildJsonObject {
        put("t", "clip")
        put("live", live)
        put("clip", c.wireJson())
    }

    fun inv(clips: List<Tombstone>, dels: List<Tombstone>) = buildJsonObject {
        put("t", "inv")
        putJsonArray("clips") { clips.forEach { add(it.toJson()) } }
        putJsonArray("dels") { dels.forEach { add(it.toJson()) } }
    }

    fun want(ids: List<String>) = buildJsonObject {
        put("t", "want")
        putJsonArray("ids") { ids.forEach { add(kotlinx.serialization.json.JsonPrimitive(it)) } }
    }

    fun del(items: List<Tombstone>) = buildJsonObject {
        put("t", "del")
        putJsonArray("items") { items.forEach { add(it.toJson()) } }
    }

    /** A live image is on its way (PROTOCOL §6.6). */
    fun incoming(id: String) = buildJsonObject {
        put("t", "incoming")
        put("id", id)
        put("kind", "image")
    }

    /** The announced image will not be sent after all. */
    fun incomingCancel(id: String) = buildJsonObject {
        put("t", "incoming")
        put("id", id)
        put("cancel", true)
    }

    fun pairRequest(device: MemberRecord) = buildJsonObject {
        put("t", "pair_request")
        put("device", device.toJson())
    }

    fun pairAccept(groupId: String, key: ByteArray, device: MemberRecord, members: List<MemberRecord>) = buildJsonObject {
        put("t", "pair_accept")
        putJsonObject("group") {
            put("id", groupId)
            put("key", B64u.encode(key))
        }
        put("device", device.toJson())
        putJsonArray("members") { members.forEach { add(it.toJson()) } }
    }

    fun pairNonce(n: ByteArray): ByteArray = ("{\"t\":\"pair_nonce\",\"n\":" + Wire.quote(B64u.encode(n)) + "}").utf8
}

/** The short authentication string of code pairing (PROTOCOL §5.2 step 5). */
object Sas {
    fun compute(transcriptHash: ByteArray): String {
        val h = Crypto.sha256("nearclip-sas".utf8, transcriptHash)
        val word = readU32(h, 0)
        return String.format(Locale.ROOT, "%06d", word % 1_000_000L)
    }

    /** "123456" → "123 456". */
    fun display(sas: String): String = if (sas.length == 6) sas.substring(0, 3) + " " + sas.substring(3) else sas
}

internal class HandshakeError(val code: String) : Exception(code)

internal class PairError(val reason: String) : Exception(reason)
