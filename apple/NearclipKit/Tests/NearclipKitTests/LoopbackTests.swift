import XCTest
@testable import NearclipKit

/// Runs real nodes over localhost TCP (no Bonjour).
final class Peer {
    let dir: URL
    let name: String
    var node: NearclipNode
    private let lock = NSLock()
    private var events: [NodeEvent] = []
    private var cursor = 0

    init(_ name: String, dir: URL? = nil) throws {
        self.name = name
        self.dir = dir ?? FileManager.default.temporaryDirectory.appendingPathComponent("nearclip-test-\(UUID().uuidString)")
        node = try Peer.makeNode(name, self.dir)
        attach()
    }

    static func makeNode(_ name: String, _ dir: URL) throws -> NearclipNode {
        try NearclipNode(config: .init(stateDirectory: dir, deviceName: name, platform: "cli", appVersion: "test", port: 0,
                                       bonjour: false, secretStore: FileSecretStore(directory: dir.appendingPathComponent("secrets"))))
    }

    private func attach() {
        node.eventQueue = DispatchQueue(label: "events-\(name)")
        node.onEvent = { [weak self] e in
            guard let self else { return }
            self.lock.lock(); self.events.append(e); self.lock.unlock()
        }
    }

    func restart() throws {
        node.stop()
        node = try Peer.makeNode(name, dir)
        lock.lock(); events = []; cursor = 0; lock.unlock()
        attach()
        node.start()
    }

    /// Waits for the next event (after previously consumed ones) matching `match`.
    @discardableResult
    func wait<T>(_ what: String, timeout: TimeInterval = 15, _ match: (NodeEvent) -> T?) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            var found: T?
            var idx = cursor
            while idx < events.count {
                if let v = match(events[idx]) { found = v; break }
                idx += 1
            }
            lock.unlock()
            if let found { return found }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("\(name): timed out waiting for \(what)")
        return nil
    }

    var port: UInt16 {
        wait("ready") { if case .ready(let p, _, _) = $0 { return p } else { return nil } } ?? 0
    }
}

final class LoopbackTests: XCTestCase {
    func testPairSyncCatchUpDeleteRemove() throws {
        let a = try Peer("Alpha"), b = try Peer("Bravo"), c = try Peer("Charlie")
        a.node.start(); b.node.start(); c.node.start()
        let aPort = a.port
        XCTAssertGreaterThan(aPort, 0)

        // QR pairing: Bravo joins Alpha.
        var invite = a.node.createTicket().invite
        invite.hosts = ["127.0.0.1"]
        b.node.join(invite: invite)
        b.wait("paired") { if case .paired(_, let peer, _, true) = $0, peer == a.node.deviceId { return true } else { return nil } }
        a.wait("paired") { if case .paired(_, let peer, _, false) = $0, peer == b.node.deviceId { return true } else { return nil } }
        b.wait("peerUp alpha") { if case .peerUp(let r) = $0, r.id == a.node.deviceId { return true } else { return nil } }
        a.wait("peerUp bravo") { if case .peerUp(let r) = $0, r.id == b.node.deviceId { return true } else { return nil } }
        XCTAssertEqual(a.node.snapshot().groupId, b.node.snapshot().groupId)

        // Live text.
        let hello = try XCTUnwrap(a.node.sendText("hello from alpha · 안녕"))
        let got = b.wait("text clip") { e -> (String, Bool, Bool)? in
            if case .clipAdded(let sc, let live, let apply, false) = e, sc.id == hello.id { return (sc.clip.text ?? "", live, apply) }
            return nil
        }
        XCTAssertEqual(got?.0, "hello from alpha · 안녕")
        XCTAssertEqual(got?.1, true)
        XCTAssertEqual(got?.2, true)

        // Multi-chunk image from Bravo.
        let image = NCCrypto.random(2_500_000)
        let img = try XCTUnwrap(b.node.sendImage(image, mime: "image/png", width: 10, height: 10))
        a.wait("image clip") { if case .clipAdded(let sc, true, _, false) = $0, sc.id == img.id { return true } else { return nil } }
        XCTAssertEqual(a.node.blobData(for: img.id), image)

        // Code pairing: Charlie joins Alpha by number comparison.
        c.node.pairWithCode(host: "127.0.0.1", port: aPort)
        let prompt = a.wait("pair prompt") { if case .pairPrompt(let p) = $0 { return p } else { return nil } }
        let code = c.wait("pair code") { if case .pairCode(let code, _) = $0 { return code } else { return nil } }
        XCTAssertEqual(prompt?.code, code)
        XCTAssertEqual(prompt?.name, "Charlie")
        a.node.answerPairPrompt(accept: true)
        c.wait("paired charlie") { if case .paired(_, _, _, true) = $0 { return true } else { return nil } }
        // Catch-up delivers both earlier clips (not live).
        c.wait("catch-up text") { if case .clipAdded(let sc, false, false, false) = $0, sc.id == hello.id { return true } else { return nil } }
        c.wait("catch-up image") { if case .clipAdded(let sc, false, false, false) = $0, sc.id == img.id { return true } else { return nil } }
        XCTAssertEqual(c.node.blobData(for: img.id), image)
        // Bravo learns about Charlie through member gossip.
        b.wait("members include charlie") { if case .membersChanged(let l) = $0, l.contains(where: { $0.id == c.node.deviceId }) { return true } else { return nil } }

        // Deletion propagates everywhere.
        a.node.delete(ids: [hello.id])
        b.wait("deleted on bravo") { if case .clipsDeleted(let ids) = $0, ids.contains(hello.id) { return true } else { return nil } }
        c.wait("deleted on charlie") { if case .clipsDeleted(let ids) = $0, ids.contains(hello.id) { return true } else { return nil } }

        // Catch-up after restart: Bravo goes away, Alpha copies, Bravo returns.
        b.node.stop()
        a.wait("bravo down") { if case .peerDown(let id) = $0, id == b.node.deviceId { return true } else { return nil } }
        let away = try XCTUnwrap(a.node.sendText("while you were away"))
        try b.restart()
        b.wait("catch-up after restart", timeout: 30) { if case .clipAdded(let sc, false, _, false) = $0, sc.id == away.id { return true } else { return nil } }

        // Removal: Alpha removes Charlie, Charlie leaves the group.
        a.node.removeMember(c.node.deviceId)
        c.wait("charlie left") { if case .left(let reason) = $0, reason == "removed" { return true } else { return nil } }
        XCTAssertNotEqual(c.node.snapshot().groupId, a.node.snapshot().groupId)

        a.node.stop(); b.node.stop(); c.node.stop()
    }

    func testWrongTicketIsRejected() throws {
        let a = try Peer("Alpha"), b = try Peer("Bravo")
        a.node.start(); b.node.start()
        _ = a.port
        var invite = a.node.createTicket().invite
        invite.hosts = ["127.0.0.1"]
        invite.secret = NCCrypto.random(16)
        b.node.join(invite: invite)
        b.wait("pair failed") { if case .pairFailed = $0 { return true } else { return nil } }
        XCTAssertNotEqual(a.node.snapshot().groupId, b.node.snapshot().groupId)
        a.node.stop(); b.node.stop()
    }

    func testDeclinedCodePairing() throws {
        let a = try Peer("Alpha"), b = try Peer("Bravo")
        a.node.start(); b.node.start()
        let port = a.port
        b.node.pairWithCode(host: "127.0.0.1", port: port)
        a.wait("prompt") { if case .pairPrompt = $0 { return true } else { return nil } }
        a.node.answerPairPrompt(accept: false)
        let reason = b.wait("declined") { if case .pairFailed(let r) = $0 { return r } else { return nil } }
        XCTAssertEqual(reason, "declined")
        a.node.stop(); b.node.stop()
    }
}

