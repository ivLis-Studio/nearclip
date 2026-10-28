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
        /// Embedded Tailscale node (remote connection, PROTOCOL.md §10). nil = not available.
        public var tailnet: TailnetOptions?
        /// Tests and demos: never dial or advertise LAN endpoints, so sessions must go through the tailnet
        /// (what a phone on mobile data looks like to the other devices).
        public var lanDial = true
        /// Tests and demos: send image chunks at about this many bytes per second, like a slow network, so the
        /// receiving side's progress can be seen (PROTOCOL.md §6.6). 0: as fast as the connection takes them.
        public var blobPace = 0

        public init(stateDirectory: URL, deviceName: String, platform: String, model: String? = nil,
                    appVersion: String? = nil, port: UInt16 = 45821, bonjour: Bool = true, secretStore: SecretStore,
                    tailnet: TailnetOptions? = nil) {
            self.stateDirectory = stateDirectory; self.deviceName = deviceName; self.platform = platform
            self.model = model; self.appVersion = appVersion; self.port = port; self.bonjour = bonjour
            self.secretStore = secretStore; self.tailnet = tailnet
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

    /// A live image arriving from another device (PROTOCOL.md §6.6). The same clip can come through several
    /// sessions (forwarding); the transfer ends when one of them delivers it or all of them are gone.
    private struct Transfer {
        var from: String
        var total: Int
        var received: Int
        var sessions: Set<ObjectIdentifier>
        var updated: Date
    }
    private var transfers: [String: Transfer] = [:]
    /// Images this device announced and has not sent or cancelled yet.
    private var announced: [String: Date] = [:]
    /// A transfer that makes no progress for this long is reported as failed (§6.6).
    static let transferTimeout: TimeInterval = 60

    // Remote connection (embedded Tailscale node, PROTOCOL.md §10).
    /// Tailnet port every Nearclip node accepts connections on.
    static let tailnetPort = 45821
    /// Tailnet candidates start this much later than LAN candidates (§10.3).
    static let tailnetDelay: TimeInterval = 0.4
    private var remoteEnabled = false
    private var tailnetStatus = TailnetStatus.off
    private var tailnetListener: NWListener?
    private var tailnetForwardPort: UInt16 = 0
    private var tailnetGeneration = 0
    private var tailnetReach = ""
    private let tailnetQueue = DispatchQueue(label: "studio.ivlis.nearclip.tailnet")
    private var pathMonitor: NWPathMonitor?
    private var pathSignature: String?
    private var pathWork: DispatchWorkItem?

    public init(config: Config) throws {
        self.config = config
        try FileManager.default.createDirectory(at: config.stateDirectory, withIntermediateDirectories: true)
        let store = try NodeStore(directory: config.stateDirectory, defaultName: config.deviceName, owner: queue, secrets: config.secretStore)
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
            pathMonitor?.cancel()
            pathMonitor = nil
            timer?.cancel()
            timer = nil
            store.saveNow()
        }
        // Let the embedded node shut down cleanly (bounded by the bridge's own timeout).
        tailnetQueue.sync {}
    }

    public func snapshot() -> NodeSnapshot { queue.sync { snapshotInternal() } }

    public func shareSeed(paused: Bool, images: Bool) throws -> ShareSeed {
        try queue.sync {
            var state = store.state
            state.members = memberList()
            return ShareSeed(state: try JSONEncoder().encode(state), groupId: state.groupId, groupKey: groupKey,
                             deviceName: deviceName, model: config.model, appVersion: config.appVersion, members: memberList().filter { !$0.removed && $0.id != deviceId }, paused: paused, images: images, remote: tailnetStatus.isRunning ? tailnetStatus : nil)
        }
    }
    func borrowShareRoute(_ status: TailnetStatus) { queue.sync { tailnetStatus = status } }
    public func supportsTargeting(_ id: String) -> Bool { queue.sync { online[id]?.supportsPolicies == true } }
    public func outgoingIdle(to id: String) -> Bool { queue.sync { online[id].map { !$0.conn.isClosed && $0.conn.pendingSends == 0 } ?? false } }

    public func policy(for id: String) -> SyncPolicy { queue.sync { store.state.policies?[id] ?? SyncPolicy() } }
    public func setPolicy(_ policy: SyncPolicy, for id: String) {
        queue.sync {
            if store.state.policies == nil { store.state.policies = [:] }
            store.state.policies?[id] = policy
            store.saveNow()
        }
    }
    private func canSend(_ c: Clip, to s: PeerSession) -> Bool {
        guard let id = s.peerId, !c.isExpired() else { return false }
        if c.recipients != nil, !c.isAddressed(to: id) || !s.supportsPolicies { return false }
        return (store.state.policies?[id] ?? SyncPolicy()).permits(c, sending: true)
    }
    private func canReceive(_ c: Clip) -> Bool {
        c.hasValidIdentity && !c.isExpired() && c.isAddressed(to: deviceId) &&
        (store.state.policies?[c.src] ?? SyncPolicy()).permits(c, sending: false)
    }

    public func blobData(for id: String) -> Data? { store.blobData(id) }
    public func blobURL(for id: String) -> URL { store.previewURL(id) }

    /// `otp`: a verification code found in a message (PROTOCOL.md §6.7).
    @discardableResult
    public func sendText(_ text: String, otp: Bool = false) -> StoredClip? {
        queue.sync {
            guard !text.isEmpty else { return nil }
            guard text.utf8.count <= Wire.maxText else { emit(.tooLarge(kind: "text")); return nil }
            let c = Clip(id: newNearclipId(), ts: max(nowMs(), newestLocalTs + 1), src: deviceId, kind: "text", text: text,
                         otp: otp ? true : nil)
            return produce(c, blob: nil)
        }
    }

    @discardableResult
    public func sendImage(_ data: Data, mime: String, width: Int? = nil, height: Int? = nil, id: String? = nil) -> StoredClip? {
        queue.sync {
            let announcedId = id?.lowercased()
            if let a = announcedId { announced[a] = nil }
            guard !data.isEmpty else { cancelAnnouncement(announcedId); return nil }
            guard data.count <= Wire.maxImage else {
                cancelAnnouncement(announcedId)
                emit(.tooLarge(kind: "image"))
                return nil
            }
            var cid = newNearclipId()
            if let a = announcedId, UUID(uuidString: a) != nil, !store.has(a), store.state.tombstones[a] == nil { cid = a }
            let c = Clip(id: cid, ts: max(nowMs(), newestLocalTs + 1), src: deviceId, kind: "image",
                         mime: mime, size: data.count, sha: Hex.encode(NCCrypto.sha256(data)), w: width, h: height)
            return produce(c, blob: data)
        }
    }

    /// Tells the other devices that an image was just copied here, before it is encoded (PROTOCOL.md §6.6), so they
    /// can show it arriving right away. Pass the returned id to `sendImage`, or to `cancelImage` if it is not sent.
    public func announceImage() -> String {
        let id = newNearclipId()
        queue.async {
            guard self.running, !self.paused else { return }
            self.announced[id] = Date()
            for s in self.online.values where s.isMember {
                let p = self.store.state.policies?[s.peerId ?? ""] ?? SyncPolicy()
                if p.send && p.images { s.sendJSON(IncomingMsg(id: id, kind: "image")) }
            }
        }
        return id
    }

    /// The announced image will not be sent after all (unreadable, too large, replaced by a newer copy).
    public func cancelImage(_ id: String) {
        queue.async {
            let id = id.lowercased()
            guard self.announced.removeValue(forKey: id) != nil else { return }
            self.cancelAnnouncement(id)
        }
    }

    private func cancelAnnouncement(_ id: String?) {
        guard let id else { return }
        for s in online.values where s.isMember { s.sendJSON(IncomingMsg(id: id, cancel: true)) }
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
            for (pid, s) in self.online where pid != id && !s.supportsRekey { s.sendJSON(MembersMsg(members: [r])) }
            self.rotateAfterRemoval()
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
            self.startCodeJoin([DialCandidate(endpoint: d.endpoint, address: nil, proxyRequest: nil, delay: 0, route: .lan)])
        }
    }

    /// Joiner: numeric-comparison pairing with an explicit address.
    public func pairWithCode(host: String, port: UInt16) {
        queue.async {
            let targets = self.candidates(for: [Endpoint(h: host, p: Int(port))], fallback: true)
            guard !targets.isEmpty else { self.emit(.pairFailed(reason: "unreachable")); return }
            self.startCodeJoin(targets)
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
            self.dialMember(peerId: nil, candidates: self.candidates(for: [Endpoint(h: host, p: Int(port))], fallback: true))
        }
    }

    /// Call after wake from sleep / network changes: drop sessions that went silent, forget back-off and redial now.
    public func nudge() {
        queue.async { self.networkChanged() }
    }

    // MARK: - Remote connection (public)

    /// Whether this build can run the embedded Tailscale node.
    public var isTailnetAvailable: Bool { config.tailnet != nil }

    /// Remote connection on/off (the app persists the choice). The node runs only while networking runs.
    public func setRemoteEnabled(_ on: Bool) {
        queue.async {
            guard self.remoteEnabled != on else { return }
            self.remoteEnabled = on
            if on { self.startTailnetIfNeeded() } else { self.stopTailnet() }
        }
    }

    /// Makes sure a Tailscale sign-in URL exists. The completion runs on `eventQueue` with the fresh status.
    public func tailnetLogin(_ completion: @escaping @Sendable (TailnetStatus) -> Void) {
        queue.async {
            let gen = self.tailnetGeneration
            guard self.tailnetListener != nil else {
                let st = self.tailnetStatus
                self.eventQueue.async { completion(st) }
                return
            }
            self.tailnetQueue.async {
                let st = TailnetBridge.login()
                self.queue.async {
                    if gen == self.tailnetGeneration { self.applyTailnet(st) }
                    self.eventQueue.async { completion(st) }
                }
            }
        }
    }

    /// Signs this device out of Tailscale (remote connection then needs a new sign-in).
    public func tailnetLogout() {
        queue.async {
            let gen = self.tailnetGeneration
            guard self.tailnetListener != nil else { return }
            self.tailnetQueue.async {
                let st = TailnetBridge.logout()
                self.queue.async { if gen == self.tailnetGeneration { self.applyTailnet(st) } }
            }
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
                     addresses: LocalAddresses.ipv4(), routes: online.mapValues { $0.route },
                     remoteEnabled: remoteEnabled, tailnet: tailnetStatus)
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
        startPathMonitor()
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
        stopTailnet()
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
                self.startTailnetIfNeeded()
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
            dialMember(peerId: d.id, candidates: dialCandidates(for: d.id))
        } else {
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, let d2 = self.discovered[d.id], d2.gt == self.groupTag, self.running, !self.paused,
                      self.online[d.id] == nil, self.dialing[d.id] == nil else { return }
                self.dialMember(peerId: d2.id, candidates: self.dialCandidates(for: d2.id))
            }
        }
    }

    /// All ways to reach a member: the discovered service, remembered endpoints and its tailnet node.
    private func dialCandidates(for id: String) -> [DialCandidate] {
        var out: [DialCandidate] = []
        if config.lanDial, let d = discovered[id], d.gt == groupTag {
            out.append(DialCandidate(endpoint: d.endpoint, address: nil, proxyRequest: nil, delay: 0, route: .lan))
        }
        var eps = store.state.endpoints[id] ?? []
        if tailnetStatus.isRunning {
            let id8 = String(id.replacingOccurrences(of: "-", with: "").prefix(8))
            for p in tailnetStatus.peers where p.idPrefix == id8 { eps.append(Endpoint(h: p.ip, p: Self.tailnetPort)) }
        }
        return out + candidates(for: eps)
    }

    /// Direct candidates for LAN endpoints; tailnet endpoints go through the bridge proxy (and through the
    /// OS when the Tailscale app itself is connected) and start a little later (PROTOCOL.md §10.3).
    private func candidates(for eps: [Endpoint], fallback: Bool = false) -> [DialCandidate] {
        var out: [DialCandidate] = []
        var seen = Set<Endpoint>()
        let st = tailnetStatus
        var osTailnet: Bool?
        for e in eps where !e.h.isEmpty && seen.insert(e).inserted {
            guard TailnetAddress.contains(e.h) else {
                if config.lanDial, let c = DialCandidate.direct(e) { out.append(c) }
                continue
            }
            if e.h == st.ip { continue }
            if st.isRunning, let pp = st.proxyPort, let token = st.token, let proxy = NWEndpoint.Port(rawValue: UInt16(clamping: pp)) {
                out.append(DialCandidate(endpoint: .hostPort(host: "127.0.0.1", port: proxy), address: e,
                                         proxyRequest: "NCTN1 \(token) \(e.h):\(e.p)\n", delay: Self.tailnetDelay, route: .remote))
            }
            if osTailnet == nil { osTailnet = LocalAddresses.ipv4().contains(where: TailnetAddress.contains) }
            if osTailnet == true, let c = DialCandidate.direct(e, delay: Self.tailnetDelay, route: .remote) { out.append(c) }
        }
        if out.isEmpty, fallback, let e = eps.first, let c = DialCandidate.direct(e) { out.append(c) }
        return out
    }

    private func dialMember(peerId: String?, candidates: [DialCandidate]) {
        guard running, !paused, !candidates.isEmpty else { return }
        if let pid = peerId {
            guard online[pid] == nil, dialing[pid] == nil else { return }
            dialing[pid] = Date()
        }
        let conn = FramedConnection(candidates: candidates, queue: queue)
        let s = PeerSession(role: .client, mode: .member, connection: conn, node: self)
        s.expectedPeerId = peerId
        sessions.insert(s)
        s.start()
    }

    private func accept(_ nw: NWConnection, viaTailnet: Bool = false) {
        guard running, !paused else { nw.cancel(); return }
        let conn = FramedConnection(nw: nw, queue: queue)
        conn.viaTailnet = viaTailnet
        let s = PeerSession(role: .server, mode: nil, connection: conn, node: self)
        sessions.insert(s)
        s.start()
    }

    private func ownEndpoints() -> [Endpoint] {
        guard port > 0 else { return [] }
        var eps = config.lanDial ? LocalAddresses.ipv4().map { Endpoint(h: $0, p: Int(port)) } : []
        if tailnetStatus.isRunning, let ip = tailnetStatus.ip { eps.append(Endpoint(h: ip, p: Self.tailnetPort)) }
        return eps
    }

    /// Keeps up to 6 LAN and 2 tailnet endpoints per member, newest first (PROTOCOL.md §4.5).
    private func rememberEndpoints(_ peerId: String, _ eps: [Endpoint]) {
        var seen = Set<Endpoint>()
        let merged = (eps + (store.state.endpoints[peerId] ?? [])).filter { !$0.h.isEmpty && seen.insert($0).inserted }
        let lan = merged.filter { !TailnetAddress.contains($0.h) }.prefix(6)
        let tail = merged.filter { TailnetAddress.contains($0.h) }.prefix(2)
        store.state.endpoints[peerId] = Array(lan) + Array(tail)
        store.saveSoon()
    }

    private func tick() {
        guard running else { return }
        let now = Date()
        if let t = ticket, t.expires <= now {
            ticket = nil
            emit(.ticketExpired)
        }
        expireTransfers(now: now)
        prune()
        guard !paused else { return }
        for (id, rec) in store.members where id != deviceId && !rec.removed && online[id] == nil && dialing[id] == nil {
            let b = backoff[id] ?? (next: .distantPast, delay: 10)
            guard now >= b.next else { continue }
            // Every known way to reach the member at once; the first connection wins (PROTOCOL.md §4.5).
            let targets = dialCandidates(for: id)
            guard !targets.isEmpty else { continue }
            backoff[id] = (next: now.addingTimeInterval(b.delay), delay: min(b.delay * 2, 300))
            dialMember(peerId: id, candidates: targets)
        }
    }

    // MARK: - Network changes

    private func startPathMonitor() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let sig = "\(path.status)|" + path.availableInterfaces.map { "\($0.name)" }.joined(separator: ",")
                + "|" + LocalAddresses.ipv4().joined(separator: ",")
            guard sig != self.pathSignature else { return }
            let first = self.pathSignature == nil
            self.pathSignature = sig
            guard !first else { return }
            self.pathWork?.cancel()
            let w = DispatchWorkItem { [weak self] in
                self?.log("network changed")
                self?.networkChanged()
            }
            self.pathWork = w
            self.queue.asyncAfter(deadline: .now() + 1, execute: w)
        }
        m.start(queue: queue)
        pathMonitor = m
    }

    /// Wake from sleep, app back in the foreground, interface change: drop sessions that went silent,
    /// forget back-off and redial now (PROTOCOL.md §4.5, §10.4).
    private func networkChanged() {
        guard running, !paused else { return }
        let now = Date()
        for s in online.values where now.timeIntervalSince(s.lastReceived) > 20 { s.close() }
        backoff = [:]
        if listener == nil { startListener(port: config.port) }
        if config.bonjour && browser == nil { startBrowser() }
        if tailnetListener != nil { tailnetQueue.async { TailnetBridge.networkChanged() } }
        for s in online.values { s.sendJSON(SimpleMsg(t: "ping")) }
        tick()
    }

    // MARK: - Embedded Tailscale node

    private func startTailnetIfNeeded() {
        guard remoteEnabled, running, !paused, let opts = config.tailnet, port > 0 else { return }
        guard let _ = tailnetListener else { startTailnetListener(); return }
        guard tailnetForwardPort > 0 else { return }  // continues when the loopback listener is ready
        var cfg: [String: Any] = ["dir": opts.directory.path, "deviceId": deviceId, "deviceName": deviceName,
                                  "ports": [Int(port)], "forward": "127.0.0.1:\(tailnetForwardPort)"]
        if let c = opts.controlURL { cfg["controlURL"] = c }
        if let l = opts.logPath { cfg["logPath"] = l }
        if opts.testMode { cfg["testMode"] = true }
        Self.excludeFromBackup(opts.directory)
        tailnetGeneration += 1
        let gen = tailnetGeneration
        if !tailnetStatus.isRunning { applyTailnet(TailnetStatus(state: "starting")) }
        tailnetQueue.async { [weak self] in
            let st = TailnetBridge.start(cfg)
            guard let self else { return }
            self.queue.async {
                guard gen == self.tailnetGeneration else { return }
                self.applyTailnet(st)
                self.scheduleTailnetPoll(gen)
            }
        }
    }

    /// Inbound tailnet connections arrive here from the bridge (loopback only).
    private func startTailnetListener() {
        let params = FramedConnection.parameters()
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let l = try? NWListener(using: params) else {
            applyTailnet(TailnetStatus(state: "error", error: "loopback listener"))
            return
        }
        tailnetListener = l
        l.newConnectionHandler = { [weak self] nw in self?.accept(nw, viaTailnet: true) }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l, self.tailnetListener === l else { return }
            switch state {
            case .ready:
                self.tailnetForwardPort = l.port?.rawValue ?? 0
                self.startTailnetIfNeeded()
            case .failed(let error):
                self.log("tailnet listener failed: \(error)")
                l.cancel()
                self.tailnetListener = nil
                self.tailnetForwardPort = 0
                self.applyTailnet(TailnetStatus(state: "error", error: error.localizedDescription))
            default:
                break
            }
        }
        l.start(queue: queue)
    }

    private func stopTailnet() {
        let active = tailnetListener != nil || tailnetStatus.state != "off"
        tailnetListener?.cancel()
        tailnetListener = nil
        tailnetForwardPort = 0
        tailnetGeneration += 1
        guard active else { return }
        tailnetQueue.async { _ = TailnetBridge.stop() }
        applyTailnet(.off)
    }

    private func scheduleTailnetPoll(_ gen: Int) {
        let delay: TimeInterval = tailnetStatus.isRunning ? 5 : 1.5
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, gen == self.tailnetGeneration, self.tailnetListener != nil else { return }
            self.tailnetQueue.async {
                let st = TailnetBridge.status()
                self.queue.async {
                    guard gen == self.tailnetGeneration else { return }
                    self.applyTailnet(st)
                    self.scheduleTailnetPoll(gen)
                }
            }
        }
    }

    private func applyTailnet(_ st: TailnetStatus) {
        let old = tailnetStatus
        tailnetStatus = st
        if !old.sameEssentials(st) { emit(.tailnetChanged(st)) }
        // New ways to reach members (node came up, other nodes appeared): dial at once.
        let reach = st.isRunning ? (st.ip ?? "") + "|" + st.peers.map { "\($0.idPrefix ?? "")@\($0.ip)" }.joined(separator: ",") : ""
        if reach != tailnetReach {
            tailnetReach = reach
            if st.isRunning {
                backoff = [:]
                tick()
            }
        }
    }

    private static func excludeFromBackup(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var u = url
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
    }

    // MARK: - Session callbacks

    func sessionEstablished(_ s: PeerSession) {
        guard !s.retired else { s.close(); return }
        guard s.peerId != nil else { s.close(); return }
        // Removal is decided after both welcomes were merged (PROTOCOL §4.3): a re-added device carries a
        // newer record of itself than a member that was offline when it was re-added.
        s.sendJSON(WelcomeMsg(device: ownRecord, members: memberList(), addrs: ownEndpoints()))
    }

    func sessionWelcome(_ s: PeerSession, _ msg: WelcomeMsg) {
        guard !s.retired else { s.close(); return }
        guard let pid = s.peerId else { return }
        if let expected = s.expectedPeerId, expected != pid { dialing[expected] = nil }
        dialing[pid] = nil
        var eps = (msg.addrs ?? []).filter { !$0.h.isEmpty && $0.p > 0 && $0.p < 65536 }
        if let a = s.dialedEndpoint {
            eps.insert(a, at: 0)
        } else if s.role == .server, !s.conn.viaTailnet, let host = s.conn.remoteHost, let p = msg.addrs?.first?.p {
            // Never remember the loopback address of connections relayed by the tailnet bridge (§10.1).
            eps.insert(Endpoint(h: host, p: p), at: 0)
        }
        rememberEndpoints(pid, eps)
        s.supportsPolicies = msg.features?.contains("policy1") == true
        s.supportsRekey = msg.features?.contains("rekey1") == true
        var device = msg.device
        device.id = pid
        mergeMembers((msg.members ?? []) + [device], from: s)
        guard !s.conn.isClosed, s.phase == .established else { return }
        if store.members[pid]?.removed == true { s.bye("removed"); return }
        guard registerOnline(s) else { return }
        backoff[pid] = nil
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
        if let rec = store.members[pid] { emit(.peerUp(rec, s.route)) }
        return true
    }

    func sessionMessage(_ s: PeerSession, type: String, json: Data) {
        guard !s.retired else { return }
        let dec = Wire.decoder
        switch type {
        case "rekey":
            if let m = try? dec.decode(RekeyMsg.self, from: json) { applyRekey(m, from: s) }
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
        case "incoming":
            if let m = try? dec.decode(IncomingMsg.self, from: json) { handleIncoming(m, from: s) }
        case "error":
            if let m = try? dec.decode(ErrorMsg.self, from: json) { log("peer error \(m.code ?? "") \(m.msg ?? "")") }
        default:
            break
        }
    }

    func sessionBye(_ s: PeerSession, reason: String) {
        guard !s.retired else { return }
        if reason == "removed" && s.mode == .member { leave(reason: "removed", announce: false) }
    }

    func sessionClosed(_ s: PeerSession) {
        sessions.remove(s)
        let key = ObjectIdentifier(s)
        for (id, t) in transfers where t.sessions.contains(key) { dropTransfer(id, session: s, reason: "disconnected") }
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

    private func rotateAfterRemoval() {
        let m = RekeyMsg(previous: groupTag, groupId: store.state.groupId, key: Base64URL.encode(NCCrypto.random(32)), members: memberList())
        applyRekey(m, from: nil)
    }

    private func applyRekey(_ m: RekeyMsg, from source: PeerSession?) {
        guard m.previous == groupTag, m.groupId == store.state.groupId,
              let key = Base64URL.decode(m.key), key.count == 32,
              m.members.contains(where: { $0.id == deviceId && !$0.removed }),
              source == nil || (source?.peerId.flatMap { online[$0] } === source) else { return }
        do { try config.secretStore.save(key, account: "group-key-" + store.state.groupId) }
        catch { log("could not save rotated group key"); return }
        let removed = Set(m.members.filter(\.removed).map(\.id))
        for (id, s) in online where !removed.contains(id) && s !== source && s.supportsRekey { s.sendJSON(m) }
        // Existing session traffic has independent ephemeral keys. Flush its handover before closing.
        groupKey = key; groupTag = NCCrypto.groupTag(key); authKey = NCCrypto.authKey(key)
        mergeMembers(m.members, from: source)
        store.saveNow()
        for s in sessions { s.retired = true; s.bye("rekey") }
        refreshAdvertisement()
        backoff = [:]
    }

    // MARK: - Clips

    private func produce(_ original: Clip, blob: Data?) -> StoredClip {
        var c = original
        if store.state.policies?.values.contains(where: { !$0.permits(c, sending: true) }) == true {
            c.recipients = store.members.values.filter { !$0.removed && $0.id != deviceId &&
                (store.state.policies?[$0.id] ?? SyncPolicy()).permits(c, sending: true) }.map(\.id)
        }
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
        guard s.isMember, canSend(c, to: s) else { return }
        if c.isImage {
            guard let blob else { return }
            s.sendJSON(ClipMsg(live: live, clip: c))
            if config.blobPace > 0 {
                sendChunksPaced(clipId: c.id, blob: blob, offset: 0, index: 0, to: s)
                return
            }
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

    /// One chunk now and the next one when it would have gone out at `config.blobPace` (demos and tests).
    private func sendChunksPaced(clipId: String, blob: Data, offset: Int, index: UInt32, to s: PeerSession) {
        guard offset < blob.count, sessions.contains(s), !s.conn.isClosed else { return }
        let end = min(offset + Wire.chunkSize, blob.count)
        s.sendChunk(clipId: clipId, index: index, data: blob.subdata(in: offset..<end))
        let delay = Double(end - offset) / Double(max(1, config.blobPace))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.sendChunksPaced(clipId: clipId, blob: blob, offset: end, index: index + 1, to: s)
        }
    }

    private func handleClip(_ m: ClipMsg, from s: PeerSession) {
        var c = m.clip
        c.id = c.id.lowercased()
        c.src = c.src.lowercased()
        if !c.isText { c.otp = nil }
        let live = m.live ?? false
        guard c.kind == "text" || c.kind == "image" else { return }
        if !canReceive(c) || store.has(c.id) || store.state.tombstones[c.id] != nil {
            if c.isImage { s.skipBlobs.insert(c.id) }
            return
        }
        if c.isText {
            guard let t = c.text, t.utf8.count <= Wire.maxText else { return }
            acceptClip(c, blob: nil, live: live, from: s)
        } else {
            guard let size = c.size, size > 0, size <= Wire.maxImage, let sha = c.sha, sha.count == 64 else {
                s.skipBlobs.insert(c.id)
                dropTransfer(c.id, session: s, reason: "corrupt")
                return
            }
            guard s.pendingBlobs[c.id] == nil else { return }
            var data = Data()
            data.reserveCapacity(size)
            s.pendingBlobs[c.id] = PendingBlob(clip: c, live: live, data: data, next: 0)
            if live { startTransfer(c, size: size, session: s) }
        }
    }

    func sessionChunk(_ s: PeerSession, clipId: String, index: UInt32, data: Data) {
        guard !s.retired else { return }
        if s.skipBlobs.contains(clipId) { return }
        guard var p = s.pendingBlobs.removeValue(forKey: clipId) else { return }
        let size = p.clip.size ?? 0
        guard index == p.next, p.data.count + data.count <= size else {
            s.skipBlobs.insert(clipId)
            log("bad chunk for \(clipId)")
            dropTransfer(clipId, session: s, reason: "corrupt")
            return
        }
        p.data.append(data)
        p.next += 1
        noteProgress(clipId, received: p.data.count, session: s)
        guard p.data.count == size else {
            s.pendingBlobs[clipId] = p
            return
        }
        guard Hex.encode(NCCrypto.sha256(p.data)) == p.clip.sha?.lowercased() else {
            log("checksum mismatch for \(clipId)")
            dropTransfer(clipId, session: s, reason: "corrupt")
            return
        }
        if store.has(clipId) || store.state.tombstones[clipId] != nil {
            dropTransfer(clipId, session: s, reason: "cancelled")
            return
        }
        acceptClip(p.clip, blob: p.data, live: p.live, from: s)
    }

    private func acceptClip(_ c: Clip, blob: Data?, live: Bool, from s: PeerSession?) {
        guard canReceive(c) else {
            if let s { dropTransfer(c.id, session: s, reason: "cancelled") }
            return
        }
        transfers[c.id] = nil
        let src = store.members[c.src]
        let sc = StoredClip(clip: c, groupId: store.state.groupId, pinned: false, receivedAt: nowMs(),
                            srcName: src?.name, srcPlatform: src?.platform, textFile: nil)
        store.add(sc, blob: blob)
        for other in online.values where other !== s { sendClip(c, blob: blob, live: live, to: other) }
        // A verification code is offered by the app, not written to the clipboard on its own (§6.7).
        let apply = live && c.src != deviceId && c.ts > newestLocalTs && !c.isCode
        if apply {
            newestLocalTs = c.ts
            store.state.newestLocalTs = c.ts
        }
        emit(.clipAdded(sc, live: live, apply: apply, local: false))
        prune()
    }

    // MARK: - Transfers in progress (PROTOCOL.md §6.6)

    private func handleIncoming(_ m: IncomingMsg, from s: PeerSession) {
        guard let pid = s.peerId, UUID(uuidString: m.id) != nil else { return }
        let id = m.id.lowercased()
        if m.cancel == true {
            // Only an announcement can be cancelled; once the clip message came, the chunks decide.
            if let t = transfers[id], t.total == 0 { dropTransfer(id, session: s, reason: "cancelled") }
            return
        }
        let policy = store.state.policies?[pid] ?? SyncPolicy()
        guard policy.receive, policy.images, m.kind == "image", transfers[id] == nil, !store.has(id), store.state.tombstones[id] == nil else { return }
        transfers[id] = Transfer(from: pid, total: 0, received: 0, sessions: [ObjectIdentifier(s)], updated: Date())
        emitTransfer(id, .preparing)
    }

    private func startTransfer(_ c: Clip, size: Int, session s: PeerSession) {
        var t = transfers[c.id] ?? Transfer(from: c.src, total: size, received: 0, sessions: [], updated: Date())
        t.from = c.src
        t.total = size
        t.sessions.insert(ObjectIdentifier(s))
        t.updated = Date()
        transfers[c.id] = t
        emitTransfer(c.id, .receiving)
    }

    private func noteProgress(_ id: String, received: Int, session s: PeerSession) {
        guard var t = transfers[id], t.sessions.contains(ObjectIdentifier(s)), received > t.received else { return }
        t.received = received
        t.updated = Date()
        transfers[id] = t
        emitTransfer(id, .receiving)
    }

    /// The session will not deliver the clip; the transfer fails once no other session is bringing it.
    private func dropTransfer(_ id: String, session s: PeerSession, reason: String) {
        guard var t = transfers[id] else { return }
        guard t.sessions.remove(ObjectIdentifier(s)) != nil else { return }
        if t.sessions.isEmpty {
            transfers[id] = nil
            emit(.transfer(IncomingTransfer(id: id, from: t.from, state: .failed, received: t.received, total: t.total, reason: reason)))
        } else {
            transfers[id] = t
        }
    }

    private func emitTransfer(_ id: String, _ state: IncomingTransfer.State) {
        guard let t = transfers[id] else { return }
        emit(.transfer(IncomingTransfer(id: id, from: t.from, state: state, received: t.received, total: t.total)))
    }

    private func expireTransfers(now: Date) {
        for (id, t) in transfers where now.timeIntervalSince(t.updated) > Self.transferTimeout {
            transfers[id] = nil
            emit(.transfer(IncomingTransfer(id: id, from: t.from, state: .failed, received: t.received, total: t.total, reason: "timeout")))
        }
        announced = announced.filter { now.timeIntervalSince($0.value) < 300 }
    }

    private func prune() {
        let expired = store.history.filter { $0.clip.isExpired() }.map { IdTs(id: $0.id, ts: nowMs()) }
        if !expired.isEmpty { applyDeletes(expired, from: nil) }
        let removed = store.prune()
        if !removed.isEmpty { emit(.clipsDeleted(removed)) }
    }

    private func sendInventory(_ s: PeerSession) {
        let now = nowMs()
        let gid = store.state.groupId
        let clips = store.history.lazy
            .filter { $0.groupId == gid && $0.clip.ts >= now - 7 * 86_400_000 && self.canSend($0.clip, to: s) }
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
        var hosts = LocalAddresses.ipv4()
        // A joiner in the same tailnet can pair from another network (the node also listens on `port`).
        if tailnetStatus.isRunning, let ip = tailnetStatus.ip, !hosts.contains(ip) { hosts.append(ip) }
        let invite = PairingInvite(inviterId: deviceId, name: deviceName, platform: platform,
                                   hosts: hosts, port: port, secret: secret)
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
        var targets: [DialCandidate] = []
        if let d = discovered[invite.inviterId] {
            targets.append(DialCandidate(endpoint: d.endpoint, address: nil, proxyRequest: nil, delay: 0, route: .lan))
        }
        var eps = invite.hosts.map { Endpoint(h: $0, p: Int(invite.port)) }
        if tailnetStatus.isRunning {
            let id8 = String(invite.inviterId.replacingOccurrences(of: "-", with: "").prefix(8))
            for p in tailnetStatus.peers where p.idPrefix == id8 { eps.append(Endpoint(h: p.ip, p: Int(invite.port))) }
        }
        targets += candidates(for: eps)
        guard !targets.isEmpty else { emit(.pairFailed(reason: "unreachable")); return }
        joining = true
        attemptJoin(mode: .pairQR, secret: invite.secret, targets: targets)
    }

    private func startCodeJoin(_ targets: [DialCandidate]) {
        guard !joining else { emit(.pairFailed(reason: "busy")); return }
        joining = true
        attemptJoin(mode: .pairCode, secret: nil, targets: targets)
    }

    /// Races all targets (PROTOCOL.md §4.5); the first that opens carries the pairing.
    private func attemptJoin(mode: PeerSession.Mode, secret: Data?, targets: [DialCandidate]) {
        guard joining else { return }
        let conn = FramedConnection(candidates: targets, queue: queue)
        let s = PeerSession(role: .client, mode: mode, connection: conn, node: self)
        s.pairSecret = secret
        s.onPairResult = { [weak self, weak s] result in
            guard let self else { return }
            switch result {
            case .success(let accept):
                self.completeJoin(accept, via: s)
            case .failure(let error):
                self.joining = false
                let reachedInviter = s?.gotPeerHello ?? false
                let reason: String
                if error == .timeout {
                    reason = "timeout"
                } else if !reachedInviter && error.code == "io" {
                    reason = "unreachable"
                } else if mode == .pairQR && error.code == "io" {
                    // A QR inviter silently closes on an expired, used or wrong ticket.
                    reason = "no_ticket"
                } else {
                    reason = error.code
                }
                self.emit(.pairFailed(reason: reason))
            }
        }
        joinSession = s
        sessions.insert(s)
        s.start()
    }

    private func completeJoin(_ accept: PairAcceptMsg, via s: PeerSession?) {
        joining = false
        guard accept.group.id.count == 36, UUID(uuidString: accept.group.id) != nil,
              let key = Base64URL.decode(accept.group.key), key.count == 32 else {
            emit(.pairFailed(reason: "protocol"))
            return
        }
        let inviter = accept.device.id.lowercased()
        for o in sessions where o.isMember { o.bye("leaving") }
        online = [:]
        dialing = [:]
        backoff = [:]
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
        dialMember(peerId: inviter, candidates: dialCandidates(for: inviter))
        for d in discovered.values where d.gt == groupTag && d.id != inviter { considerDial(d) }
    }
}

