import CryptoKit
import Foundation
import Security

/// Errors surfaced by the engine. `code` is the short machine-readable form used by the CLI and UI.
public enum NearclipError: Error, CustomStringConvertible, Equatable {
    case protocolViolation(String)
    case crypto(String)
    case remote(String)
    case io(String)
    case timeout
    case cancelled

    public var description: String {
        switch self {
        case .protocolViolation(let s): return "protocol: \(s)"
        case .crypto(let s): return "crypto: \(s)"
        case .remote(let s): return s
        case .io(let s): return "io: \(s)"
        case .timeout: return "timeout"
        case .cancelled: return "cancelled"
        }
    }

    public var code: String {
        switch self {
        case .remote(let c): return c
        case .timeout: return "timeout"
        case .cancelled: return "cancelled"
        case .io: return "io"
        case .crypto: return "crypto"
        case .protocolViolation: return "protocol"
        }
    }
}

public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Accepts input with or without padding.
    public static func decode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.hasSuffix("=") { s.removeLast() }
        switch s.count % 4 {
        case 1: return nil
        case 2: s += "=="
        case 3: s += "="
        default: break
        }
        return Data(base64Encoded: s)
    }
}

public enum Hex {
    private static let digits = Array("0123456789abcdef".utf8)

    public static func encode(_ data: Data) -> String {
        var out = [UInt8]()
        out.reserveCapacity(data.count * 2)
        for b in data {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    public static func decode(_ string: String) -> Data? {
        let chars = Array(string.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        func value(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 97...102: return c - 87
            case 65...70: return c - 55
            default: return nil
            }
        }
        var i = 0
        while i < chars.count {
            guard let hi = value(chars[i]), let lo = value(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }
}

public enum NCCrypto {
    public static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    public static func hmac(key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    public static func hkdf(ikm: Data, salt: Data, info: Data, count: Int) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: info, outputByteCount: count)
            .withUnsafeBytes { Data($0) }
    }

    /// `derive(K, label, n)` from PROTOCOL.md §0.
    public static func derive(_ key: Data, _ label: String, _ count: Int) -> Data {
        hkdf(ikm: key, salt: Data("nearclip-v1".utf8), info: Data(label.utf8), count: count)
    }

    public static func groupTag(_ key: Data) -> String { Hex.encode(derive(key, "group-tag", 8)) }
    public static func authKey(_ key: Data) -> Data { derive(key, "auth", 32) }

    public static func random(_ count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return data
    }

    /// 12-byte AES-GCM nonce: four zero bytes followed by the big-endian 64-bit frame counter.
    public static func nonce(_ counter: UInt64) -> Data {
        var d = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { d.append(contentsOf: $0) }
        return d
    }

    /// Six-digit pairing code (PROTOCOL.md §5.2).
    public static func sas(_ transcriptHash: Data) -> String {
        let h = sha256(Data("nearclip-sas".utf8) + transcriptHash)
        var word: UInt32 = 0
        for b in h.prefix(4) { word = (word << 8) | UInt32(b) }
        return String(format: "%06u", word % 1_000_000)
    }

    public static func seal(key: Data, counter: UInt64, _ plaintext: Data) throws -> Data {
        var c = FrameCipher(key: key)
        c.counter = counter
        return try c.seal(plaintext)
    }

    public static func open(key: Data, counter: UInt64, _ payload: Data) throws -> Data {
        var c = FrameCipher(key: key)
        c.counter = counter
        return try c.open(payload)
    }
}

/// Ephemeral P-256 key pair for one handshake.
public struct EphemeralKey {
    public let privateKey: P256.KeyAgreement.PrivateKey

    public init() { privateKey = P256.KeyAgreement.PrivateKey() }
    public init(raw: Data) throws { privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: raw) }

    /// Uncompressed X9.63 public key (65 bytes).
    public var publicX963: Data { privateKey.publicKey.x963Representation }

    /// Raw ECDH shared secret (X coordinate).
    public func sharedSecret(withX963 peer: Data) throws -> Data {
        guard peer.count == 65, peer.first == 0x04 else { throw NearclipError.crypto("bad public key") }
        let pk: P256.KeyAgreement.PublicKey
        do { pk = try P256.KeyAgreement.PublicKey(x963Representation: peer) } catch { throw NearclipError.crypto("public key not on curve") }
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: pk)
        return secret.withUnsafeBytes { Data($0) }
    }
}

/// AES-256-GCM with a per-direction counter nonce.
public struct FrameCipher {
    let key: SymmetricKey
    public var counter: UInt64 = 0

    public init(key: Data) { self.key = SymmetricKey(data: key) }

    public mutating func seal(_ plaintext: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, nonce: try AES.GCM.Nonce(data: NCCrypto.nonce(counter)))
        counter &+= 1
        var out = Data(box.ciphertext)
        out.append(box.tag)
        return out
    }

    public mutating func open(_ payload: Data) throws -> Data {
        guard payload.count >= 16 else { throw NearclipError.crypto("short frame") }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: NCCrypto.nonce(counter)),
                                        ciphertext: payload.prefix(payload.count - 16),
                                        tag: payload.suffix(16))
        let plain: Data
        do { plain = try AES.GCM.open(box, using: key) } catch { throw NearclipError.crypto("decrypt failed") }
        counter &+= 1
        return plain
    }
}

