package studio.ivlis.nearclip.runtime

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.LruCache
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream

object ImageTools {
    const val MAX_IMAGE = 32 * 1024 * 1024
    private const val MAX_READ = 96 * 1024 * 1024

    class Prepared(val bytes: ByteArray, val mime: String, val width: Int, val height: Int)

    /** Reads an image and returns PNG/JPEG bytes (PROTOCOL §7: PNG, or JPEG q90 when the PNG exceeds 32 MiB). */
    fun prepare(context: Context, uri: Uri): Prepared? {
        val bytes = try {
            context.contentResolver.openInputStream(uri)?.use { readLimited(it) }
        } catch (_: Exception) {
            null
        } ?: return null
        return prepare(bytes)
    }

    fun prepare(bytes: ByteArray): Prepared? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        val sniffed = sniff(bytes)
        if (sniffed != null && bytes.size <= MAX_IMAGE) return Prepared(bytes, sniffed, bounds.outWidth, bounds.outHeight)
        val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
        var out = compress(bmp, Bitmap.CompressFormat.PNG, 100)
        var mime = "image/png"
        if (out.size > MAX_IMAGE) {
            out = compress(bmp, Bitmap.CompressFormat.JPEG, 90)
            mime = "image/jpeg"
        }
        return Prepared(out, mime, bmp.width, bmp.height)
    }

    private fun compress(bmp: Bitmap, format: Bitmap.CompressFormat, quality: Int): ByteArray =
        ByteArrayOutputStream().also { bmp.compress(format, quality, it) }.toByteArray()

    private fun readLimited(input: InputStream): ByteArray? {
        val out = ByteArrayOutputStream()
        val buf = ByteArray(256 * 1024)
        while (true) {
            val n = input.read(buf)
            if (n < 0) break
            out.write(buf, 0, n)
            if (out.size() > MAX_READ) return null
        }
        return out.toByteArray()
    }

    fun sniff(b: ByteArray): String? = when {
        b.size >= 8 && b[0] == 0x89.toByte() && b[1] == 'P'.code.toByte() && b[2] == 'N'.code.toByte() && b[3] == 'G'.code.toByte() -> "image/png"
        b.size >= 3 && b[0] == 0xFF.toByte() && b[1] == 0xD8.toByte() && b[2] == 0xFF.toByte() -> "image/jpeg"
        else -> null
    }

    private val cache = object : LruCache<String, Bitmap>(24 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap) = value.byteCount
    }

    /** Pixel size of an image file without decoding it. */
    fun bounds(file: File): Pair<Int, Int>? {
        if (!file.isFile) return null
        val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, o)
        return if (o.outWidth > 0 && o.outHeight > 0) o.outWidth to o.outHeight else null
    }

    /** A downsampled bitmap no larger than [maxPx] on its longer side (cached). */
    fun thumbnail(file: File, maxPx: Int): Bitmap? {
        val key = file.path + "@" + maxPx
        cache.get(key)?.let { return it }
        if (!file.isFile) return null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        if (bounds.outWidth <= 0) return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxPx) sample *= 2
        val bmp = BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null
        cache.put(key, bmp)
        return bmp
    }

    /** Saves an image clip to Pictures/Nearclip. Needs WRITE_EXTERNAL_STORAGE below Android 10. */
    fun saveToGallery(context: Context, file: File, mime: String, displayName: String): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= 29) {
                val values = ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
                    put(MediaStore.Images.Media.MIME_TYPE, mime)
                    put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/Nearclip")
                    put(MediaStore.Images.Media.IS_PENDING, 1)
                }
                val resolver = context.contentResolver
                val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values) ?: return false
                resolver.openOutputStream(uri)?.use { out -> file.inputStream().use { it.copyTo(out) } } ?: return false
                values.clear()
                values.put(MediaStore.Images.Media.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
                true
            } else {
                @Suppress("DEPRECATION")
                val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "Nearclip")
                dir.mkdirs()
                val target = File(dir, displayName)
                file.inputStream().use { input -> FileOutputStream(target).use { input.copyTo(it) } }
                @Suppress("DEPRECATION")
                context.sendBroadcast(android.content.Intent(android.content.Intent.ACTION_MEDIA_SCANNER_SCAN_FILE, Uri.fromFile(target)))
                true
            }
        } catch (_: Exception) {
            false
        }
    }
}
