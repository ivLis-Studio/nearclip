package studio.ivlis.nearclip.core

import studio.ivlis.nearclip.core.crypto.P256
import java.math.BigInteger
import java.security.spec.ECFieldFp

/** Affine P-256 arithmetic, test-only: derives public keys from the private scalars in the vectors. */
object EcMath {
    private val p: BigInteger = (P256.params.curve.field as ECFieldFp).p
    private val a: BigInteger = P256.params.curve.a
    private val g = P256.params.generator

    private data class Pt(val x: BigInteger, val y: BigInteger)

    private fun add(P: Pt?, Q: Pt?): Pt? {
        if (P == null) return Q
        if (Q == null) return P
        if (P.x == Q.x) {
            if (P.y.add(Q.y).mod(p).signum() == 0) return null
            return dbl(P)
        }
        val l = Q.y.subtract(P.y).multiply(Q.x.subtract(P.x).modInverse(p)).mod(p)
        val x3 = l.multiply(l).subtract(P.x).subtract(Q.x).mod(p)
        val y3 = l.multiply(P.x.subtract(x3)).subtract(P.y).mod(p)
        return Pt(x3, y3)
    }

    private fun dbl(P: Pt): Pt? {
        if (P.y.signum() == 0) return null
        val l = P.x.multiply(P.x).multiply(BigInteger.valueOf(3)).add(a)
            .multiply(P.y.shiftLeft(1).modInverse(p)).mod(p)
        val x3 = l.multiply(l).subtract(P.x.shiftLeft(1)).mod(p)
        val y3 = l.multiply(P.x.subtract(x3)).subtract(P.y).mod(p)
        return Pt(x3, y3)
    }

    /** Uncompressed X9.63 encoding of d·G. */
    fun publicFromPrivate(d: ByteArray): ByteArray {
        val k = BigInteger(1, d)
        var r: Pt? = null
        var base: Pt? = Pt(g.affineX, g.affineY)
        for (i in 0 until k.bitLength()) {
            if (k.testBit(i)) r = add(r, base)
            base = base?.let { dbl(it) }
        }
        val q = r ?: error("point at infinity")
        return byteArrayOf(4) + P256.fixed32(q.x) + P256.fixed32(q.y)
    }
}
