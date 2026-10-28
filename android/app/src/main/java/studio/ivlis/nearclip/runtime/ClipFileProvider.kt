package studio.ivlis.nearclip.runtime

import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import androidx.core.content.FileProvider
import java.io.FileNotFoundException
import java.util.UUID
import java.io.File
import studio.ivlis.nearclip.core.store.FileStore

/** Restores a readable view of an encrypted image when another app opens a clipboard URI after a restart.
 * Also preserves pre-1.2 clipboard URIs pointing at blobs, which are now encrypted on disk.
 */
class ClipFileProvider : FileProvider() {
    // Reading a clipboard image must not start networking or disturb an in-flight engine transfer.
    private val store by lazy {
        FileStore(File(requireNotNull(context).filesDir, "nearclip"), KeystoreKeyProtector(), cleanTemps = false, migrateBlobs = false)
    }
    private fun readableUri(uri: Uri): Uri {
        val parts = uri.pathSegments
        if (parts.size != 2 || parts[0] !in setOf("blobs", "previews")) return uri
        val name = parts[1]
        if (!name.endsWith(".png") && !name.endsWith(".jpg")) return uri
        val id = name.substringBeforeLast('.')
        if (id.length != 36 || runCatching { UUID.fromString(id) }.isFailure) return uri
        val context = context ?: return uri
        if (!store.hasFile(name)) throw FileNotFoundException("Image no longer in history")
        val file = store.file(name)
        if (!file.isFile) throw FileNotFoundException("Image unavailable")
        return getUriForFile(context, context.packageName + ".files", file)
    }
    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw FileNotFoundException("Clipboard images are read-only")
        return super.openFile(readableUri(uri), mode) ?: throw FileNotFoundException("Image unavailable")
    }
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor =
        super.query(readableUri(uri), projection, selection, selectionArgs, sortOrder)
}
