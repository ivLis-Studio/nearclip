package studio.ivlis.nearclip.core

import studio.ivlis.nearclip.core.store.FileStore
import studio.ivlis.nearclip.core.model.*
import java.nio.file.Files
import kotlin.test.*

class PrivacyTest {
    @Test fun localFilesAreEncryptedMigratedAndAuthenticated() {
        val dir=Files.createTempDirectory("nearclip-vault-").toFile()
        try {
            val legacy=dir.resolve("history.json"); legacy.writeText("private history 👋")
            val store=FileStore(dir)
            assertEquals("private history 👋",store.read("history"))
            assertTrue(legacy.readBytes().take(4).toByteArray().contentEquals("NCV1".toByteArray()))
            assertFalse(legacy.readText().contains("private history"))
            val bytes=ByteArray(2_000_000) { (it % 127).toByte() }
            store.writeFile("image.bin",bytes)
            assertContentEquals(bytes,store.readFile("image.bin"))
            assertContentEquals(bytes,store.file("image.bin").readBytes())
            assertFalse(dir.resolve("blobs/image.bin").readBytes().contentEquals(bytes))
            assertEquals("private history 👋",FileStore(dir).read("history"))
            dir.resolve("swapped.json").writeBytes(legacy.readBytes())
            assertFails { store.read("swapped") }
            val corrupt=legacy.readBytes();corrupt[corrupt.lastIndex]=(corrupt.last().toInt() xor 1).toByte();legacy.writeBytes(corrupt)
            assertFails { store.read("history") }
            assertContentEquals(corrupt,legacy.readBytes())
        } finally { dir.deleteRecursively() }
    }
    @Test fun providerAccessPreservesTransfersAndRestoresImagesAfterRestart() {
        val dir=Files.createTempDirectory("nearclip-provider-").toFile()
        try {
            val writer=FileStore(dir)
            val pending=writer.newTempFile().apply { writeText("in flight") }
            val name=newId()+".png"; val bytes=ByteArray(1024) { it.toByte() }
            writer.writeFile(name,bytes)
            val provider=FileStore(dir,cleanTemps=false,migrateBlobs=false)
            assertEquals("in flight",pending.readText())
            assertContentEquals(bytes,provider.file(name).readBytes())
            FileStore(dir) // normal process restart clears transient readable views
            assertContentEquals(bytes,provider.file(name).readBytes())
            assertFalse(dir.resolve("blobs/$name").readBytes().contentEquals(bytes))
        } finally { dir.deleteRecursively() }
    }
    @Test fun concurrentReadersUseOneHistoryKey() {
        val dir=Files.createTempDirectory("nearclip-concurrent-vault-").toFile()
        val pool=java.util.concurrent.Executors.newFixedThreadPool(8)
        try {
            val tasks=(0..15).map { n -> pool.submit(java.util.concurrent.Callable {
                FileStore(dir,cleanTemps=false,migrateBlobs=false).also { it.writeFile("$n.bin",byteArrayOf(n.toByte())) }
            }) }
            val stores=tasks.map { it.get() }
            stores.forEach { store -> (0..15).forEach { n -> assertContentEquals(byteArrayOf(n.toByte()),store.readFile("$n.bin")) } }
        } finally { pool.shutdownNow();dir.deleteRecursively() }
    }
    @Test fun policyAndExpirySemantics() {
        val now=1_800_000_000_000L
        val code=Clip(newId(),now,newId(),ClipKind.TEXT,text="1234",groupId="g",otp=true)
        assertFalse(code.isExpired(now+179_999));assertTrue(code.isExpired(now+180_000))
        assertTrue(code.copy(ts=now+60_001).isExpired(now))
        assertFalse(code.copy(otp=false,ts=0).isExpired(now))
        assertFalse(SyncPolicy(codes=false).permits(code,true))
        assertFalse(SyncPolicy(send=false).permits(code,true));assertTrue(SyncPolicy(send=false).permits(code,false))
        val restricted=code.copy(recipients=listOf(newId()))
        assertEquals(restricted.recipients,Clip.fromWire(restricted.wireJson(),"g",now)?.recipients)
    }
}
