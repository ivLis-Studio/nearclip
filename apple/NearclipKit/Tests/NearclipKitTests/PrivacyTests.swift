import XCTest
@testable import NearclipKit

final class PrivacyTests: XCTestCase {
    func testVaultMigratesLegacyAndRejectsTamperingAndFileSwaps() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = FileSecretStore(directory: dir.appendingPathComponent("keys"))
        let vault = try LocalVault(secrets: secrets)
        let file = dir.appendingPathComponent("history.json")
        let plain = Data("private history 👋 482915".utf8)
        try plain.write(to: file)
        XCTAssertEqual(try vault.read(file), plain)
        var encrypted = try Data(contentsOf: file)
        XCTAssertTrue(encrypted.starts(with: Data("NCV1".utf8)))
        XCTAssertNil(String(data: encrypted, encoding: .utf8)?.range(of: "private history"))
        XCTAssertEqual(try LocalVault(secrets: secrets).read(file), plain)
        let other = dir.appendingPathComponent("another.json")
        try encrypted.write(to: other)
        XCTAssertThrowsError(try vault.read(other))
        encrypted[encrypted.count - 1] ^= 1
        try encrypted.write(to: file)
        XCTAssertThrowsError(try vault.read(file))
        XCTAssertEqual(try Data(contentsOf: file), encrypted)
    }
    func testExpiryAndPolicies() {
        let now: Int64 = 1_800_000_000_000
        let code = Clip(id: newNearclipId(), ts: now, src: newNearclipId(), kind: "text", text: "1234", otp: true)
        XCTAssertFalse(code.isExpired(at: now + 179_999))
        XCTAssertTrue(code.isExpired(at: now + 180_000))
        XCTAssertTrue(code.isExpired(at: now - 60_001))
        XCTAssertFalse(SyncPolicy(codes: false).permits(code, sending: true))
        XCTAssertFalse(SyncPolicy(send: false).permits(code, sending: true))
        XCTAssertTrue(SyncPolicy(send: false).permits(code, sending: false))
    }
    func testShareEngineHasSeparateFilesAndNoHistory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let shareDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: shareDir) }
        let main = try Peer.makeNode("Main phone", dir)
        main.sendText("must not be exported to the share extension")
        let seed = try main.shareSeed(paused: false, images: true)
        let share = try NearclipNode.shareNode(seed: seed, directory: shareDir)
        XCTAssertEqual(main.deviceId, share.deviceId)
        XCTAssertEqual(main.snapshot().groupId, share.snapshot().groupId)
        XCTAssertTrue(share.snapshot().history.isEmpty)
        XCTAssertEqual(main.snapshot().history.count, 1)
        share.stop(); main.stop()
    }
}
