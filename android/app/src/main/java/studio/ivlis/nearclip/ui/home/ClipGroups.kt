package studio.ivlis.nearclip.ui.home

import studio.ivlis.nearclip.core.model.Clip
import studio.ivlis.nearclip.core.model.ContentKey

/**
 * History as rows (DESIGN §4.4): the same content copied more than once shows once, as its newest copy, pinned when any
 * copy is; pinning or deleting the row covers every copy.
 */
class ClipGroups private constructor(val clips: List<Clip>, private val ids: Map<String, Set<String>>) {
    /** Every clip id behind a row. */
    fun idsOf(clip: Clip): Set<String> = ids[clip.id] ?: setOf(clip.id)

    companion object {
        /** Content keys by clip id (composition runs on the main thread only). */
        private val keys = object : LinkedHashMap<String, String>(256, 0.75f, true) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, String>?) = size > 4096
        }

        private fun keyOf(c: Clip): String = keys.getOrPut(c.id) { ContentKey.of(c) ?: ("id:" + c.id) }

        /** [history] is newest first. */
        fun of(history: List<Clip>): ClipGroups {
            val index = HashMap<String, Int>()
            val clips = ArrayList<Clip>(history.size)
            val ids = ArrayList<LinkedHashSet<String>>(history.size)
            for (c in history) {
                val key = keyOf(c)
                val i = index[key]
                if (i == null) {
                    index[key] = clips.size
                    clips.add(c)
                    ids.add(linkedSetOf(c.id))
                    continue
                }
                ids[i].add(c.id)
                if (c.pinned && !clips[i].pinned) clips[i] = clips[i].copy(pinned = true)
            }
            return ClipGroups(clips, clips.indices.associate { clips[it].id to ids[it] })
        }
    }
}
