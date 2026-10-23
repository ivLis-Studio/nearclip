package studio.ivlis.nearclip.core.engine

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import studio.ivlis.nearclip.core.model.Clip
import studio.ivlis.nearclip.core.model.ClipKind
import studio.ivlis.nearclip.core.model.Endpoint
import studio.ivlis.nearclip.core.model.MemberRecord
import studio.ivlis.nearclip.core.proto.Wire
import studio.ivlis.nearclip.core.proto.arr
import studio.ivlis.nearclip.core.proto.bool
import studio.ivlis.nearclip.core.proto.int
import studio.ivlis.nearclip.core.proto.long
import studio.ivlis.nearclip.core.proto.normalizeId
import studio.ivlis.nearclip.core.proto.obj
import studio.ivlis.nearclip.core.proto.objects
import studio.ivlis.nearclip.core.proto.str
import studio.ivlis.nearclip.core.store.Store

/** Everything the engine persists apart from the history (state.json). */
internal class PersistedState(
    var deviceId: String,
    var deviceName: String,
    var groupId: String,
    var groupKey: ByteArray?,
    var joinedAt: Long,
    val members: LinkedHashMap<String, MemberRecord> = LinkedHashMap(),
    val endpoints: HashMap<String, MutableList<Endpoint>> = HashMap(),
    val lastSeen: HashMap<String, Long> = HashMap(),
    val tombstones: HashMap<String, Long> = HashMap(),
    var newestLocalTs: Long = 0,
)

internal object Persistence {
    const val STATE = "state"
    const val HISTORY = "history"
    const val INLINE_TEXT_LIMIT = 256 * 1024

    fun loadState(store: Store): PersistedState? {
        val text = store.read(STATE) ?: return null
        val o = try { Wire.parseObject(text) } catch (_: Exception) { return null }
        val id = normalizeId(o.str("deviceId")) ?: return null
        val key = o.str("groupKey")?.let { k ->
            try { store.keyProtector.unprotect(k).takeIf { it.size == 32 } } catch (_: Exception) { null }
        }
        val st = PersistedState(
            deviceId = id,
            deviceName = o.str("deviceName") ?: "",
            groupId = normalizeId(o.str("groupId")) ?: "",
            groupKey = key,
            joinedAt = o.long("joinedAt") ?: 0,
            newestLocalTs = o.long("newestLocalTs") ?: 0,
        )
        o.arr("members")?.objects()?.forEach { MemberRecord.fromJson(it)?.let { r -> st.members[r.id] = r } }
        o.obj("endpoints")?.forEach { (pid, v) ->
            val list = (v as? JsonArray)?.objects()?.mapNotNull { Endpoint.fromJson(it) }?.toMutableList()
            if (list != null && list.isNotEmpty()) st.endpoints[pid] = list
        }
        o.obj("lastSeen")?.forEach { (pid, _) -> o.obj("lastSeen")?.long(pid)?.let { st.lastSeen[pid] = it } }
        o.obj("tombstones")?.let { t -> t.keys.forEach { cid -> t.long(cid)?.let { st.tombstones[cid] = it } } }
        return st
    }

    fun stateJson(st: PersistedState, store: Store): String = buildJsonObject {
        put("v", 1)
        put("deviceId", st.deviceId)
        put("deviceName", st.deviceName)
        put("groupId", st.groupId)
        st.groupKey?.let { put("groupKey", store.keyProtector.protect(it)) }
        put("keyProtection", store.keyProtector.kind)
        put("joinedAt", st.joinedAt)
        put("newestLocalTs", st.newestLocalTs)
        putJsonArray("members") { st.members.values.forEach { add(it.toJson()) } }
        putJsonObject("endpoints") {
            st.endpoints.forEach { (pid, list) -> put(pid, JsonArray(list.map { it.toJson() })) }
        }
        putJsonObject("lastSeen") { st.lastSeen.forEach { (pid, ts) -> put(pid, ts) } }
        putJsonObject("tombstones") { st.tombstones.forEach { (cid, ts) -> put(cid, ts) } }
    }.toString()

    fun textFileName(id: String) = "$id.txt"

    fun blobFileName(clip: Clip) = clip.id + if (clip.mime == "image/jpeg") ".jpg" else ".png"

    fun loadHistory(store: Store): List<Clip> {
        val text = store.read(HISTORY) ?: return emptyList()
        val o = try { Wire.parseObject(text) } catch (_: Exception) { return emptyList() }
        val out = ArrayList<Clip>()
        for (c in o.arr("clips")?.objects().orEmpty()) {
            val id = normalizeId(c.str("id")) ?: continue
            val kind = c.str("kind") ?: continue
            var body = c.str("text")
            if (kind == ClipKind.TEXT && c.bool("textFile") == true) {
                body = try { store.file(textFileName(id)).readText(Charsets.UTF_8) } catch (_: Exception) { continue }
            }
            out.add(
                Clip(
                    id = id,
                    ts = c.long("ts") ?: continue,
                    src = normalizeId(c.str("src")) ?: continue,
                    kind = kind,
                    text = body,
                    mime = c.str("mime"),
                    size = c.long("size"),
                    sha = c.str("sha"),
                    w = c.int("w"),
                    h = c.int("h"),
                    groupId = c.str("groupId") ?: "",
                    pinned = c.bool("pinned") ?: false,
                    receivedAt = c.long("receivedAt") ?: 0,
                    sourceName = c.str("srcName"),
                    sourcePlatform = c.str("srcPlatform"),
                    localOnly = c.bool("localOnly") ?: false,
                ),
            )
        }
        out.sortByDescending { it.ts }
        return out
    }

    /** Serializes the history; texts above [INLINE_TEXT_LIMIT] go to side files (written once). */
    fun historyJson(history: List<Clip>, store: Store): String {
        val clips = ArrayList<JsonObject>(history.size)
        for (c in history) {
            val big = c.isText && (c.text?.length ?: 0) > INLINE_TEXT_LIMIT / 4 &&
                (c.text ?: "").toByteArray(Charsets.UTF_8).size > INLINE_TEXT_LIMIT
            if (big) {
                val f = store.file(textFileName(c.id))
                if (!f.exists()) f.writeText(c.text ?: "", Charsets.UTF_8)
            }
            clips.add(
                buildJsonObject {
                    put("id", c.id)
                    put("ts", c.ts)
                    put("src", c.src)
                    put("kind", c.kind)
                    if (c.isText && !big) put("text", c.text)
                    if (big) put("textFile", true)
                    c.mime?.let { put("mime", it) }
                    c.size?.let { put("size", it) }
                    c.sha?.let { put("sha", it) }
                    c.w?.let { put("w", it) }
                    c.h?.let { put("h", it) }
                    put("groupId", c.groupId)
                    if (c.pinned) put("pinned", true)
                    put("receivedAt", c.receivedAt)
                    c.sourceName?.let { put("srcName", it) }
                    c.sourcePlatform?.let { put("srcPlatform", it) }
                    if (c.localOnly) put("localOnly", true)
                },
            )
        }
        return JsonObject(mapOf("v" to kotlinx.serialization.json.JsonPrimitive(1), "clips" to JsonArray(clips))).toString()
    }
}
