package studio.ivlis.nearclip.runtime

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import studio.ivlis.nearclip.core.crypto.B64u
import studio.ivlis.nearclip.core.store.KeyProtector
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Wraps the 32-byte group key with a non-exportable AES-256-GCM key from the Android Keystore (PROTOCOL §1).
 * The stored form is "v1:<b64u(iv)>:<b64u(ciphertext||tag)>".
 */
class KeystoreKeyProtector : KeyProtector {
    override val kind = "android-keystore"

    @Synchronized
    private fun key(): SecretKey {
        val ks = KeyStore.getInstance(PROVIDER).apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER)
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return gen.generateKey()
    }

    override fun protect(secret: ByteArray): String {
        val c = Cipher.getInstance(TRANSFORMATION)
        c.init(Cipher.ENCRYPT_MODE, key())
        val ct = c.doFinal(secret)
        return "v1:" + B64u.encode(c.iv) + ":" + B64u.encode(ct)
    }

    override fun unprotect(data: String): ByteArray {
        val parts = data.split(':')
        require(parts.size == 3 && parts[0] == "v1") { "unknown key format" }
        val c = Cipher.getInstance(TRANSFORMATION)
        c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, B64u.decode(parts[1])))
        return c.doFinal(B64u.decode(parts[2]))
    }

    private companion object {
        const val PROVIDER = "AndroidKeyStore"
        const val ALIAS = "studio.ivlis.nearclip.groupkey.v1"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
    }
}
