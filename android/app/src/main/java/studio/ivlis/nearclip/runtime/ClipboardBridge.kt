package studio.ivlis.nearclip.runtime

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.os.PersistableBundle
import androidx.core.content.FileProvider
import java.io.File

/**
 * System clipboard access. Reading needs window focus on Android 10+ (MainActivity or SendActivity);
 * writing works from the background service. Our own writes carry a marker in the ClipDescription extras so
 * they are never sent back out (DESIGN §4.3 loop safety); clips flagged EXTRA_IS_SENSITIVE are never synced.
 */
class ClipboardBridge(private val context: Context) {
    private val cm: ClipboardManager = context.getSystemService(ClipboardManager::class.java)
    private val authority = context.packageName + ".files"

    sealed interface Content {
        val stamp: Long
        val ours: Boolean
        val sensitive: Boolean
    }

    data class Text(val text: String, override val stamp: Long, override val ours: Boolean, override val sensitive: Boolean) : Content

    data class Image(val uri: Uri, val mime: String, override val stamp: Long, override val ours: Boolean, override val sensitive: Boolean) : Content

    /** Timestamp of the current clip without reading its content (no "pasted from clipboard" toast). */
    fun stamp(): Long? = try { cm.primaryClipDescription?.timestamp } catch (_: Exception) { null }

    fun read(): Content? {
        val clip = try { cm.primaryClip } catch (_: Exception) { null } ?: return null
        if (clip.itemCount == 0) return null
        val desc = clip.description
        val extras = desc.extras
        val ours = extras?.getString(EXTRA_ORIGIN) != null
        val sensitive = extras?.getBoolean(EXTRA_IS_SENSITIVE, false) == true
        val item = clip.getItemAt(0)
        val uri = item.uri
        if (uri != null) {
            val type = (0 until desc.mimeTypeCount).map { desc.getMimeType(it) }.firstOrNull { it.startsWith("image/") }
                ?: try { context.contentResolver.getType(uri) } catch (_: Exception) { null }
            if (type != null && type.startsWith("image/")) return Image(uri, type, desc.timestamp, ours, sensitive)
        }
        val text = try { item.coerceToText(context)?.toString() } catch (_: Exception) { null } ?: return null
        if (text.isEmpty()) return null
        return Text(text, desc.timestamp, ours, sensitive)
    }

    fun writeText(text: String, clipId: String): Boolean = set(ClipData.newPlainText(LABEL, text), clipId)

    fun writeImage(file: File, clipId: String): Boolean {
        if (!file.isFile) return false
        val uri = try { FileProvider.getUriForFile(context, authority, file) } catch (_: Exception) { return false }
        return set(ClipData.newUri(context.contentResolver, LABEL, uri), clipId)
    }

    private fun set(clip: ClipData, clipId: String): Boolean = try {
        clip.description.extras = PersistableBundle().apply { putString(EXTRA_ORIGIN, clipId) }
        cm.setPrimaryClip(clip)
        true
    } catch (_: Exception) {
        false
    }

    companion object {
        const val LABEL = "Nearclip"
        const val EXTRA_ORIGIN = "studio.ivlis.nearclip.CLIP_ID"
        /** ClipDescription.EXTRA_IS_SENSITIVE (API 33); password managers also set it on older releases. */
        const val EXTRA_IS_SENSITIVE = "android.content.extra.IS_SENSITIVE"
    }
}
