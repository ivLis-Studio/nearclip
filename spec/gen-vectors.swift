// Generates spec/test-vectors.json with Apple CryptoKit (the reference for all implementations).
// Run: swift spec/gen-vectors.swift > spec/test-vectors.json
import CryptoKit
import Foundation

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
func unhex(_ s: String) -> Data {
    var d = Data(); var i = s.startIndex
    while i < s.endIndex { let j = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<j], radix: 16)!); i = j }
    return d
}
func utf8(_ s: String) -> Data { Data(s.utf8) }
func b64u(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
func sha256(_ d: Data) -> Data { Data(SHA256.hash(data: d)) }
func hkdf(_ ikm: Data, _ salt: Data, _ info: Data, _ n: Int) -> Data {
    HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: info, outputByteCount: n).withUnsafeBytes { Data($0) }
}
func derive(_ k: Data, _ label: String, _ n: Int) -> Data { hkdf(k, utf8("nearclip-v1"), utf8(label), n) }
func hmac(_ key: Data, _ data: Data) -> Data { Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))) }
func nonce(_ c: UInt64) -> Data { var d = Data(count: 4); var be = c.bigEndian; d.append(Data(bytes: &be, count: 8)); return d }
func seal(_ key: Data, _ counter: UInt64, _ pt: Data) -> Data {
    let box = try! AES.GCM.seal(pt, using: SymmetricKey(data: key), nonce: try! AES.GCM.Nonce(data: nonce(counter)))
    return box.ciphertext + box.tag
}
func u32(_ v: UInt32) -> Data { var be = v.bigEndian; return Data(bytes: &be, count: 4) }

// --- fixed inputs ---
let groupKey = Data((0..<32).map { UInt8($0) })
let groupId = "6f1d2c3b-4a59-4e68-8f7a-0b1c2d3e4f50"
let privC = try! P256.KeyAgreement.PrivateKey(rawRepresentation: sha256(utf8("nearclip-vector-client")))
let privS = try! P256.KeyAgreement.PrivateKey(rawRepresentation: sha256(utf8("nearclip-vector-server")))
let EC = privC.publicKey.x963Representation
let ES = privS.publicKey.x963Representation
let Z = try! privC.sharedSecretFromKeyAgreement(with: privS.publicKey).withUnsafeBytes { Data($0) }
let Z2 = try! privS.sharedSecretFromKeyAgreement(with: privC.publicKey).withUnsafeBytes { Data($0) }
precondition(Z == Z2)
let idC = "11111111-2222-4333-8444-555555555555"
let idS = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
let NC = Data((0..<16).map { UInt8(0xA0 + $0) })
let NS = Data((0..<16).map { UInt8(0xB0 + $0) })

let groupTag = hex(derive(groupKey, "group-tag", 8))
let authKey = derive(groupKey, "auth", 32)

// --- member session ---
let mHelloC = "{\"t\":\"hello\",\"v\":1,\"mode\":\"member\",\"id\":\"\(idC)\",\"gt\":\"\(groupTag)\",\"e\":\"\(b64u(EC))\",\"n\":\"\(b64u(NC))\"}"
let mHelloS = "{\"t\":\"hello\",\"v\":1,\"mode\":\"member\",\"id\":\"\(idS)\",\"gt\":\"\(groupTag)\",\"e\":\"\(b64u(ES))\",\"n\":\"\(b64u(NS))\"}"
let mTH = sha256(utf8(mHelloC) + utf8(mHelloS))
let mOkm = hkdf(Z, authKey, utf8("nearclip-session") + mTH, 64)
let kC2S = mOkm.prefix(32), kS2C = mOkm.suffix(32)

let welcomeJson = "{\"t\":\"welcome\",\"device\":{\"id\":\"\(idC)\",\"name\":\"Vector Mac\",\"platform\":\"mac\",\"addedAt\":1792800000000,\"updatedAt\":1792800000000,\"removed\":false},\"members\":[],\"addrs\":[{\"h\":\"192.168.0.12\",\"p\":45821}]}"
let f0pt = Data([0x01]) + utf8(welcomeJson)
let clipId = "0f0e0d0c-0b0a-4908-8706-050403020100"
let chunkData = utf8("PNG-BYTES-FOR-VECTOR")
let f1pt = Data([0x02]) + utf8(clipId) + u32(0) + chunkData
let pingPt = Data([0x01]) + utf8("{\"t\":\"ping\"}")
let frames: [[String: Any]] = [
    ["dir": "c2s", "counter": 0, "nonce": hex(nonce(0)), "plaintext": hex(f0pt), "payload": hex(seal(Data(kC2S), 0, f0pt))],
    ["dir": "c2s", "counter": 1, "nonce": hex(nonce(1)), "plaintext": hex(f1pt), "payload": hex(seal(Data(kC2S), 1, f1pt))],
    ["dir": "s2c", "counter": 0, "nonce": hex(nonce(0)), "plaintext": hex(pingPt), "payload": hex(seal(Data(kS2C), 0, pingPt))],
    ["dir": "c2s", "counter": 4294967296, "nonce": hex(nonce(4294967296)), "plaintext": hex(pingPt), "payload": hex(seal(Data(kC2S), 4294967296, pingPt))],
]

// --- QR pairing ---
let T = Data((0..<16).map { UInt8(0xC0 + $0) })
let qHelloC = "{\"t\":\"hello\",\"v\":1,\"mode\":\"pair-qr\",\"id\":\"\(idC)\",\"e\":\"\(b64u(EC))\",\"n\":\"\(b64u(NC))\"}"
let qHelloS = "{\"t\":\"hello\",\"v\":1,\"mode\":\"pair-qr\",\"id\":\"\(idS)\",\"e\":\"\(b64u(ES))\",\"n\":\"\(b64u(NS))\"}"
let qTH = sha256(utf8(qHelloC) + utf8(qHelloS))
let qOkm = hkdf(Z, T, utf8("nearclip-pair-qr") + qTH, 64)
let qrUri = "nearclip://pair?v=1&id=\(idS)&nm=Vector%20Mac&pf=mac&h=192.168.0.12,10.0.0.5&p=45821&s=\(b64u(T))"

// --- code pairing ---
let commit = sha256(utf8("nearclip-commit") + ES + EC + NS)
let cHelloC = "{\"t\":\"hello\",\"v\":1,\"mode\":\"pair-code\",\"id\":\"\(idC)\",\"e\":\"\(b64u(EC))\",\"nm\":\"Vector PC\",\"pf\":\"win\"}"
let cHelloS = "{\"t\":\"hello\",\"v\":1,\"mode\":\"pair-code\",\"id\":\"\(idS)\",\"e\":\"\(b64u(ES))\",\"c\":\"\(b64u(commit))\",\"nm\":\"Vector Mac\",\"pf\":\"mac\"}"
let cTH = sha256(utf8(cHelloC) + utf8(cHelloS) + NC + NS)
let sasHash = sha256(utf8("nearclip-sas") + cTH)
let sasBytes = [UInt8](sasHash.prefix(4))
var sasWord: UInt32 = 0
for b in sasBytes { sasWord = (sasWord << 8) | UInt32(b) }
let sasVal: UInt32 = sasWord % 1_000_000
let sas = String(format: "%06u", sasVal)
let cOkm = hkdf(Z, utf8("nearclip-pair-code"), cTH, 64)

// RFC 5869 test case 1 (sanity check of the HKDF implementation itself)
let rfcIkm = Data(repeating: 0x0b, count: 22)
let rfcSalt = Data((0x00...0x0c).map { UInt8($0) })
let rfcInfo = Data((0xf0...0xf9).map { UInt8($0) })
let rfcOkm = hkdf(rfcIkm, rfcSalt, rfcInfo, 42)
precondition(hex(rfcOkm) == "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")

let blob = utf8("Nearclip image blob")
let out: [String: Any] = [
    "about": "Nearclip protocol v1 test vectors, generated by spec/gen-vectors.swift (CryptoKit). All byte strings are lowercase hex unless the key ends in _utf8 or _b64u.",
    "hkdf_rfc5869_case1": ["ikm": hex(rfcIkm), "salt": hex(rfcSalt), "info": hex(rfcInfo), "length": 42, "okm": hex(rfcOkm)],
    "group": ["id": groupId, "key": hex(groupKey), "key_b64u": b64u(groupKey), "group_tag": groupTag, "auth_key": hex(authKey)],
    "ecdh": ["client_private": hex(privC.rawRepresentation), "client_public_x963": hex(EC), "client_public_b64u": b64u(EC),
             "server_private": hex(privS.rawRepresentation), "server_public_x963": hex(ES), "server_public_b64u": b64u(ES),
             "shared_z": hex(Z)],
    "ids": ["client": idC, "server": idS],
    "nonces": ["nc": hex(NC), "nc_b64u": b64u(NC), "ns": hex(NS), "ns_b64u": b64u(NS)],
    "member_session": ["hello_c_utf8": mHelloC, "hello_s_utf8": mHelloS, "th": hex(mTH), "okm": hex(mOkm), "k_c2s": hex(kC2S), "k_s2c": hex(kS2C), "frames": frames],
    "pair_qr": ["ticket": hex(T), "ticket_b64u": b64u(T), "uri": qrUri, "hello_c_utf8": qHelloC, "hello_s_utf8": qHelloS, "th": hex(qTH), "k_c2s": hex(qOkm.prefix(32)), "k_s2c": hex(qOkm.suffix(32))],
    "pair_code": ["hello_c_utf8": cHelloC, "hello_s_utf8": cHelloS, "commit": hex(commit), "commit_b64u": b64u(commit), "th": hex(cTH), "sas": sas, "k_c2s": hex(cOkm.prefix(32)), "k_s2c": hex(cOkm.suffix(32))],
    "blob": ["data_utf8": "Nearclip image blob", "sha256": hex(sha256(blob))],
    "b64u": [["bytes": "fbff", "b64u": "-_8"], ["bytes": "00", "b64u": "AA"], ["bytes": "000102", "b64u": "AAEC"], ["bytes": "", "b64u": ""]],
]
let json = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
print(String(data: json, encoding: .utf8)!)

