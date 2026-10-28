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
    func testClipIdentifiersCannotEscapeStorage() {
        let invalid = Clip(id: "../escape", ts: nowMs(), src: newNearclipId(), kind: "text", text: "x")
        XCTAssertFalse(invalid.hasValidIdentity)
        var valid = Clip(id: newNearclipId(), ts: nowMs(), src: newNearclipId(), kind: "text", text: "x")
        valid.recipients = ["invalid"]
        XCTAssertFalse(valid.hasValidIdentity)
    }
    func testSelectedRecipientAndOriginalDeviceCanKeepSharedHistory() {
        let source = newNearclipId(), recipient = newNearclipId(), other = newNearclipId()
        let clip = Clip(id: newNearclipId(), ts: nowMs(), src: source, kind: "text", text: "shared URL", recipients: [recipient])
        XCTAssertTrue(clip.isAddressed(to: source))
        XCTAssertTrue(clip.isAddressed(to: recipient))
        XCTAssertFalse(clip.isAddressed(to: other))
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
    func testInactivePoliciesDoNotRestrictNewClips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let node = try Peer.makeNode("Active policies", dir)
        defer { node.stop(); try? FileManager.default.removeItem(at: dir) }
        node.setPolicy(SyncPolicy(send: false), for: newNearclipId())
        XCTAssertNil(try XCTUnwrap(node.sendText("ordinary history")).clip.recipients)
    }
    func testExplicitRecipientDoesNotWidenAfterNewPairing() throws {
        let a = try Peer("Source"), b = try Peer("Selected"), c = try Peer("New device")
        defer { for p in [a,b,c] { p.node.stop(); try? FileManager.default.removeItem(at: p.dir) } }
        for p in [a,b,c] { p.node.start() }
        _ = a.port
        func pair(_ peer: Peer) {
            var invite = a.node.createTicket().invite; invite.hosts = ["127.0.0.1"]
            peer.node.join(invite: invite)
            peer.wait("connected source") { if case .peerUp(let m, _) = $0, m.id == a.node.deviceId { return true }; return nil }
            a.wait("connected recipient") { if case .peerUp(let m, _) = $0, m.id == peer.node.deviceId { return true }; return nil }
        }
        pair(b)
        let selected = try XCTUnwrap(a.node.sendText("selected device only", recipients: [b.node.deviceId]))
        XCTAssertEqual(selected.clip.recipients, [b.node.deviceId])
        b.wait("selected item") { if case .clipAdded(let item, _, _, false) = $0, item.id == selected.id { return true }; return nil }
        let publicItem = try XCTUnwrap(a.node.sendText("ordinary history"))
        pair(c)
        c.wait("public catch-up") { if case .clipAdded(let item, _, _, false) = $0, item.id == publicItem.id { return true }; return nil }
        a.node.setPolicy(SyncPolicy(send: false), for: b.node.deviceId)
        let denied = try XCTUnwrap(a.node.sendText("must not fall back to another recipient", recipients: [b.node.deviceId]))
        XCTAssertEqual(denied.clip.recipients, [])
        let barrier = try XCTUnwrap(a.node.sendText("after scoped sends"))
        c.wait("ordered barrier") { if case .clipAdded(let item, _, _, false) = $0, item.id == barrier.id { return true }; return nil }
        XCTAssertFalse(c.node.snapshot().history.contains { $0.id == selected.id || $0.id == denied.id })
    }

}
