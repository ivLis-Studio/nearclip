import Foundation
import Network

/// The Nearclip engine: listener, Bonjour, sessions, pairing, gossip and history.
/// Everything runs on `queue`; events are delivered on `eventQueue`.
public final class NearclipNode: @unchecked Sendable {
    public struct Config {
        public var stateDirectory: URL
        public var deviceName: String
        public var platform: String
        public var model: String?
        public var appVersion: String?
        public var port: UInt16
        public var bonjour: Bool
        public var secretStore: SecretStore

        public init(stateDirectory: URL, deviceName: String, platform: String, model: String? = nil,
                    appVersion: String? = nil, port: UInt16 = 45821, bonjour: Bool = true, secretStore: SecretStore) {
            self.stateDirectory = stateDirectory; self.deviceName = deviceName; self.platform = platform
            self.model = model; self.appVersion = appVersion; self.port = port; self.bonjour = bonjour
            self.secretStore = secretStore
        }
    }

    private struct Discovered {
        var id: String
        var name: String
        var platform: String
        var gt: String
        var pm: Bool
        var endpoint: NWEndpoint
    }

    private struct Ticket {
        var secret: Data
        var expires: Date
        var failures: Int
    }

    public let queue = DispatchQueue(label: "studio.ivlis.nearclip.node")
    public var eventQueue: DispatchQueue = .main
    public var onEvent: ((NodeEvent) -> Void)?

    let config: Config
    private let store: NodeStore
    public let deviceId: String
    private(set) var deviceName: String
    var platform: String { config.platform }
    private(set) var groupKey: Data
    private(set) var groupTag: String
    private(set) var authKey: Data

    private var listener: NWListener?
    private var browser: NWBrowser?
    private(set) var port: UInt16 = 0
    private var sessions = Set<PeerSession>()
    private var online: [String: PeerSession] = [:]
    private var dialing: [String: Date] = [:]
    private var backoff: [String: (next: Date, delay: TimeInterval)] = [:]
    private var attempt: [String: Int] = [:]
    private var discovered: [String: Discovered] = [:]
    private var ticket: Ticket?
    private var codeSession: PeerSession?
    private var codeAttempts: [Date] = []
    private var joining = false
    private var joinSession: PeerSession?
    private var pairingMode = false
    private var paused = false
    private var running = false
    private var timer: DispatchSourceTimer?
    private var newestLocalTs: Int64 = 0

    public init(config: Config) throws {
        self.config = config
        try FileManager.default.createDirectory(at: config.stateDirectory, withIntermediateDirectories: true)
        let store = NodeStore(directory: config.stateDirectory, defaultName: config.deviceName, owner: queue)
        self.store = store
        deviceId = store.state.deviceId
        deviceName = store.state.deviceName
        let key: Data
        if let k = config.secretStore.load("group-key-" + store.state.groupId), k.count == 32 {
            key = k
        } else {
            // First launch (or the key is gone): start a fresh solo group.
            key = NCCrypto.random(32)
            store.state.groupId = newNearclipId()
            store.state.joinedAt = nowMs()
            store.members = [:]
            store.state.endpoints = [:]
            try config.secretStore.save(key, account: "group-key-" + store.state.groupId)
        }
        groupKey = key
        groupTag = NCCrypto.groupTag(key)
        authKey = NCCrypto.authKey(key)
        newestLocalTs = store.state.newestLocalTs ?? 0
        ensureOwnRecord()
        store.saveNow()
    }

    // MARK: - Public API (thread-safe)

    public func start() { queue.async { self.startInternal() } }

    /// Sends `bye` to every peer and flushes state. Blocks until done.
    public func stop() {
        queue.sync {
            guard running else { store.saveNow(); return }
            running = false
            stopNetworking(reason: "shutdown")
            timer?.cancel()
            timer = nil
            store.saveNow()
        }
    }

    public func snapshot() -> NodeSnapshot { queue.sync { snapshotInternal() } }

    public func blobData(for id: String) -> Data? { store.blobData(id) }
    public func blobURL(for id: String) -> URL { store.blobURL(id) }

    @discardableResult
    public func sendText(_ text: String) -> StoredClip? {
        queue.sync {
            guard !text.isEmpty else { return nil }
            guard text.utf8.count <= Wire.maxText else { emit(.tooLarge(kind: "text")); return nil }
            let c = Clip(id: newNearclipId(), ts: max(nowMs(), newestLocalTs + 1), src: deviceId, kind: "text", text: text)
            return produce(c, blob: nil)
        }
    }

    @discardableResult
    public func sendImage(_ data: Data, mime: String, width: Int? = nil, height: Int? = nil) -> StoredClip? {
        queue.sync {
            guard !data.isEmpty else { return nil }
            guard data.count <= Wire.maxImage else { emit(.tooLarge(kind: "image")); return nil }
            let c = Clip(id: newNearclipId(), ts: max(nowMs(), newestLocalTs + 1), src: deviceId, kind: "image",
                         mime: mime, size: data.count, sha: Hex.encode(NCCrypto.sha256(data)), w: width, h: height)
            return produce(c, blob: data)
        }
    }

    /// Tells the engine that a clip was written to the system clipboard by the app (keeps "newest" ordering right).
    public func noteApplied(_ clip: Clip) {
        queue.async {
            if clip.ts > self.newestLocalTs { self.newestLocalTs = clip.ts; self.store.state.newestLocalTs = clip.ts }
        }
    }

    public func delete(ids: [String]) {
        queue.async { self.applyDeletes(ids.map { IdTs(id: $0.lowercased(), ts: nowMs()) }, from: nil) }
    }

    public func clearHistory() {
        queue.async { self.applyDeletes(self.store.history.map { IdTs(id: $0.id, ts: nowMs()) }, from: nil) }
    }

    public func setPinned(_ pinned: Bool, id: String) {
        queue.async { if let sc = self.store.setPinned(id.lowercased(), pinned) { self.emit(.clipUpdated(sc)) } }
    }

    public func setRetention(days: Int, maxItems: Int = 1000) {
        queue.async {
            self.store.retentionDays = days
            self.store.maxItems = maxItems
            self.prune()
        }
    }

    public func rename(_ name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        guard !trimmed.isEmpty else { return }
        queue.async {
            self.deviceName = trimmed
            self.store.state.deviceName = trimmed
            var me = self.ownRecord
            me.name = trimmed
            me.updatedAt = max(nowMs(), me.updatedAt + 1)
            self.store.members[self.deviceId] = me
            self.store.saveSoon()
            for s in self.online.values { s.sendJSON(MembersMsg(members: [me])) }
            self.refreshAdvertisement()
            self.emit(.membersChanged(self.memberList()))
        }
    }

    public func removeMember(_ id: String) {
        queue.async {
            let id = id.lowercased()
            guard id != self.deviceId, var r = self.store.members[id] else { return }
            r.removed = true
            r.updatedAt = max(nowMs(), r.updatedAt + 1)
            self.store.members[id] = r
            if let s = self.online[id] { s.bye("removed") }
            for (pid, s) in self.online where pid != id { s.sendJSON(MembersMsg(members: [r])) }
            self.store.saveSoon()
            self.emit(.membersChanged(self.memberList()))
        }
    }

    /// This device leaves its group and starts a new, empty one (history is kept).
    public func leaveGroup() { queue.async { self.leave(reason: "leaving", announce: true) } }

    public func setPaused(_ value: Bool) {
        queue.async {
            guard self.paused != value else { return }
            self.paused = value
            guard self.running else { return }
            if value { self.stopNetworking(reason: "shutdown") } else { self.startNetworking() }
        }
    }

    /// Advertise `pm=1` while the Add-device UI is visible.
    public func setPairingMode(_ on: Bool) {
        queue.async {
            guard self.pairingMode != on else { return }
            self.pairingMode = on
            self.refreshAdvertisement()
        }
    }

    @discardableResult
    public func createTicket() -> PairingTicket { queue.sync { createTicketInternal() } }

    public func cancelTicket() { queue.async { self.ticket = nil } }

    /// Joiner: QR / link pairing.
    public func join(invite: PairingInvite) { queue.async { self.joinInternal(invite) } }

    /// Joiner: numeric-comparison pairing with a device found nearby.
    public func pairWithCode(nearbyId: String) {
        queue.async {
            guard let d = self.discovered[nearbyId.lowercased()] else { self.emit(.pairFailed(reason: "unreachable")); return }
            self.startCodeJoin([(d.endpoint, nil)])
        }
    }

    /// Joiner: numeric-comparison pairing with an explicit address.
    public func pairWithCode(host: String, port: UInt16) {
        queue.async {
            guard let p = NWEndpoint.Port(rawValue: port) else { self.emit(.pairFailed(reason: "unreachable")); return }
            self.startCodeJoin([(.hostPort(host: NWEndpoint.Host(host), port: p), Endpoint(h: host, p: Int(port)))])
        }
    }

    public func cancelJoin() {
        queue.async {
            self.joinSession?.onPairResult = nil
            self.joinSession?.close()
            self.joinSession = nil
            self.joining = false
        }
    }

    /// Inviter: answer the pending code-pairing prompt.
    public func answerPairPrompt(accept: Bool) {
        queue.async {
            guard let s = self.codeSession, s.phase == .awaitDecision else { return }
            if accept {
                self.inviterAccept(s)
            } else {
                s.sendJSON(SimpleMsg(t: "pair_decline"), thenClose: true)
                self.codeSession = nil
            }
        }
    }

    /// Dial a member session at an explicit address.
    public func connect(host: String, port: UInt16) {
        queue.async {
            guard let p = NWEndpoint.Port(rawValue: port) else { return }
            self.dialMember(peerId: nil, endpoint: .hostPort(host: NWEndpoint.Host(host), port: p), address: Endpoint(h: host, p: Int(port)))
        }
    }

    // MARK: - Internal state

    var ownRecord: MemberRecord {
        store.members[deviceId] ?? MemberRecord(id: deviceId, name: deviceName, platform: platform, model: config.model,
                                                app: config.appVersion, addedAt: nowMs(), updatedAt: nowMs())
    }

    private func ensureOwnRecord() {
        let now = nowMs()
        var rec = store.members[deviceId] ?? MemberRecord(id: deviceId, name: deviceName, platform: platform, model: config.model,
                                                          app: config.appVersion, addedAt: now, updatedAt: now)
        if rec.name != deviceName || rec.platform != platform || rec.app != config.appVersion || rec.model != config.model || rec.removed {
            rec.name = deviceName
            rec.platform = platform
            rec.app = config.appVersion
            rec.model = config.model
            rec.removed = false
            rec.updatedAt = max(now, rec.updatedAt + 1)
        }
        store.members[deviceId] = rec
    }

    private func memberList() -> [MemberRecord] { store.members.values.sorted { $0.addedAt < $1.addedAt } }

    private func snapshotInternal() -> NodeSnapshot {
        NodeSnapshot(deviceId: deviceId, deviceName: deviceName, platform: platform, groupId: store.state.groupId,
                     members: memberList(), online: Set(online.keys), lastSeen: store.state.lastSeen,
                     history: store.history, nearby: nearbyList(), port: port, paused: paused,
                     addresses: LocalAddresses.ipv4())
    }

    private func emit(_ e: NodeEvent) {
        let handler = onEvent
        eventQueue.async { handler?(e) }
    }

    private func log(_ s: String) { emit(.log(s)) }

    // MARK: - Networking

    private func startInternal() {
        guard !running else { return }
        running = true
        prune()
        if !paused { startNetworking() }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func startNetworking() {
        if listener == nil { startListener(port: config.port) }
        if config.bonjour && browser == nil { startBrowser() }
    }

    private func stopNetworking(reason: String) {
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        for s in sessions {
            if s.isMember { s.bye(reason) } else { s.close() }
        }
        discovered = [:]
        emit(.nearbyChanged([]))
    }

    private func startListener(port preferred: UInt16) {
        let params = FramedConnection.parameters()
        params.allowLocalEndpointReuse = true
        let nwPort: NWEndpoint.Port = preferred == 0 ? .any : (NWEndpoint.Port(rawValue: preferred) ?? .any)
        guard let l = try? NWListener(using: params, on: nwPort) else {
            if preferred != 0 { startListener(port: 0) }
            return
        }
        listener = l
        l.newConnectionHandler = { [weak self] nw in self?.accept(nw) }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l, self.listener === l else { return }
            switch state {
            case .ready:
                self.port = l.port?.rawValue ?? 0
                self.emit(.ready(port: self.port, groupId: self.store.state.groupId, groupTag: self.groupTag))
            case .failed(let error):
                l.cancel()
                self.listener = nil
                if preferred != 0, case .posix(let code) = error, code == .EADDRINUSE {
                    self.startListener(port: 0)
                } else {
                    self.log("listener failed: \(error)")
                    self.queue.asyncAfter(deadline: .now() + 2) {
                        if self.running && !self.paused && self.listener == nil { self.startListener(port: preferred) }
                    }
                }
            default:
                break
            }
        }
        if config.bonjour { l.service = makeService() }
        l.start(queue: queue)
    }

    private static func truncateUTF8(_ s: String, _ limit: Int) -> String {
        var out = ""
        var used = 0
        for ch in s {
            let n = String(ch).utf8.count
            if used + n > limit { break }
            out.append(ch)
            used += n
        }
        return out
    }

    private func makeService() -> NWListener.Service {
        var txt = NWTXTRecord()
        txt["v"] = "1"
        txt["id"] = deviceId
        txt["nm"] = Self.truncateUTF8(deviceName, 60)
        txt["pf"] = platform
        txt["gt"] = groupTag
        if pairingMode { txt["pm"] = "1" }
        let name = Self.truncateUTF8(deviceName.isEmpty ? "Nearclip" : deviceName, 63)
        return NWListener.Service(name: name, type: Wire.serviceType, domain: nil, txtRecord: txt)
    }

    private func refreshAdvertisement() {
        guard config.bonjour, let l = listener else { return }
        l.service = makeService()
    }

    private func startBrowser() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Wire.serviceType, domain: nil), using: .tcp)
        browser = b
        b.browseResultsChangedHandler = { [weak self, weak b] results, _ in
            guard let self, let b, self.browser === b else { return }
            self.updateDiscovered(results)
        }
        b.stateUpdateHandler = { [weak self, weak b] state in
            guard let self, let b, self.browser === b else { return }
            if case .failed(let error) = state {
                self.log("browser failed: \(error)")
                b.cancel()
                self.browser = nil
                self.queue.asyncAfter(deadline: .now() + 3) {
                    if self.running && !self.paused && self.browser == nil && self.config.bonjour { self.startBrowser() }
                }
            }
        }
        b.start(queue: queue)
    }

    private func updateDiscovered(_ results: Set<NWBrowser.Result>) {
        var map: [String: Discovered] = [:]
        for r in results {
            guard case .bonjour(let txt) = r.metadata, txt["v"] == "1",
                  let id = txt["id"]?.lowercased(), !id.isEmpty, id != deviceId else { continue }
            var name = txt["nm"] ?? ""
            if name.isEmpty, case .service(let n, _, _, _) = r.endpoint { name = n }
            map[id] = Discovered(id: id, name: name, platform: txt["pf"] ?? "", gt: txt["gt"] ?? "", pm: txt["pm"] == "1", endpoint: r.endpoint)
        }
        let previous = discovered
        discovered = map
        for d in map.values where d.gt == groupTag {
            if previous[d.id] == nil { backoff[d.id] = nil }
            considerDial(d)
        }
        emit(.nearbyChanged(nearbyList()))
    }

    private func nearbyList() -> [NearbyDevice] {
        discovered.values.filter { $0.gt != groupTag }
            .map { NearbyDevice(id: $0.id, name: $0.name, platform: $0.platform, pairingMode: $0.pm) }
            .sorted { ($0.pairingMode ? 0 : 1, $0.name) < ($1.pairingMode ? 0 : 1, $1.name) }
    }

    private func considerDial(_ d: Discovered) {
        guard running, !paused, online[d.id] == nil, dialing[d.id] == nil, store.members[d.id]?.removed != true else { return }
        if deviceId < d.id {
            dialMember(peerId: d.id, endpoint: d.endpoint, address: nil)
        } else {
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, let d2 = self.discovered[d.id], d2.gt == self.groupTag,
                      self.online[d.id] == nil, self.dialing[d.id] == nil else { return }
                self.dialMember(peerId: d.id, endpoint: d2.endpoint, address: nil)
            }
        }
    }

    private func dialMember(peerId: String?, endpoint: NWEndpoint, address: Endpoint?) {
        guard running, !paused else { return }
        if let pid = peerId {
            guard online[pid] == nil, dialing[pid] == nil else { return }
            dialing[pid] = Date()
        }
        let conn = FramedConnection(nw: NWConnection(to: endpoint, using: FramedConnection.parameters()), queue: queue)
        let s = PeerSession(role: .client, mode: .member, connection: conn, node: self)
        s.expectedPeerId = peerId
        s.dialedEndpoint = address
        sessions.insert(s)
        s.start()
    }

    private func accept(_ nw: NWConnection) {
        guard running, !paused else { nw.cancel(); return }
        let s = PeerSession(role: .server, mode: nil, connection: FramedConnection(nw: nw, queue: queue), node: self)
        sessions.insert(s)
        s.start()
    }

    private func ownEndpoints() -> [Endpoint] {
        guard port > 0 else { return [] }
        return LocalAddresses.ipv4().map { Endpoint(h: $0, p: Int(port)) }
    }

    private func rememberEndpoints(_ peerId: String, _ eps: [Endpoint]) {
        var seen = Set<Endpoint>()
        let merged = (eps + (store.state.endpoints[peerId] ?? [])).filter { seen.insert($0).inserted }
        store.state.endpoints[peerId] = Array(merged.prefix(6))
        store.saveSoon()
    }

    private func tick() {
        guard running else { return }
        let now = Date()
        if let t = ticket, t.expires <= now {
            ticket = nil
            emit(.ticketExpired)
        }
        guard !paused else { return }
        for (id, rec) in store.members where id != deviceId && !rec.removed && online[id] == nil && dialing[id] == nil {
            let b = backoff[id] ?? (next: .distantPast, delay: 10)
            guard now >= b.next else { continue }
            var target: (NWEndpoint, Endpoint?)?
            if let d = discovered[id], d.gt == groupTag {
                target = (d.endpoint, nil)
            } else if let eps = store.state.endpoints[id], !eps.isEmpty {
                let n = attempt[id, default: 0]
                attempt[id] = n + 1
                let a = eps[n % eps.count]
                if let p = NWEndpoint.Port(rawValue: UInt16(clamping: a.p)) { target = (.hostPort(host: NWEndpoint.Host(a.h), port: p), a) }
            }
            guard let target else { continue }
            backoff[id] = (next: now.addingTimeInterval(b.delay), delay: min(b.delay * 2, 300))
            dialMember(peerId: id, endpoint: target.0, address: target.1)
        }
    }

    // MARK: - Session callbacks

    func sessionEstablished(_ s: PeerSession) {
        guard let pid = s.peerId else { s.close(); return }
        if store.members[pid]?.removed == true { s.bye("removed"); return }
        s.sendJSON(WelcomeMsg(device: ownRecord, members: memberList(), addrs: ownEndpoints()))
    }

    func sessionWelcome(_ s: PeerSession, _ msg: WelcomeMsg) {
        guard let pid = s.peerId else { return }
        if let expected = s.expectedPeerId, expected != pid { dialing[expected] = nil }
        dialing[pid] = nil
        var eps = (msg.addrs ?? []).filter { !$0.h.isEmpty && $0.p > 0 && $0.p < 65536 }
        if let a = s.dialedEndpoint {
            eps.insert(a, at: 0)
        } else if s.role == .server, let host = s.conn.remoteHost, let p = msg.addrs?.first?.p {
            eps.insert(Endpoint(h: host, p: p), at: 0)
        }
        rememberEndpoints(pid, eps)
        var device = msg.device
        device.id = pid
        mergeMembers((msg.members ?? []) + [device], from: s)
        guard !s.conn.isClosed, s.phase == .established else { return }
        if store.members[pid]?.removed == true { s.bye("removed"); return }
        guard registerOnline(s) else { return }
        backoff[pid] = nil
        attempt[pid] = 0
        sendInventory(s)
    }

    private func registerOnline(_ s: PeerSession) -> Bool {
        guard let pid = s.peerId else { return false }
        if let existing = online[pid], existing !== s {
            let newClient = s.role == .client ? deviceId : pid
            let oldClient = existing.role == .client ? deviceId : pid
            if newClient < oldClient {
                online[pid] = s
                existing.bye("duplicate")
                return true
            }
            s.bye("duplicate")
            return false
        }
        online[pid] = s
        store.state.lastSeen[pid] = nowMs()
        store.saveSoon()
        if let rec = store.members[pid] { emit(.peerUp(rec)) }
        return true
    }

    func sessionMessage(_ s: PeerSession, type: String, json: Data) {
        let dec = Wire.decoder
        switch type {
        case "clip":
            if let m = try? dec.decode(ClipMsg.self, from: json) { handleClip(m, from: s) }
        case "inv":
            if let m = try? dec.decode(InvMsg.self, from: json) { handleInventory(m, from: s) }
        case "want":
            if let m = try? dec.decode(WantMsg.self, from: json) { handleWant(m, from: s) }
        case "del":
            if let m = try? dec.decode(DelMsg.self, from: json) { applyDeletes(m.items ?? [], from: s) }
        case "members":
            if let m = try? dec.decode(MembersMsg.self, from: json) { mergeMembers(m.members ?? [], from: s) }
        case "error":
            if let m = try? dec.decode(ErrorMsg.self, from: json) { log("peer error \(m.code ?? "") \(m.msg ?? "")") }
        default:
            break
        }
    }

    func sessionBye(_ s: PeerSession, reason: String) {
        if reason == "removed" && s.mode == .member { leave(reason: "removed", announce: false) }
    }

    func sessionClosed(_ s: PeerSession) {
        sessions.remove(s)
        if s.role == .client, s.mode == .member {
            if let pid = s.expectedPeerId { dialing[pid] = nil }
            if let pid = s.peerId { dialing[pid] = nil }
        }
        if let pid = s.peerId, online[pid] === s {
            online[pid] = nil
            store.state.lastSeen[pid] = nowMs()
            store.saveSoon()
            emit(.peerDown(pid))
        }
        if codeSession === s {
            codeSession = nil
            emit(.pairPromptDismissed)
        }
        if joinSession === s { joinSession = nil }
    }

    // MARK: - Clips

    private func produce(_ c: Clip, blob: Data?) -> StoredClip {
        newestLocalTs = c.ts
        store.state.newestLocalTs = c.ts
        let sc = StoredClip(clip: c, groupId: store.state.groupId, pinned: false, receivedAt: nowMs(),
                            srcName: deviceName, srcPlatform: platform, textFile: nil)
        store.add(sc, blob: blob)
        for s in online.values { sendClip(c, blob: blob, live: true, to: s) }
        emit(.clipAdded(sc, live: true, apply: false, local: true))
        prune()
        return sc
    }

    private func sendClip(_ c: Clip, blob: Data?, live: Bool, to s: PeerSession) {
        guard s.isMember else { return }
        if c.isImage {
            guard let blob else { return }
            s.sendJSON(ClipMsg(live: live, clip: c))
            var index: UInt32 = 0
            var offset = 0
            while offset < blob.count {
                let end = min(offset + Wire.chunkSize, blob.count)
                s.sendChunk(clipId: c.id, index: index, data: blob.subdata(in: offset..<end))
                offset = end
                index += 1
            }
        } else {
            s.sendJSON(ClipMsg(live: live, clip: c))
        }
    }

    private func handleClip(_ m: ClipMsg, from s: PeerSession) {
        var c = m.clip
        c.id = c.id.lowercased()
        c.src = c.src.lowercased()
        let live = m.live ?? false
        guard c.kind == "text" || c.kind == "image" else { return }
        if store.has(c.id) || store.state.tombstones[c.id] != nil {
            if c.isImage { s.skipBlobs.insert(c.id) }
            return
        }
        if c.isText {
            guard let t = c.text, t.utf8.count <= Wire.maxText else { return }
            acceptClip(c, blob: nil, live: live, from: s)
        } else {
            guard let size = c.size, size > 0, size <= Wire.maxImage, let sha = c.sha, sha.count == 64 else {
                s.skipBlobs.insert(c.id)
                return
            }
            guard s.pendingBlobs[c.id] == nil else { return }
            var data = Data()
            data.reserveCapacity(size)
            s.pendingBlobs[c.id] = PendingBlob(clip: c, live: live, data: data, next: 0)
        }
    }

    func sessionChunk(_ s: PeerSession, clipId: String, index: UInt32, data: Data) {
        if s.skipBlobs.contains(clipId) { return }
        guard var p = s.pendingBlobs.removeValue(forKey: clipId) else { return }
        let size = p.clip.size ?? 0
        guard index == p.next, p.data.count + data.count <= size else {
            s.skipBlobs.insert(clipId)
            log("bad chunk for \(clipId)")
            return
        }
        p.data.append(data)
        p.next += 1
        guard p.data.count == size else {
            s.pendingBlobs[clipId] = p
            return
        }
        guard Hex.encode(NCCrypto.sha256(p.data)) == p.clip.sha?.lowercased() else {
            log("checksum mismatch for \(clipId)")
            return
        }
        if store.has(clipId) || store.state.tombstones[clipId] != nil { return }
        acceptClip(p.clip, blob: p.data, live: p.live, from: s)
    }

    private func acceptClip(_ c: Clip, blob: Data?, live: Bool, from s: PeerSession?) {
        let src = store.members[c.src]
        let sc = StoredClip(clip: c, groupId: store.state.groupId, pinned: false, receivedAt: nowMs(),
                            srcName: src?.name, srcPlatform: src?.platform, textFile: nil)
        store.add(sc, blob: blob)
        for other in online.values where other !== s { sendClip(c, blob: blob, live: live, to: other) }
        let apply = live && c.src != deviceId && c.ts > newestLocalTs
        if apply {
            newestLocalTs = c.ts
            store.state.newestLocalTs = c.ts
        }
        emit(.clipAdded(sc, live: live, apply: apply, local: false))
        prune()
    }

    private func prune() {
        let removed = store.prune()
        if !removed.isEmpty { emit(.clipsDeleted(removed)) }
    }

    private func sendInventory(_ s: PeerSession) {
        let now = nowMs()
        let gid = store.state.groupId
        let clips = store.history.lazy
            .filter { $0.groupId == gid && $0.clip.ts >= now - 7 * 86_400_000 }
            .prefix(200)
            .map { IdTs(id: $0.id, ts: $0.clip.ts) }
        let dels = store.state.tombstones.filter { $0.value >= now - 30 * 86_400_000 }.map { IdTs(id: $0.key, ts: $0.value) }
        s.sendJSON(InvMsg(clips: Array(clips), dels: dels))
    }

    private func handleInventory(_ m: InvMsg, from s: PeerSession) {
        applyDeletes(m.dels ?? [], from: s)
        let cutoff: Int64 = store.retentionDays > 0 ? nowMs() - Int64(store.retentionDays) * 86_400_000 : 0
        let want = (m.clips ?? [])
            .map { IdTs(id: $0.id.lowercased(), ts: $0.ts) }
            .filter { !store.has($0.id) && store.state.tombstones[$0.id] == nil && $0.ts >= cutoff }
            .map(\.id)
        if !want.isEmpty { s.sendJSON(WantMsg(ids: want)) }
    }

    private func handleWant(_ m: WantMsg, from s: PeerSession) {
        let gid = store.state.groupId
        for raw in (m.ids ?? []).prefix(500) {
            guard let sc = store.clip(raw.lowercased()), sc.groupId == gid else { continue }
            if sc.clip.isImage {
                guard (sc.clip.size ?? 0) <= Wire.maxCatchUpImage, let blob = store.blobData(sc.id) else { continue }
                sendClip(sc.clip, blob: blob, live: false, to: s)
            } else {
                sendClip(sc.clip, blob: nil, live: false, to: s)
            }
        }
    }

    private func applyDeletes(_ items: [IdTs], from s: PeerSession?) {
        var fresh: [IdTs] = []
        for it in items {
            let id = it.id.lowercased()
            guard store.state.tombstones[id] == nil else { continue }
            store.state.tombstones[id] = it.ts
            store.remove(id)
            fresh.append(IdTs(id: id, ts: it.ts))
        }
        guard !fresh.isEmpty else { return }
        store.saveSoon()
        for other in online.values where other !== s { other.sendJSON(DelMsg(items: fresh)) }
        emit(.clipsDeleted(fresh.map(\.id)))
    }

    // MARK: - Members

    private func mergeMembers(_ incoming: [MemberRecord], from source: PeerSession?) {
        var changed: [MemberRecord] = []
        var mustLeave = false
        for var r in incoming {
            r.id = r.id.lowercased()
            if r.id == deviceId {
                if r.removed && r.updatedAt >= ownRecord.updatedAt { mustLeave = true }
                continue
            }
            if let cur = store.members[r.id] {
                if r.updatedAt > cur.updatedAt || (r.updatedAt == cur.updatedAt && r.removed && !cur.removed) {
                    store.members[r.id] = r
                    changed.append(r)
                }
            } else {
                store.members[r.id] = r
                changed.append(r)
            }
        }
        if !changed.isEmpty {
            store.saveSoon()
            for r in changed where r.removed {
                if let s = online[r.id] { s.bye("removed") }
            }
            for (pid, s) in online where s !== source && store.members[pid]?.removed != true {
                s.sendJSON(MembersMsg(members: changed))
            }
            emit(.membersChanged(memberList()))
        }
        if mustLeave { leave(reason: "removed", announce: false) }
    }

    private func switchGroup(id: String, key: Data) {
        let old = store.state.groupId
        try? config.secretStore.save(key, account: "group-key-" + id)
        if old != id { config.secretStore.delete("group-key-" + old) }
        store.state.groupId = id
        store.state.joinedAt = nowMs()
        groupKey = key
        groupTag = NCCrypto.groupTag(key)
        authKey = NCCrypto.authKey(key)
        ticket = nil
    }

    private func leave(reason: String, announce: Bool) {
        if announce {
            var me = ownRecord
            me.removed = true
            me.updatedAt = max(nowMs(), me.updatedAt + 1)
            for s in online.values { s.sendJSON(MembersMsg(members: [me])) }
        }
        for s in sessions where s.isMember { s.bye(reason == "removed" ? "shutdown" : "leaving") }
        online = [:]
        dialing = [:]
        backoff = [:]
        attempt = [:]
        switchGroup(id: newNearclipId(), key: NCCrypto.random(32))
        let now = nowMs()
        store.members = [deviceId: MemberRecord(id: deviceId, name: deviceName, platform: platform, model: config.model,
                                                app: config.appVersion, addedAt: now, updatedAt: now)]
        store.state.endpoints = [:]
        store.state.lastSeen = [:]
        store.saveSoon()
        refreshAdvertisement()
        emit(.left(reason: reason))
        emit(.membersChanged(memberList()))
        emit(.nearbyChanged(nearbyList()))
    }

    // MARK: - Pairing

    private func createTicketInternal() -> PairingTicket {
        let secret = NCCrypto.random(16)
        let invite = PairingInvite(inviterId: deviceId, name: deviceName, platform: platform,
                                   hosts: LocalAddresses.ipv4(), port: port, secret: secret)
        let t = Ticket(secret: secret, expires: Date().addingTimeInterval(600), failures: 0)
        ticket = t
        let pt = PairingTicket(invite: invite, expiresAt: t.expires)
        emit(.ticket(pt))
        return pt
    }

    func currentTicketSecret() -> Data? {
        guard let t = ticket, t.expires > Date() else { return nil }
        return t.secret
    }

    func ticketDecryptFailed() {
        guard var t = ticket else { return }
        t.failures += 1
        ticket = t.failures >= 10 ? nil : t
    }

    func reserveCodePairing(_ s: PeerSession) -> Bool {
        let now = Date()
        codeAttempts = codeAttempts.filter { now.timeIntervalSince($0) < 60 }
        if let cur = codeSession, !cur.conn.isClosed { return false }
        guard codeAttempts.count < 10 else { return false }
        codeAttempts.append(now)
        codeSession = s
        return true
    }

    func inviterPrompt(_ s: PeerSession) {
        guard codeSession === s, let pid = s.peerId else { s.close(); return }
        let rec = s.peerRecord
        let name = (rec?.name).flatMap { $0.isEmpty ? nil : $0 } ?? s.peerName ?? ""
        let pf = (rec?.platform).flatMap { $0.isEmpty ? nil : $0 } ?? s.peerPlatform ?? ""
        emit(.pairPrompt(PairPrompt(peerId: pid, name: name, platform: pf, code: s.sas ?? "")))
    }

    func inviterAccept(_ s: PeerSession) {
        guard let pid = s.peerId, var rec = s.peerRecord else { s.close(); return }
        let now = nowMs()
        rec.id = pid
        rec.addedAt = now
        rec.updatedAt = max(now, (store.members[pid]?.updatedAt ?? 0) + 1)
        rec.removed = false
        store.members[pid] = rec
        let accept = PairAcceptMsg(group: GroupWire(id: store.state.groupId, key: Base64URL.encode(groupKey)),
                                   device: ownRecord, members: memberList())
        s.sendJSON(accept, thenClose: true)
        if s.mode == .pairQR { ticket = nil }
        if codeSession === s { codeSession = nil }
        store.saveSoon()
        for (opid, o) in online where opid != pid { o.sendJSON(MembersMsg(members: [rec])) }
        emit(.membersChanged(memberList()))
        emit(.paired(groupId: store.state.groupId, peerId: pid, peerName: rec.name, joined: false))
    }

    func joinerGotCode(_ s: PeerSession) {
        emit(.pairCode(code: s.sas ?? "", peerName: s.peerName ?? ""))
    }

    private func joinInternal(_ invite: PairingInvite) {
        guard !joining else { emit(.pairFailed(reason: "busy")); return }
        guard invite.inviterId != deviceId else { emit(.pairFailed(reason: "self")); return }
        var targets: [(NWEndpoint, Endpoint?)] = []
        if let p = NWEndpoint.Port(rawValue: invite.port) {
            targets = invite.hosts.map { (.hostPort(host: NWEndpoint.Host($0), port: p), Endpoint(h: $0, p: Int(invite.port))) }
        }
        if let d = discovered[invite.inviterId] { targets.insert((d.endpoint, nil), at: 0) }
        guard !targets.isEmpty else { emit(.pairFailed(reason: "unreachable")); return }
        joining = true
        attemptJoin(mode: .pairQR, secret: invite.secret, targets: targets, index: 0, lastError: nil)
    }

    private func startCodeJoin(_ targets: [(NWEndpoint, Endpoint?)]) {
        guard !joining else { emit(.pairFailed(reason: "busy")); return }
        joining = true
        attemptJoin(mode: .pairCode, secret: nil, targets: targets, index: 0, lastError: nil)
    }

    private func attemptJoin(mode: PeerSession.Mode, secret: Data?, targets: [(NWEndpoint, Endpoint?)], index: Int, lastError: NearclipError?) {
        guard joining else { return }
        guard index < targets.count else {
            joining = false
            emit(.pairFailed(reason: lastError.map { $0 == .timeout ? "timeout" : $0.code == "io" ? "unreachable" : $0.code } ?? "unreachable"))
            return
        }
        let (endpoint, address) = targets[index]
        let conn = FramedConnection(nw: NWConnection(to: endpoint, using: FramedConnection.parameters()), queue: queue)
        let s = PeerSession(role: .client, mode: mode, connection: conn, node: self)
        s.pairSecret = secret
        s.dialedEndpoint = address
        s.onPairResult = { [weak self, weak s] result in
            guard let self else { return }
            switch result {
            case .success(let accept):
                self.completeJoin(accept, via: s)
            case .failure(let error):
                let reachedInviter = s?.gotPeerHello ?? false
                if !reachedInviter && (error.code == "io" || error == .timeout) {
                    self.attemptJoin(mode: mode, secret: secret, targets: targets, index: index + 1, lastError: error)
                } else {
                    self.joining = false
                    // A QR inviter silently closes on an expired, used or wrong ticket.
                    let reason = error == .timeout ? "timeout" : (mode == .pairQR && error.code == "io" ? "no_ticket" : error.code)
                    self.emit(.pairFailed(reason: reason))
                }
            }
        }
        joinSession = s
        sessions.insert(s)
        s.start()
    }

    private func completeJoin(_ accept: PairAcceptMsg, via s: PeerSession?) {
        joining = false
        guard let key = Base64URL.decode(accept.group.key), key.count == 32 else {
            emit(.pairFailed(reason: "protocol"))
            return
        }
        let inviter = accept.device.id.lowercased()
        for o in sessions where o.isMember { o.bye("leaving") }
        online = [:]
        dialing = [:]
        backoff = [:]
        attempt = [:]
        switchGroup(id: accept.group.id.lowercased(), key: key)
        var members: [String: MemberRecord] = [:]
        for var r in (accept.members ?? []) + [accept.device] {
            r.id = r.id.lowercased()
            if let cur = members[r.id], cur.updatedAt > r.updatedAt { continue }
            members[r.id] = r
        }
        var me = members[deviceId] ?? ownRecord
        me.name = deviceName
        me.platform = platform
        me.model = config.model
        me.app = config.appVersion
        me.removed = false
        me.updatedAt = max(nowMs(), me.updatedAt + 1)
        members[deviceId] = me
        store.members = members
        store.state.endpoints = [:]
        if let a = s?.dialedEndpoint { store.state.endpoints[inviter] = [a] }
        store.saveSoon()
        refreshAdvertisement()
        emit(.membersChanged(memberList()))
        emit(.nearbyChanged(nearbyList()))
        emit(.paired(groupId: store.state.groupId, peerId: inviter, peerName: accept.device.name, joined: true))
        if let a = s?.dialedEndpoint, let p = NWEndpoint.Port(rawValue: UInt16(clamping: a.p)) {
            dialMember(peerId: inviter, endpoint: .hostPort(host: NWEndpoint.Host(a.h), port: p), address: a)
        } else if let d = discovered[inviter] {
            dialMember(peerId: inviter, endpoint: d.endpoint, address: nil)
        }
        for d in discovered.values where d.gt == groupTag && d.id != inviter { considerDial(d) }
    }
}

