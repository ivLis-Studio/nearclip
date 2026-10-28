package studio.ivlis.nearclip.core.model

import kotlinx.serialization.json.*

data class SyncPolicy(val send: Boolean = true, val receive: Boolean = true, val images: Boolean = true, val codes: Boolean = true) {
    fun permits(c: Clip, sending: Boolean) = (if (sending) send else receive) && (!c.isImage || images) && (!c.isCode || codes)
    fun json() = buildJsonObject { put("send", send); put("receive", receive); put("images", images); put("codes", codes) }
    companion object {
        fun from(o: JsonObject) = SyncPolicy(o["send"]?.jsonPrimitive?.booleanOrNull ?: true,
            o["receive"]?.jsonPrimitive?.booleanOrNull ?: true, o["images"]?.jsonPrimitive?.booleanOrNull ?: true,
            o["codes"]?.jsonPrimitive?.booleanOrNull ?: true)
    }
}
