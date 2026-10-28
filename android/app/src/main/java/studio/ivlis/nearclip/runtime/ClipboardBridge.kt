package studio.ivlis.nearclip.runtime

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.os.PersistableBundle
import android.text.Html
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

    fun writeText(text: String, clipId: String, sensitive: Boolean = false): Boolean = set(ClipData.newPlainText(LABEL, text), clipId, sensitive)

    fun clearCode(id: String, text: String, written: Long?) {
        if (written == null || stamp() != written) return
        val clip = try { cm.primaryClip } catch (_: Exception) { null } ?: return
        if (clip.description.extras?.getString(EXTRA_ORIGIN) != id || clip.itemCount != 1 || clip.getItemAt(0).text?.toString() != text) return
        if (android.os.Build.VERSION.SDK_INT >= 28) cm.clearPrimaryClip() else cm.setPrimaryClip(ClipData.newPlainText("", ""))
    }

    fun writeImage(file: File, clipId: String): Boolean {
        if (!file.isFile) return false
        val uri = try { FileProvider.getUriForFile(context, authority, file) } catch (_: Exception) { return false }
        return set(ClipData.newUri(context.contentResolver, LABEL, uri), clipId)
    }

    private fun set(clip: ClipData, clipId: String, sensitive: Boolean = false): Boolean = try {
        clip.description.extras = PersistableBundle().apply { putString(EXTRA_ORIGIN, clipId); if (sensitive) putBoolean(EXTRA_IS_SENSITIVE, true) }
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

        private val NOT_TEXT = setOf(ClipDescription.MIMETYPE_TEXT_URILIST, ClipDescription.MIMETYPE_TEXT_INTENT)
        private val LOCAL_SCHEMES = setOf("content", "file", "android.resource")

        /** Whether a clip holds text, judged from its description (photos, files and intents don't). */
        fun hasText(desc: ClipDescription): Boolean =
            (0 until desc.mimeTypeCount).map { desc.getMimeType(it) }.any { it.startsWith("text/") && it !in NOT_TEXT }

        /**
         * The text of a clip read on someone else's behalf (InstantCapture): content: and file: URIs are never
         * opened — their read grant went to the reader, not to Nearclip.
         */
        fun plainText(clip: ClipData): String? {
            if (clip.itemCount == 0) return null
            val item = clip.getItemAt(0)
            val text: CharSequence? = item.text
                ?: item.htmlText?.let { Html.fromHtml(it, Html.FROM_HTML_MODE_COMPACT) }
                ?: item.uri?.takeIf { it.scheme !in LOCAL_SCHEMES }?.toString()
            return text?.toString()?.takeIf { it.isNotEmpty() }
        }
    }
}
