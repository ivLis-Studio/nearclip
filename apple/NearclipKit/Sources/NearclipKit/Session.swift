import Foundation
import Network

struct PendingBlob {
    var clip: Clip
    var live: Bool
    var data: Data
    var next: UInt32
}

/// One TCP connection: handshake (member / pair-qr / pair-code) and the encrypted message stream.
/// Lives entirely on the node queue.
final class PeerSession: Hashable {
    static func == (a: PeerSession, b: PeerSession) -> Bool { a === b }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    enum Role { case client, server }
    enum Mode: String { case member, pairQR = "pair-qr", pairCode = "pair-code" }
    enum Phase { case connecting, awaitHello, awaitNonce, awaitPairRequest, awaitDecision, awaitPairResult, established, closed }

    let role: Role
    private(set) var mode: Mode?
    let conn: FramedConnection
    weak var node: NearclipNode?
    let created = Date()
    private(set) var phase: Phase

    var peerId: String?
    var peerName: String?
    var peerPlatform: String?
    var peerRecord: MemberRecord?
    var expectedPeerId: String?
    /// The peer address the winning dial candidate stood for (client sessions).
    var dialedEndpoint: Endpoint? { conn.winner?.address }
    var route: PeerRoute { conn.route }
    var receivedWelcome = false
    var gotPeerHello = false
    var pairSecret: Data?
    var sas: String?
    var onPairResult: ((Result<PairAcceptMsg, NearclipError>) -> Void)?
    var pendingBlobs: [String: PendingBlob] = [:]
    var skipBlobs = Set<String>()
    var lastSent = Date()
    var lastReceived = Date()
    var closeError: NearclipError?

    private let eph = EphemeralKey()
    private let myNonce = NCCrypto.random(16)
    private var myHello = Data()
    private var peerHello = Data()
    private var peerEph = Data()
    private var commitment: Data?
    private var sendCipher: FrameCipher?
    private var recvCipher: FrameCipher?
    private var timer: DispatchSourceTimer?

    init(role: Role, mode: Mode?, connection: FramedConnection, node: NearclipNode) {
        self.role = role
        self.mode = mode
        self.conn = connection
        self.node = node
        self.phase = role == .client ? .connecting : .awaitHello
    }

    var isMember: Bool { mode == .member && phase == .established }
    var isPairing: Bool { mode == .pairQR || mode == .pairCode }

    func start() {
        conn.onReady = { [weak self] in self?.connected() }
        conn.onFrame = { [weak self] frame in self?.received(frame) }
        conn.onClose = { [weak self] error in self?.didClose(error) }
        conn.start()
        let t = DispatchSource.makeTimerSource(queue: conn.queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    // MARK: Sending

    func sendPlain(_ bytes: Data, thenClose: Bool = false) {
        lastSent = Date()
        conn.send(bytes, completion: thenClose ? { [weak self] in self?.close() } : nil)
    }

    func sendJSON<T: Encodable>(_ message: T, thenClose: Bool = false) {
        guard sendCipher != nil, let body = try? Wire.encoder.encode(message) else { return }
        var plain = Data([Wire.typeJSON])
        plain.append(body)
        sendEncrypted(plain, thenClose: thenClose)
    }

    func sendChunk(clipId: String, index: UInt32, data: Data) {
        var plain = Data([Wire.typeChunk])
        plain.append(Data(clipId.utf8))
        withUnsafeBytes(of: index.bigEndian) { plain.append(contentsOf: $0) }
        plain.append(data)
        sendEncrypted(plain)
    }

    private func sendEncrypted(_ plain: Data, thenClose: Bool = false) {
        guard sendCipher != nil, !conn.isClosed else { return }
        do {
            let payload = try sendCipher!.seal(plain)
            lastSent = Date()
            conn.send(payload, completion: thenClose ? { [weak self] in self?.close() } : nil)
        } catch {
            fail(.crypto("seal failed"))
        }
    }

    func bye(_ reason: String) {
        if sendCipher != nil { sendJSON(ByeMsg(reason: reason), thenClose: true) } else { close() }
    }

    func close() { conn.close() }

    func fail(_ error: NearclipError) {
        if closeError == nil { closeError = error }
        conn.close()
    }

    // MARK: Lifecycle

    private func connected() {
        guard role == .client, let node, let mode else { return }
        var hello: [String: Any] = [
            "t": "hello", "v": 1, "mode": mode.rawValue, "id": node.deviceId,
            "e": Base64URL.encode(eph.publicX963),
        ]
        switch mode {
        case .member:
            hello["gt"] = node.groupTag
            hello["n"] = Base64URL.encode(myNonce)
        case .pairQR:
            hello["n"] = Base64URL.encode(myNonce)
        case .pairCode:
            hello["nm"] = node.deviceName
            hello["pf"] = node.platform
        }
        myHello = Wire.jsonBytes(hello)
        phase = .awaitHello
        sendPlain(myHello)
    }

    private func didClose(_ error: NearclipError?) {
        if closeError == nil { closeError = error }
        phase = .closed
        timer?.cancel()
        timer = nil
        if let cb = onPairResult {
            onPairResult = nil
            cb(.failure(closeError ?? .io("connection closed")))
        }
        node?.sessionClosed(self)
    }

    private func tick() {
        let now = Date()
        switch phase {
        case .established:
            if now.timeIntervalSince(lastSent) >= 15 { sendJSON(SimpleMsg(t: "ping")) }
            if now.timeIntervalSince(lastReceived) >= 45 { fail(.timeout) }
        case .closed:
            break
        default:
            let limit: TimeInterval = isPairing ? 150 : 15
            if now.timeIntervalSince(created) >= limit { fail(.timeout) }
        }
    }

    // MARK: Receiving

    private func received(_ frame: Data) {
        lastReceived = Date()
        do {
            if recvCipher != nil {
                try receivedEncrypted(frame)
            } else {
                try receivedPlain(frame)
            }
        } catch let e as NearclipError {
            fail(e)
        } catch {
            fail(.protocolViolation("\(error)"))
        }
    }

    private func receivedPlain(_ frame: Data) throws {
        guard let obj = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any],
              let t = obj["t"] as? String else { throw NearclipError.protocolViolation("bad handshake frame") }
        if t == "error" { throw NearclipError.remote((obj["code"] as? String) ?? "error") }
        switch (role, phase) {
        case (.client, .awaitHello): try clientHello(obj, frame)
        case (.server, .awaitHello): try serverHello(obj, frame)
        case (.client, .awaitNonce): try clientNonce(obj)
        case (.server, .awaitNonce): try serverNonce(obj)
        default: throw NearclipError.protocolViolation("unexpected \(t)")
        }
    }

    private struct Hello { var mode: String; var id: String; var e: Data }

    private func parseHello(_ obj: [String: Any]) throws -> Hello {
        guard obj["t"] as? String == "hello" else { throw NearclipError.protocolViolation("expected hello") }
        guard (obj["v"] as? Int) == 1 else { throw NearclipError.remote("version") }
        guard let mode = obj["mode"] as? String, let id = (obj["id"] as? String)?.lowercased(), !id.isEmpty,
              let eStr = obj["e"] as? String, let e = Base64URL.decode(eStr), e.count == 65, e.first == 0x04
        else { throw NearclipError.protocolViolation("malformed hello") }
        guard let node, id != node.deviceId else { throw NearclipError.protocolViolation("hello from self") }
        return Hello(mode: mode, id: id, e: e)
    }

    private func installKeys(_ okm: Data) {
        let c2s = okm.prefix(32), s2c = okm.suffix(32)
        if role == .client {
            sendCipher = FrameCipher(key: Data(c2s))
            recvCipher = FrameCipher(key: Data(s2c))
        } else {
            sendCipher = FrameCipher(key: Data(s2c))
            recvCipher = FrameCipher(key: Data(c2s))
        }
    }

    private func clientHello(_ obj: [String: Any], _ frame: Data) throws {
        guard let node, let mode else { return }
        let h = try parseHello(obj)
        guard h.mode == mode.rawValue else { throw NearclipError.protocolViolation("mode mismatch") }
        gotPeerHello = true
        peerId = h.id
        peerHello = frame
        peerEph = h.e
        let z = try eph.sharedSecret(withX963: h.e)
        switch mode {
        case .member:
            guard obj["gt"] as? String == node.groupTag else { throw NearclipError.remote("group_mismatch") }
            let th = NCCrypto.sha256(myHello + frame)
            installKeys(NCCrypto.hkdf(ikm: z, salt: node.authKey, info: Data("nearclip-session".utf8) + th, count: 64))
            phase = .established
            node.sessionEstablished(self)
        case .pairQR:
            guard let secret = pairSecret else { throw NearclipError.protocolViolation("no ticket secret") }
            let th = NCCrypto.sha256(myHello + frame)
            installKeys(NCCrypto.hkdf(ikm: z, salt: secret, info: Data("nearclip-pair-qr".utf8) + th, count: 64))
            phase = .awaitPairResult
            sendJSON(PairRequestMsg(device: node.ownRecord))
        case .pairCode:
            guard let cStr = obj["c"] as? String, let c = Base64URL.decode(cStr), c.count == 32 else {
                throw NearclipError.protocolViolation("missing commitment")
            }
            commitment = c
            peerName = obj["nm"] as? String
            peerPlatform = obj["pf"] as? String
            phase = .awaitNonce
            sendPlain(Wire.jsonBytes(["t": "pair_nonce", "n": Base64URL.encode(myNonce)]))
        }
    }

    private func clientNonce(_ obj: [String: Any]) throws {
        guard let node, obj["t"] as? String == "pair_nonce", let nStr = obj["n"] as? String,
              let ns = Base64URL.decode(nStr), !ns.isEmpty else { throw NearclipError.protocolViolation("expected pair_nonce") }
        let expected = NCCrypto.sha256(Data("nearclip-commit".utf8) + peerEph + eph.publicX963 + ns)
        guard expected == commitment else { throw NearclipError.remote("commit") }
        let th = NCCrypto.sha256(myHello + peerHello + myNonce + ns)
        let z = try eph.sharedSecret(withX963: peerEph)
        sas = NCCrypto.sas(th)
        installKeys(NCCrypto.hkdf(ikm: z, salt: Data("nearclip-pair-code".utf8), info: th, count: 64))
        phase = .awaitPairResult
        node.joinerGotCode(self)
        sendJSON(PairRequestMsg(device: node.ownRecord))
    }

    private func serverHello(_ obj: [String: Any], _ frame: Data) throws {
        guard let node else { return }
        let h = try parseHello(obj)
        gotPeerHello = true
        peerId = h.id
        peerHello = frame
        peerEph = h.e
        let z = try eph.sharedSecret(withX963: h.e)
        switch h.mode {
        case "member":
            mode = .member
            guard obj["gt"] as? String == node.groupTag else {
                sendPlain(Wire.jsonBytes(["t": "error", "code": "group_mismatch"]), thenClose: true)
                return
            }
            myHello = Wire.jsonBytes([
                "t": "hello", "v": 1, "mode": "member", "id": node.deviceId, "gt": node.groupTag,
                "e": Base64URL.encode(eph.publicX963), "n": Base64URL.encode(myNonce),
            ])
            sendPlain(myHello)
            let th = NCCrypto.sha256(frame + myHello)
            installKeys(NCCrypto.hkdf(ikm: z, salt: node.authKey, info: Data("nearclip-session".utf8) + th, count: 64))
            phase = .established
            node.sessionEstablished(self)
        case "pair-qr":
            mode = .pairQR
            guard let secret = node.currentTicketSecret() else {
                sendPlain(Wire.jsonBytes(["t": "error", "code": "no_ticket"]), thenClose: true)
                return
            }
            pairSecret = secret
            myHello = Wire.jsonBytes([
                "t": "hello", "v": 1, "mode": "pair-qr", "id": node.deviceId,
                "e": Base64URL.encode(eph.publicX963), "n": Base64URL.encode(myNonce),
            ])
            sendPlain(myHello)
            let th = NCCrypto.sha256(frame + myHello)
            installKeys(NCCrypto.hkdf(ikm: z, salt: secret, info: Data("nearclip-pair-qr".utf8) + th, count: 64))
            phase = .awaitPairRequest
        case "pair-code":
            mode = .pairCode
            peerName = obj["nm"] as? String
            peerPlatform = obj["pf"] as? String
            guard node.reserveCodePairing(self) else {
                sendPlain(Wire.jsonBytes(["t": "error", "code": "busy"]), thenClose: true)
                return
            }
            let commit = NCCrypto.sha256(Data("nearclip-commit".utf8) + eph.publicX963 + h.e + myNonce)
            myHello = Wire.jsonBytes([
                "t": "hello", "v": 1, "mode": "pair-code", "id": node.deviceId,
                "e": Base64URL.encode(eph.publicX963), "c": Base64URL.encode(commit),
                "nm": node.deviceName, "pf": node.platform,
            ])
            sendPlain(myHello)
            phase = .awaitNonce
        default:
            sendPlain(Wire.jsonBytes(["t": "error", "code": "bad_request"]), thenClose: true)
        }
    }

    private func serverNonce(_ obj: [String: Any]) throws {
        guard obj["t"] as? String == "pair_nonce", let nStr = obj["n"] as? String,
              let nc = Base64URL.decode(nStr), !nc.isEmpty else { throw NearclipError.protocolViolation("expected pair_nonce") }
        sendPlain(Wire.jsonBytes(["t": "pair_nonce", "n": Base64URL.encode(myNonce)]))
        let th = NCCrypto.sha256(peerHello + myHello + nc + myNonce)
        let z = try eph.sharedSecret(withX963: peerEph)
        sas = NCCrypto.sas(th)
        installKeys(NCCrypto.hkdf(ikm: z, salt: Data("nearclip-pair-code".utf8), info: th, count: 64))
        phase = .awaitPairRequest
    }

    private func receivedEncrypted(_ frame: Data) throws {
        let plain: Data
        do {
            plain = try recvCipher!.open(frame)
        } catch {
            if mode == .pairQR && role == .server { node?.ticketDecryptFailed() }
            throw NearclipError.crypto("decrypt failed")
        }
        guard let type = plain.first else { return }
        switch type {
        case Wire.typeJSON:
            try handleJSON(Data(plain.dropFirst()))
        case Wire.typeChunk:
            guard phase == .established, receivedWelcome, plain.count > 41 else { return }
            let bytes = Data(plain)
            guard let clipId = String(data: bytes[1..<37], encoding: .ascii) else { return }
            var index: UInt32 = 0
            for b in bytes[37..<41] { index = (index << 8) | UInt32(b) }
            node?.sessionChunk(self, clipId: clipId.lowercased(), index: index, data: bytes.subdata(in: 41..<bytes.count))
        default:
            return
        }
    }

    private func handleJSON(_ json: Data) throws {
        guard let t = Wire.type(of: json) else { throw NearclipError.protocolViolation("message without t") }
        let dec = Wire.decoder
        switch phase {
        case .awaitPairRequest:
            guard t == "pair_request", let msg = try? dec.decode(PairRequestMsg.self, from: json) else {
                throw NearclipError.protocolViolation("expected pair_request")
            }
            var rec = msg.device
            rec.id = peerId ?? rec.id
            peerRecord = rec
            if mode == .pairQR {
                node?.inviterAccept(self)
            } else {
                phase = .awaitDecision
                node?.inviterPrompt(self)
            }
        case .awaitPairResult:
            switch t {
            case "pair_accept":
                guard let msg = try? dec.decode(PairAcceptMsg.self, from: json) else { throw NearclipError.protocolViolation("bad pair_accept") }
                let cb = onPairResult
                onPairResult = nil
                cb?(.success(msg))
                close()
            case "pair_decline":
                fail(.remote("declined"))
            case "error":
                let e = try? dec.decode(ErrorMsg.self, from: json)
                fail(.remote(e?.code ?? "error"))
            default:
                throw NearclipError.protocolViolation("unexpected \(t)")
            }
        case .established:
            if t == "ping" { sendJSON(SimpleMsg(t: "pong")); return }
            if t == "pong" { return }
            if t == "bye" {
                let reason = (try? dec.decode(ByeMsg.self, from: json))?.reason ?? "shutdown"
                node?.sessionBye(self, reason: reason)
                close()
                return
            }
            if !receivedWelcome {
                guard t == "welcome", let msg = try? dec.decode(WelcomeMsg.self, from: json) else {
                    throw NearclipError.protocolViolation("expected welcome")
                }
                receivedWelcome = true
                var rec = msg.device
                rec.id = peerId ?? rec.id
                peerRecord = rec
                node?.sessionWelcome(self, msg)
                return
            }
            node?.sessionMessage(self, type: t, json: json)
        default:
            throw NearclipError.protocolViolation("unexpected \(t)")
        }
    }
}

