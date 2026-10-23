import CryptoKit
import XCTest
@testable import NearclipKit

final class VectorTests: XCTestCase {
    var v: [String: Any] = [:]

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("spec/test-vectors.json")
        v = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func section(_ k: String) -> [String: Any] { v[k] as! [String: Any] }
    func hex(_ s: Any?) -> Data { Hex.decode(s as! String)! }
    func utf8(_ s: Any?) -> Data { Data((s as! String).utf8) }

    func testHKDFRFC5869() {
        let c = section("hkdf_rfc5869_case1")
        XCTAssertEqual(NCCrypto.hkdf(ikm: hex(c["ikm"]), salt: hex(c["salt"]), info: hex(c["info"]), count: 42), hex(c["okm"]))
    }

    func testGroupDerivation() {
        let g = section("group")
        let key = hex(g["key"])
        XCTAssertEqual(NCCrypto.groupTag(key), g["group_tag"] as? String)
        XCTAssertEqual(NCCrypto.authKey(key), hex(g["auth_key"]))
        XCTAssertEqual(Base64URL.encode(key), g["key_b64u"] as? String)
    }

    func testECDH() throws {
        let e = section("ecdh")
        let c = try EphemeralKey(raw: hex(e["client_private"]))
        let s = try EphemeralKey(raw: hex(e["server_private"]))
        XCTAssertEqual(c.publicX963, hex(e["client_public_x963"]))
        XCTAssertEqual(s.publicX963, hex(e["server_public_x963"]))
        XCTAssertEqual(try c.sharedSecret(withX963: s.publicX963), hex(e["shared_z"]))
        XCTAssertEqual(try s.sharedSecret(withX963: c.publicX963), hex(e["shared_z"]))
        XCTAssertThrowsError(try c.sharedSecret(withX963: Data(repeating: 4, count: 65)))
    }

    func testMemberSession() throws {
        let m = section("member_session")
        let z = hex(section("ecdh")["shared_z"])
        let auth = hex(section("group")["auth_key"])
        let th = NCCrypto.sha256(utf8(m["hello_c_utf8"]) + utf8(m["hello_s_utf8"]))
        XCTAssertEqual(th, hex(m["th"]))
        let okm = NCCrypto.hkdf(ikm: z, salt: auth, info: Data("nearclip-session".utf8) + th, count: 64)
        XCTAssertEqual(okm, hex(m["okm"]))
        XCTAssertEqual(okm.prefix(32), hex(m["k_c2s"]))
        XCTAssertEqual(okm.suffix(32), hex(m["k_s2c"]))
        for f in m["frames"] as! [[String: Any]] {
            let key = (f["dir"] as! String) == "c2s" ? hex(m["k_c2s"]) : hex(m["k_s2c"])
            let counter = (f["counter"] as! NSNumber).uint64Value
            XCTAssertEqual(NCCrypto.nonce(counter), hex(f["nonce"]))
            XCTAssertEqual(try NCCrypto.seal(key: key, counter: counter, hex(f["plaintext"])), hex(f["payload"]))
            XCTAssertEqual(try NCCrypto.open(key: key, counter: counter, hex(f["payload"])), hex(f["plaintext"]))
            XCTAssertThrowsError(try NCCrypto.open(key: key, counter: counter + 1, hex(f["payload"])))
        }
    }

    func testPairQR() throws {
        let q = section("pair_qr")
        let z = hex(section("ecdh")["shared_z"])
        let th = NCCrypto.sha256(utf8(q["hello_c_utf8"]) + utf8(q["hello_s_utf8"]))
        XCTAssertEqual(th, hex(q["th"]))
        let okm = NCCrypto.hkdf(ikm: z, salt: hex(q["ticket"]), info: Data("nearclip-pair-qr".utf8) + th, count: 64)
        XCTAssertEqual(okm.prefix(32), hex(q["k_c2s"]))
        XCTAssertEqual(okm.suffix(32), hex(q["k_s2c"]))
        let invite = try XCTUnwrap(PairingInvite(uri: q["uri"] as! String))
        XCTAssertEqual(invite.inviterId, section("ids")["server"] as? String)
        XCTAssertEqual(invite.name, "Vector Mac")
        XCTAssertEqual(invite.platform, "mac")
        XCTAssertEqual(invite.hosts, ["192.168.0.12", "10.0.0.5"])
        XCTAssertEqual(invite.port, 45821)
        XCTAssertEqual(invite.secret, hex(q["ticket"]))
        XCTAssertEqual(PairingInvite(uri: invite.uri), invite)
    }

    func testPairCode() {
        let c = section("pair_code")
        let e = section("ecdh")
        let n = section("nonces")
        let commit = NCCrypto.sha256(Data("nearclip-commit".utf8) + hex(e["server_public_x963"]) + hex(e["client_public_x963"]) + hex(n["ns"]))
        XCTAssertEqual(commit, hex(c["commit"]))
        let th = NCCrypto.sha256(utf8(c["hello_c_utf8"]) + utf8(c["hello_s_utf8"]) + hex(n["nc"]) + hex(n["ns"]))
        XCTAssertEqual(th, hex(c["th"]))
        XCTAssertEqual(NCCrypto.sas(th), c["sas"] as? String)
        let okm = NCCrypto.hkdf(ikm: hex(e["shared_z"]), salt: Data("nearclip-pair-code".utf8), info: th, count: 64)
        XCTAssertEqual(okm.prefix(32), hex(c["k_c2s"]))
        XCTAssertEqual(okm.suffix(32), hex(c["k_s2c"]))
    }

    func testEncodings() {
        for case let item as [String: String] in v["b64u"] as! [Any] {
            XCTAssertEqual(Base64URL.encode(Hex.decode(item["bytes"]!)!), item["b64u"])
            XCTAssertEqual(Base64URL.decode(item["b64u"]!), Hex.decode(item["bytes"]!))
        }
        XCTAssertEqual(Base64URL.decode("AAEC"), Data([0, 1, 2]))
        XCTAssertEqual(Base64URL.decode("AA=="), Data([0]))
        let b = section("blob")
        XCTAssertEqual(Hex.encode(NCCrypto.sha256(utf8(b["data_utf8"]))), b["sha256"] as? String)
    }
}

