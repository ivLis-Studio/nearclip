package studio.ivlis.nearclip.core.store

import studio.ivlis.nearclip.core.crypto.B64u
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/** Protects the group key at rest. The CLI stores it as-is (0600 file); Android wraps it with a Keystore key. */
interface KeyProtector {
    val kind: String
    fun protect(secret: ByteArray): String
    fun unprotect(data: String): ByteArray

    object Plain : KeyProtector {
        override val kind = "plain"
        override fun protect(secret: ByteArray): String = B64u.encode(secret)
        override fun unprotect(data: String): ByteArray = B64u.decode(data)
    }
}

/** Persistence abstraction used by the engine: small JSON documents plus binary side files. */
interface Store {
    val keyProtector: KeyProtector

    /** Returns the document text or null if it does not exist. */
    fun read(name: String): String?

    /** Atomically replaces the document. */
    fun write(name: String, content: String)

    /** A side file (image blobs, large texts) under the store. */
    fun file(name: String): File

    fun delete(name: String)

    /** A fresh temporary file on the same volume as [file] (for atomic moves). */
    fun newTempFile(): File
}

/** Plain-directory implementation: <root>/<name>.json, <root>/blobs/…, <root>/tmp/…. */
class FileStore(
    val root: File,
    override val keyProtector: KeyProtector = KeyProtector.Plain,
) : Store {
    private val blobs = File(root, "blobs")
    private val tmp = File(root, "tmp")

    init {
        if (!blobs.isDirectory && !blobs.mkdirs()) throw IOException("cannot create $blobs")
        if (!tmp.isDirectory && !tmp.mkdirs()) throw IOException("cannot create $tmp")
        tmp.listFiles()?.forEach { it.delete() }
    }

    override fun read(name: String): String? {
        val f = File(root, "$name.json")
        return if (f.isFile) f.readText(Charsets.UTF_8) else null
    }

    override fun write(name: String, content: String) {
        val target = File(root, "$name.json")
        val part = File(root, "$name.json.part")
        part.outputStream().use { out ->
            out.write(content.toByteArray(Charsets.UTF_8))
            out.fd.sync()
        }
        restrict(part)
        try {
            Files.move(part.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
        } catch (e: Exception) {
            Files.move(part.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
    }

    override fun file(name: String): File = File(blobs, name)

    override fun delete(name: String) {
        File(blobs, name).delete()
    }

    override fun newTempFile(): File = File.createTempFile("rx-", ".part", tmp)

    private fun restrict(f: File) {
        f.setReadable(false, false)
        f.setReadable(true, true)
        f.setWritable(false, false)
        f.setWritable(true, true)
    }
}
