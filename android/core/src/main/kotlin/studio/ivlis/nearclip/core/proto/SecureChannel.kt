package studio.ivlis.nearclip.core.proto

import kotlinx.serialization.json.JsonObject
import studio.ivlis.nearclip.core.crypto.AesGcm
import studio.ivlis.nearclip.core.crypto.u32
import studio.ivlis.nearclip.core.crypto.utf8
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * The encrypted half of a connection (PROTOCOL §3): one key and one 64-bit counter per direction.
 * [seal] must only be called by the single writer, [open] only by the single reader.
 */
class SecureChannel(sendKey: ByteArray, receiveKey: ByteArray) {
    private val sendSpec = SecretKeySpec(sendKey, "AES")
    private val receiveSpec = SecretKeySpec(receiveKey, "AES")
    private val sealer: Cipher = Cipher.getInstance("AES/GCM/NoPadding")
    private val opener: Cipher = Cipher.getInstance("AES/GCM/NoPadding")
    private var sendCounter = 0L
    private var receiveCounter = 0L

    fun seal(plaintext: ByteArray): ByteArray {
        sealer.init(Cipher.ENCRYPT_MODE, sendSpec, GCMParameterSpec(128, AesGcm.nonce(sendCounter)))
        sendCounter++
        return sealer.doFinal(plaintext)
    }

    fun open(payload: ByteArray): ByteArray {
        opener.init(Cipher.DECRYPT_MODE, receiveSpec, GCMParameterSpec(128, AesGcm.nonce(receiveCounter)))
        receiveCounter++
        return opener.doFinal(payload)
    }

    companion object {
        /** Splits the 64-byte okm into kC2S || kS2C and orients it for the given role. */
        fun fromOkm(okm: ByteArray, isClient: Boolean): SecureChannel {
            val c2s = okm.copyOfRange(0, 32)
            val s2c = okm.copyOfRange(32, 64)
            return if (isClient) SecureChannel(c2s, s2c) else SecureChannel(s2c, c2s)
        }
    }
}

/** Plaintext layouts inside encrypted frames (type byte + body). */
object Plain {
    const val TYPE_JSON: Byte = 0x01
    const val TYPE_CHUNK: Byte = 0x02
    const val CHUNK_SIZE = 1_048_576
    const val CHUNK_HEADER = 1 + 36 + 4

    fun json(obj: JsonObject): ByteArray {
        val body = obj.toString().utf8
        val out = ByteArray(body.size + 1)
        out[0] = TYPE_JSON
        System.arraycopy(body, 0, out, 1, body.size)
        return out
    }

    fun chunk(clipId: String, index: Int, data: ByteArray, offset: Int = 0, length: Int = data.size): ByteArray {
        val id = clipId.toByteArray(Charsets.US_ASCII)
        require(id.size == 36) { "clip id must be 36 ASCII bytes" }
        require(length in 1..CHUNK_SIZE) { "chunk size" }
        val out = ByteArray(CHUNK_HEADER + length)
        out[0] = TYPE_CHUNK
        System.arraycopy(id, 0, out, 1, 36)
        System.arraycopy(u32(index.toLong()), 0, out, 37, 4)
        System.arraycopy(data, offset, out, CHUNK_HEADER, length)
        return out
    }
}
