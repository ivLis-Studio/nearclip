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
    fun readFile(name: String): ByteArray = file(name).readBytes()
    fun writeFile(name: String, data: ByteArray) { file(name).writeBytes(data) }
    fun hasFile(name: String): Boolean = file(name).isFile

    fun delete(name: String)

    /** A fresh temporary file on the same volume as [file] (for atomic moves). */
    fun newTempFile(): File
}

/** Plain-directory implementation: <root>/<name>.json, <root>/blobs/…, <root>/tmp/…. */
class FileStore(
    val root: File,
    override val keyProtector: KeyProtector = KeyProtector.Plain,
    cleanTemps: Boolean = true,
    migrateBlobs: Boolean = true,
) : Store {
    private companion object { val keyLock = Any() }
    private val blobs = File(root, "blobs")
    private val tmp = File(root, "tmp")
    private val keyFile = File(root, "history-key")
    private val magic = "NCV1".toByteArray()
    private val localKey: javax.crypto.spec.SecretKeySpec

    init {
        if (!blobs.isDirectory && !blobs.mkdirs() && !blobs.isDirectory) throw IOException("cannot create $blobs")
        if (!tmp.isDirectory && !tmp.mkdirs() && !tmp.isDirectory) throw IOException("cannot create $tmp")
        if (cleanTemps) tmp.listFiles()?.forEach { it.deleteRecursively() }
        val key = synchronized(keyLock) {
            if (keyFile.isFile) keyProtector.unprotect(keyFile.readText()) else {
                val bytes = studio.ivlis.nearclip.core.crypto.Crypto.random(32)
                val part = File(root, "history-key.part")
                part.writeText(keyProtector.protect(bytes)); restrict(part)
                Files.move(part.toPath(), keyFile.toPath(), StandardCopyOption.REPLACE_EXISTING)
                bytes
            }
        }
        require(key.size == 32) { "invalid local history key" }
        localKey = javax.crypto.spec.SecretKeySpec(key, "AES")
        if (migrateBlobs) blobs.listFiles()?.filter { it.isFile && it.extension in setOf("png", "jpg", "txt", "bin") }?.forEach { readEncrypted(it) }
    }

    override fun read(name: String): String? {
        val f = File(root, "$name.json")
        return if (f.isFile) readEncrypted(f).toString(Charsets.UTF_8) else null
    }

    override fun write(name: String, content: String) {
        writeEncrypted(File(root, "$name.json"), content.toByteArray(Charsets.UTF_8))
    }

    @Synchronized
    private fun readEncrypted(f: File): ByteArray {
        val bytes = f.readBytes()
        if (bytes.size >= 4 && bytes.copyOfRange(0, 4).contentEquals(magic)) {
            require(bytes.size >= 32) { "truncated history file" }
            val c = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
            c.init(javax.crypto.Cipher.DECRYPT_MODE, localKey, javax.crypto.spec.GCMParameterSpec(128, bytes.copyOfRange(4, 16)))
            c.updateAAD(f.name.toByteArray(Charsets.UTF_8))
            return c.doFinal(bytes.copyOfRange(16, bytes.size))
        }
        writeEncrypted(f, bytes)
        return bytes
    }

    @Synchronized
    private fun writeEncrypted(target: File, plain: ByteArray) {
        val c = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        c.init(javax.crypto.Cipher.ENCRYPT_MODE, localKey)
        c.updateAAD(target.name.toByteArray(Charsets.UTF_8))
        val part = File(target.parentFile, target.name + "." + java.util.UUID.randomUUID() + ".part")
        part.outputStream().use { out -> out.write(magic + c.iv + c.doFinal(plain)); out.fd.sync() }
        restrict(part)
        try { Files.move(part.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE) }
        catch (_: java.nio.file.AtomicMoveNotSupportedException) { Files.move(part.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING) }
    }

    override fun readFile(name: String): ByteArray = readEncrypted(File(blobs, name))
    override fun writeFile(name: String, data: ByteArray) {
        writeEncrypted(File(blobs, name), data)
        File(tmp, name).delete()
    }
    override fun hasFile(name: String): Boolean = File(blobs, name).isFile
    @Synchronized
    override fun file(name: String): File {
        val view = File(tmp, name)
        val raw = File(blobs, name)
        if (!view.exists() && raw.isFile) {
            val part = File(tmp, name + "." + java.util.UUID.randomUUID() + ".part")
            part.writeBytes(readEncrypted(raw)); restrict(part)
            Files.move(part.toPath(), view.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
        return view
    }


    override fun delete(name: String) {
        File(blobs, name).delete()
        File(tmp, name).delete()
    }

    override fun newTempFile(): File = File.createTempFile("rx-", ".part", tmp)

    private fun restrict(f: File) {
        f.setReadable(false, false)
        f.setReadable(true, true)
        f.setWritable(false, false)
        f.setWritable(true, true)
    }
}
