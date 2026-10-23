package studio.ivlis.nearclip.core.crypto

import java.math.BigInteger
import java.security.InvalidKeyException
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import java.security.spec.ECFieldFp
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPrivateKeySpec
import java.security.spec.ECPublicKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Primitive building blocks of PROTOCOL §0. Only JCA APIs, so the code runs on the JVM and on Android. */
object Crypto {
    private val rng = SecureRandom()

    fun random(n: Int): ByteArray = ByteArray(n).also { rng.nextBytes(it) }

    fun sha256(vararg parts: ByteArray): ByteArray {
        val md = MessageDigest.getInstance("SHA-256")
        for (p in parts) md.update(p)
        return md.digest()
    }

    fun hmacSha256(key: ByteArray, vararg parts: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        for (p in parts) mac.update(p)
        return mac.doFinal()
    }

    /** HKDF-SHA256 (RFC 5869). */
    fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        require(length in 0..255 * 32) { "HKDF length" }
        val prk = hmacSha256(if (salt.isEmpty()) ByteArray(32) else salt, ikm)
        val out = ByteArray(length)
        var block = ByteArray(0)
        var pos = 0
        var counter = 1
        while (pos < length) {
            block = hmacSha256(prk, block, info, byteArrayOf(counter.toByte()))
            val n = minOf(block.size, length - pos)
            System.arraycopy(block, 0, out, pos, n)
            pos += n
            counter++
        }
        return out
    }

    /** derive(K, label, n) = HKDF(ikm = K, salt = "nearclip-v1", info = label, L = n). */
    fun derive(key: ByteArray, label: String, length: Int): ByteArray =
        hkdf(key, "nearclip-v1".utf8, label.utf8, length)
}

/** ECDH over P-256 with uncompressed X9.63 public keys. */
object P256 {
    class KeyPair(val private: PrivateKey, val publicX963: ByteArray)

    val params: ECParameterSpec by lazy {
        val kpg = KeyPairGenerator.getInstance("EC")
        kpg.initialize(ECGenParameterSpec("secp256r1"))
        (kpg.generateKeyPair().public as ECPublicKey).params
    }

    private val fieldP: BigInteger get() = (params.curve.field as ECFieldFp).p

    fun generate(): KeyPair {
        val kpg = KeyPairGenerator.getInstance("EC")
        kpg.initialize(ECGenParameterSpec("secp256r1"), SecureRandom())
        val kp = kpg.generateKeyPair()
        return KeyPair(kp.private, encode((kp.public as ECPublicKey).w))
    }

    fun encode(point: ECPoint): ByteArray =
        concat(byteArrayOf(0x04), fixed32(point.affineX), fixed32(point.affineY))

    /** Decodes and validates a 65-byte uncompressed point; rejects anything that is not on the curve. */
    fun decode(x963: ByteArray): PublicKey {
        if (x963.size != 65 || x963[0] != 0x04.toByte()) throw InvalidKeyException("public key must be 65-byte uncompressed X9.63")
        val x = BigInteger(1, x963.copyOfRange(1, 33))
        val y = BigInteger(1, x963.copyOfRange(33, 65))
        if (!isOnCurve(x, y)) throw InvalidKeyException("public key is not on P-256")
        return KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(x, y), params))
    }

    fun isOnCurve(x: BigInteger, y: BigInteger): Boolean {
        val p = fieldP
        if (x.signum() < 0 || x >= p || y.signum() < 0 || y >= p) return false
        val lhs = y.multiply(y).mod(p)
        val rhs = x.multiply(x).multiply(x).add(params.curve.a.multiply(x)).add(params.curve.b).mod(p)
        return lhs == rhs
    }

    /** Raw shared secret Z = x coordinate of d * Q (32 bytes). */
    fun ecdh(private: PrivateKey, peerX963: ByteArray): ByteArray {
        val ka = KeyAgreement.getInstance("ECDH")
        ka.init(private)
        ka.doPhase(decode(peerX963), true)
        val z = ka.generateSecret()
        return if (z.size == 32) z else fixed32(BigInteger(1, z))
    }

    fun privateFromScalar(d: ByteArray): PrivateKey =
        KeyFactory.getInstance("EC").generatePrivate(ECPrivateKeySpec(BigInteger(1, d), params))

    fun fixed32(v: BigInteger): ByteArray {
        val b = v.toByteArray()
        return when {
            b.size == 32 -> b
            b.size > 32 -> {
                require(b.size == 33 && b[0] == 0.toByte()) { "coordinate too large" }
                b.copyOfRange(1, 33)
            }
            else -> ByteArray(32 - b.size) + b
        }
    }
}

/** AES-256-GCM, 12-byte nonce, 16-byte tag appended to the ciphertext, empty AAD. */
object AesGcm {
    fun nonce(counter: Long): ByteArray = concat(ByteArray(4), u64(counter))

    fun seal(key: ByteArray, nonce: ByteArray, plaintext: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        return c.doFinal(plaintext)
    }

    fun open(key: ByteArray, nonce: ByteArray, payload: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        return c.doFinal(payload)
    }
}
