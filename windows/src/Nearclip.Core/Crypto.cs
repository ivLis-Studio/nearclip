using System.Buffers.Binary;
using System.Globalization;
using System.Numerics;
using System.Security.Cryptography;

namespace Nearclip.Core;

/// <summary>The primitives of PROTOCOL.md §0, all from System.Security.Cryptography.</summary>
public static class NcCrypto
{
    static readonly byte[] SaltV1 = Utf8.Bytes("nearclip-v1");

    public static byte[] Sha256(params byte[][] parts)
    {
        using var h = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        foreach (var p in parts) h.AppendData(p);
        return h.GetHashAndReset();
    }

    public static byte[] Hmac(byte[] key, byte[] data) => HMACSHA256.HashData(key, data);

    /// <summary>HKDF-SHA256 (RFC 5869).</summary>
    public static byte[] Hkdf(byte[] ikm, byte[] salt, byte[] info, int length) =>
        HKDF.DeriveKey(HashAlgorithmName.SHA256, ikm, length, salt, info);

    /// <summary><c>derive(K, label, n)</c> = HKDF(ikm = K, salt = "nearclip-v1", info = label, L = n).</summary>
    public static byte[] Derive(byte[] key, string label, int length) => Hkdf(key, SaltV1, Utf8.Bytes(label), length);

    public static string GroupTag(byte[] groupKey) => Hex.Encode(Derive(groupKey, "group-tag", 8));

    public static byte[] AuthKey(byte[] groupKey) => Derive(groupKey, "auth", 32);

    public static byte[] Random(int count) => RandomNumberGenerator.GetBytes(count);

    /// <summary>12-byte AES-GCM nonce: four zero bytes followed by the big-endian 64-bit frame counter.</summary>
    public static byte[] Nonce(ulong counter)
    {
        var n = new byte[12];
        BinaryPrimitives.WriteUInt64BigEndian(n.AsSpan(4), counter);
        return n;
    }

    /// <summary>Six-digit pairing code (PROTOCOL.md §5.2), no space.</summary>
    public static string Sas(byte[] transcriptHash)
    {
        var h = Sha256(Utf8.Bytes("nearclip-sas"), transcriptHash);
        var word = BinaryPrimitives.ReadUInt32BigEndian(h);
        return (word % 1_000_000).ToString("D6", CultureInfo.InvariantCulture);
    }

    /// <summary><c>commit = SHA-256("nearclip-commit" || ES || EC || NS)</c>.</summary>
    public static byte[] Commitment(byte[] es, byte[] ec, byte[] ns) => Sha256(Utf8.Bytes("nearclip-commit"), es, ec, ns);

    public static byte[] Seal(byte[] key, ulong counter, byte[] plaintext)
    {
        using var c = new FrameCipher(key) { Counter = counter };
        return c.Seal(plaintext);
    }

    public static byte[] Open(byte[] key, ulong counter, byte[] payload)
    {
        using var c = new FrameCipher(key) { Counter = counter };
        return c.Open(payload);
    }

    // ---- P-256 public key validation (uncompressed X9.63, on the curve) ----

    static readonly BigInteger P = BigInteger.Parse("0ffffffff00000001000000000000000000000000ffffffffffffffffffffffff", NumberStyles.HexNumber);
    static readonly BigInteger B = BigInteger.Parse("05ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b", NumberStyles.HexNumber);

    public static bool IsValidPublicKey(ReadOnlySpan<byte> x963)
    {
        if (x963.Length != 65 || x963[0] != 0x04) return false;
        var x = new BigInteger(x963.Slice(1, 32), isUnsigned: true, isBigEndian: true);
        var y = new BigInteger(x963.Slice(33, 32), isUnsigned: true, isBigEndian: true);
        if (x >= P || y >= P) return false;
        var lhs = BigInteger.ModPow(y, 2, P);
        var rhs = (BigInteger.ModPow(x, 3, P) - 3 * x + B) % P;
        if (rhs.Sign < 0) rhs += P;
        return lhs == rhs;
    }
}

/// <summary>AES-256-GCM with a per-direction 64-bit counter nonce, empty AAD, 16-byte tag (PROTOCOL.md §3).</summary>
public sealed class FrameCipher : IDisposable
{
    readonly AesGcm _aes;
    public ulong Counter { get; set; }

    public FrameCipher(byte[] key)
    {
        if (key.Length != 32) throw new ArgumentException("AES-256 key must be 32 bytes", nameof(key));
        _aes = new AesGcm(key, 16);
    }

    public byte[] Seal(ReadOnlySpan<byte> plaintext)
    {
        var output = new byte[plaintext.Length + 16];
        _aes.Encrypt(NcCrypto.Nonce(Counter), plaintext, output.AsSpan(0, plaintext.Length), output.AsSpan(plaintext.Length));
        Counter++;
        return output;
    }

    public byte[] Open(ReadOnlySpan<byte> payload)
    {
        if (payload.Length < 16) throw NearclipException.Crypto("short frame");
        var plain = new byte[payload.Length - 16];
        try
        {
            _aes.Decrypt(NcCrypto.Nonce(Counter), payload[..^16], payload[^16..], plain);
        }
        catch (CryptographicException)
        {
            throw NearclipException.Crypto("decrypt failed");
        }
        Counter++;
        return plain;
    }

    public void Dispose() => _aes.Dispose();
}

/// <summary>Ephemeral P-256 key pair for one handshake.</summary>
public sealed class EphemeralKey : IDisposable
{
    readonly ECDiffieHellman _ecdh;

    public EphemeralKey() => _ecdh = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);

    /// <summary>Imports a fixed key (test vectors).</summary>
    public EphemeralKey(byte[] privateScalar, byte[] publicX963)
    {
        if (!NcCrypto.IsValidPublicKey(publicX963)) throw NearclipException.Crypto("bad public key");
        _ecdh = ECDiffieHellman.Create(new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256,
            D = privateScalar,
            Q = new ECPoint { X = publicX963[1..33], Y = publicX963[33..65] },
        });
    }

    /// <summary>Uncompressed X9.63 public key (65 bytes).</summary>
    public byte[] PublicX963
    {
        get
        {
            var p = _ecdh.ExportParameters(false);
            var output = new byte[65];
            output[0] = 0x04;
            p.Q.X!.CopyTo(output, 1 + 32 - p.Q.X!.Length);
            p.Q.Y!.CopyTo(output, 33 + 32 - p.Q.Y!.Length);
            return output;
        }
    }

    /// <summary>Raw ECDH shared secret Z (the 32-byte X coordinate). Rejects keys that are not 65 bytes / not on the curve.</summary>
    public byte[] SharedSecret(byte[] peerX963)
    {
        if (!NcCrypto.IsValidPublicKey(peerX963)) throw NearclipException.Crypto("bad public key");
        try
        {
            using var peer = ECDiffieHellman.Create(new ECParameters
            {
                Curve = ECCurve.NamedCurves.nistP256,
                Q = new ECPoint { X = peerX963[1..33], Y = peerX963[33..65] },
            });
            return _ecdh.DeriveRawSecretAgreement(peer.PublicKey);
        }
        catch (CryptographicException e)
        {
            throw NearclipException.Crypto("key agreement failed: " + e.Message);
        }
    }

    public void Dispose() => _ecdh.Dispose();
}
