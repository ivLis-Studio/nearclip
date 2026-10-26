package studio.ivlis.nearclip.core.model

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import studio.ivlis.nearclip.core.crypto.Crypto
import studio.ivlis.nearclip.core.crypto.Hex
import studio.ivlis.nearclip.core.proto.bool
import studio.ivlis.nearclip.core.proto.int
import studio.ivlis.nearclip.core.proto.long
import studio.ivlis.nearclip.core.proto.normalizeId
import studio.ivlis.nearclip.core.proto.str

object Platform {
    const val MAC = "mac"
    const val WINDOWS = "win"
    const val ANDROID = "android"
    const val IOS = "ios"
    const val CLI = "cli"
}

/** A group: id + secret key, with the derived public tag and session auth key (PROTOCOL §1). */
class Group(val id: String, val key: ByteArray, val createdAt: Long) {
    init { require(key.size == 32) { "group key must be 32 bytes" } }
    val tag: String = Hex.encode(Crypto.derive(key, "group-tag", 8))
    val authKey: ByteArray = Crypto.derive(key, "auth", 32)

    companion object {
        fun create(now: Long): Group = Group(newId(), Crypto.random(32), now)
    }
}

fun newId(): String = java.util.UUID.randomUUID().toString().lowercase()

/** Member record (PROTOCOL §1.1). */
data class MemberRecord(
    val id: String,
    val name: String,
    val platform: String,
    val model: String? = null,
    val app: String? = null,
    val addedAt: Long,
    val updatedAt: Long,
    val removed: Boolean = false,
) {
    fun toJson(): JsonObject = buildJsonObject {
        put("id", id)
        put("name", name)
        put("platform", platform)
        if (model != null) put("model", model)
        if (app != null) put("app", app)
        put("addedAt", addedAt)
        put("updatedAt", updatedAt)
        put("removed", removed)
    }

    companion object {
        fun fromJson(obj: JsonObject?): MemberRecord? {
            if (obj == null) return null
            val id = normalizeId(obj.str("id")) ?: return null
            val updatedAt = obj.long("updatedAt") ?: return null
            return MemberRecord(
                id = id,
                name = (obj.str("name") ?: "").take(64),
                platform = obj.str("platform") ?: "",
                model = obj.str("model"),
                app = obj.str("app"),
                addedAt = obj.long("addedAt") ?: updatedAt,
                updatedAt = updatedAt,
                removed = obj.bool("removed") ?: false,
            )
        }

        /**
         * Last-writer-wins by updatedAt; on a tie prefer the tombstone, otherwise keep the existing record.
         * Returns the record that should be stored, or null when [existing] stays.
         */
        fun merge(existing: MemberRecord?, incoming: MemberRecord): MemberRecord? {
            if (existing == null) return incoming
            val wins = incoming.updatedAt > existing.updatedAt ||
                (incoming.updatedAt == existing.updatedAt && incoming.removed && !existing.removed)
            return if (wins && incoming != existing) incoming else null
        }
    }
}

object ClipKind {
    const val TEXT = "text"
    const val IMAGE = "image"
}

/**
 * A clip as stored locally. The wire fields are those of PROTOCOL §6.1; [groupId], [pinned], [receivedAt],
 * [sourceName], [sourcePlatform] and [localOnly] never leave the device.
 */
data class Clip(
    val id: String,
    val ts: Long,
    val src: String,
    val kind: String,
    val text: String? = null,
    val mime: String? = null,
    val size: Long? = null,
    val sha: String? = null,
    val w: Int? = null,
    val h: Int? = null,
    val groupId: String,
    val pinned: Boolean = false,
    val receivedAt: Long = ts,
    val sourceName: String? = null,
    val sourcePlatform: String? = null,
    /** Set when the clip exceeded the protocol limits: kept in local history but never synced. */
    val localOnly: Boolean = false,
    /** A verification code a phone found in a message (PROTOCOL §6.7): offered, not copied, by the devices receiving it. */
    val otp: Boolean = false,
) {
    val isImage: Boolean get() = kind == ClipKind.IMAGE
    val isText: Boolean get() = kind == ClipKind.TEXT
    val isCode: Boolean get() = otp && isText

    fun wireJson(): JsonObject = buildJsonObject {
        put("id", id)
        put("ts", ts)
        put("src", src)
        put("kind", kind)
        when (kind) {
            ClipKind.TEXT -> {
                put("text", text ?: "")
                if (otp) put("otp", true)
            }
            ClipKind.IMAGE -> {
                put("mime", mime)
                put("size", size)
                put("sha", sha)
                if (w != null) put("w", w)
                if (h != null) put("h", h)
            }
        }
    }

    companion object {
        const val MAX_TEXT_BYTES = 4 * 1024 * 1024
        const val MAX_IMAGE_BYTES = 32L * 1024 * 1024
        const val MAX_CATCHUP_IMAGE_BYTES = 16L * 1024 * 1024

        /** Parses and validates the "clip" object of a clip message. Returns null for invalid or unknown kinds. */
        fun fromWire(obj: JsonObject?, groupId: String, now: Long): Clip? {
            if (obj == null) return null
            val id = normalizeId(obj.str("id")) ?: return null
            val ts = obj.long("ts") ?: return null
            val src = normalizeId(obj.str("src")) ?: return null
            return when (obj.str("kind")) {
                ClipKind.TEXT -> {
                    val text = obj.str("text") ?: return null
                    if (text.toByteArray(Charsets.UTF_8).size > MAX_TEXT_BYTES) return null
                    Clip(id, ts, src, ClipKind.TEXT, text = text, groupId = groupId, receivedAt = now, otp = obj.bool("otp") == true)
                }
                ClipKind.IMAGE -> {
                    val mime = obj.str("mime")?.lowercase() ?: return null
                    if (mime != "image/png" && mime != "image/jpeg") return null
                    val size = obj.long("size") ?: return null
                    if (size < 1 || size > MAX_IMAGE_BYTES) return null
                    val sha = obj.str("sha")?.lowercase() ?: return null
                    if (!Hex.isLowerHex(sha, 64)) return null
                    Clip(
                        id, ts, src, ClipKind.IMAGE, mime = mime, size = size, sha = sha,
                        w = obj.int("w")?.takeIf { it > 0 }, h = obj.int("h")?.takeIf { it > 0 },
                        groupId = groupId, receivedAt = now,
                    )
                }
                else -> null
            }
        }
    }
}

data class Tombstone(val id: String, val ts: Long) {
    fun toJson(): JsonObject = buildJsonObject {
        put("id", id)
        put("ts", ts)
    }

    companion object {
        fun fromJson(obj: JsonObject): Tombstone? {
            val id = normalizeId(obj.str("id")) ?: return null
            return Tombstone(id, obj.long("ts") ?: return null)
        }
    }
}

data class Endpoint(val host: String, val port: Int) {
    init { require(port in 1..65535) { "port out of range" } }

    fun toJson(): JsonObject = buildJsonObject {
        put("h", host)
        put("p", port)
    }

    override fun toString(): String = if (host.contains(':')) "[$host]:$port" else "$host:$port"

    companion object {
        fun fromJson(obj: JsonObject): Endpoint? {
            val h = obj.str("h")?.trim()?.takeIf { it.isNotEmpty() } ?: return null
            val p = obj.int("p") ?: return null
            if (p !in 1..65535) return null
            return Endpoint(h, p)
        }

        /** Parses "host:port" or "[v6]:port". */
        fun parse(text: String, defaultPort: Int? = null): Endpoint? {
            val t = text.trim()
            if (t.isEmpty()) return null
            if (t.startsWith("[")) {
                val close = t.indexOf(']')
                if (close < 0) return null
                val host = t.substring(1, close)
                val rest = t.substring(close + 1)
                val port = if (rest.startsWith(":")) rest.substring(1).toIntOrNull() else defaultPort
                return if (port != null && port in 1..65535) Endpoint(host, port) else null
            }
            val colon = t.lastIndexOf(':')
            if (colon < 0 || t.count { it == ':' } > 1) {
                return if (defaultPort != null) Endpoint(t, defaultPort) else null
            }
            val port = t.substring(colon + 1).toIntOrNull() ?: return null
            val host = t.substring(0, colon)
            return if (host.isNotEmpty() && port in 1..65535) Endpoint(host, port) else null
        }
    }
}
