package studio.ivlis.nearclip.core.proto

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import studio.ivlis.nearclip.core.crypto.utf8

class ProtocolException(message: String) : Exception(message)

/** JSON helpers. Unknown fields are ignored and null is treated as "omitted" (PROTOCOL §0). */
object Wire {
    val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    fun parseObject(bytes: ByteArray, offset: Int = 0): JsonObject {
        val text = String(bytes, offset, bytes.size - offset, Charsets.UTF_8)
        val element = try { json.parseToJsonElement(text) } catch (e: Exception) { throw ProtocolException("invalid JSON") }
        return element as? JsonObject ?: throw ProtocolException("JSON message is not an object")
    }

    fun parseObject(text: String): JsonObject {
        val element = try { json.parseToJsonElement(text) } catch (e: Exception) { throw ProtocolException("invalid JSON") }
        return element as? JsonObject ?: throw ProtocolException("JSON message is not an object")
    }

    fun encode(obj: JsonObject): ByteArray = obj.toString().utf8

    /** A JSON string literal with proper escaping. */
    fun quote(value: String): String = JsonPrimitive(value).toString()
}

private fun JsonObject.prim(key: String): JsonPrimitive? {
    val e = this[key] ?: return null
    if (e is JsonNull) return null
    return e as? JsonPrimitive
}

fun JsonObject.str(key: String): String? = prim(key)?.takeIf { it.isString }?.content

fun JsonObject.long(key: String): Long? {
    val p = prim(key) ?: return null
    if (p.isString) return null
    return p.longOrNull ?: p.doubleOrNull?.takeIf { !it.isNaN() && !it.isInfinite() }?.toLong()
}

fun JsonObject.int(key: String): Int? = long(key)?.takeIf { it in Int.MIN_VALUE..Int.MAX_VALUE }?.toInt()

fun JsonObject.bool(key: String): Boolean? {
    val p = prim(key) ?: return null
    if (p.isString) return null
    return p.booleanOrNull
}

fun JsonObject.obj(key: String): JsonObject? = this[key] as? JsonObject

fun JsonObject.arr(key: String): JsonArray? = this[key] as? JsonArray

fun JsonArray.objects(): List<JsonObject> = mapNotNull { it as? JsonObject }

fun JsonElement?.asObject(): JsonObject? = this as? JsonObject

/** Lowercase canonical form of an id; returns null for anything that is not a 36-char UUID string. */
fun normalizeId(id: String?): String? {
    if (id == null || id.length != 36) return null
    val lower = id.lowercase()
    for ((i, c) in lower.withIndex()) {
        val dash = i == 8 || i == 13 || i == 18 || i == 23
        if (dash) { if (c != '-') return null } else if (!(c in '0'..'9' || c in 'a'..'f')) return null
    }
    return lower
}
