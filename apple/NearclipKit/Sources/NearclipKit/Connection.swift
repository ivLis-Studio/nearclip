import Foundation
import Network

/// One way to reach a peer during a dial race (PROTOCOL.md §4.5, §10.3).
struct DialCandidate {
    /// Where to open the TCP connection: the peer itself, or the tailnet bridge proxy.
    var endpoint: NWEndpoint
    /// The peer address this candidate stands for (remembered when it wins).
    var address: Endpoint?
    /// Proxy request line ("NCTN1 <token> <ip>:<port>\n") when dialing through the tailnet bridge.
    var proxyRequest: String?
    /// Start delay; tailnet candidates start after the LAN ones.
    var delay: TimeInterval
    var route: PeerRoute

    static func direct(_ e: Endpoint, delay: TimeInterval = 0, route: PeerRoute = .lan) -> DialCandidate? {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: e.p)), e.p > 0 else { return nil }
        return DialCandidate(endpoint: .hostPort(host: NWEndpoint.Host(e.h), port: p), address: e, proxyRequest: nil,
                             delay: delay, route: route)
    }
}

/// Length-prefixed frames over a Network.framework TCP connection. All callbacks run on `queue`.
/// A dialing connection races all its candidates and keeps the first one that opens.
final class FramedConnection {
    private(set) var nw: NWConnection?
    let queue: DispatchQueue
    var onReady: (() -> Void)?
    var onFrame: ((Data) -> Void)?
    var onClose: ((NearclipError?) -> Void)?
    private(set) var isClosed = false
    private(set) var isReady = false
    /// The candidate that won the race (client connections).
    private(set) var winner: DialCandidate?
    /// Set for inbound connections relayed by the tailnet bridge.
    var viaTailnet = false
    private let candidates: [DialCandidate]
    private var racers: [ObjectIdentifier: NWConnection] = [:]
    private var pendingStarts = 0
    private var lastError: String?

    init(nw: NWConnection, queue: DispatchQueue) {
        self.nw = nw
        self.queue = queue
        self.candidates = []
    }

    init(candidates: [DialCandidate], queue: DispatchQueue) {
        self.nw = nil
        self.queue = queue
        self.candidates = candidates
    }

    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 20
        tcp.connectionTimeout = 6
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = false
        return params
    }

    /// Remote IP for inbound connections (IPv4-mapped IPv6 is unwrapped).
    var remoteHost: String? {
        guard winner == nil, let nw, case .hostPort(let host, _) = nw.endpoint else { return nil }
        return Self.describe(host)
    }

    /// Whether the connection runs over the tailnet.
    var route: PeerRoute {
        if let winner { return winner.route }
        if viaTailnet { return .remote }
        if let h = remoteHost, TailnetAddress.contains(h) { return .remote }
        return .lan
    }

    static func describe(_ host: NWEndpoint.Host) -> String? {
        var s: String
        switch host {
        case .ipv4(let a): s = "\(a)"
        case .ipv6(let a): s = "\(a)"
        case .name(let n, _): s = n
        @unknown default: return nil
        }
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
        if s.hasPrefix("::ffff:") { s = String(s.dropFirst(7)) }
        return s
    }

    func start() {
        if let nw {
            adopt(nw)
            nw.start(queue: queue)
            return
        }
        guard !candidates.isEmpty else {
            queue.async { [weak self] in self?.finish(.io("no address")) }
            return
        }
        pendingStarts = candidates.count
        for c in candidates {
            if c.delay <= 0 {
                launch(c)
            } else {
                queue.asyncAfter(deadline: .now() + c.delay) { [weak self] in self?.launch(c) }
            }
        }
        // Safety net: a race never takes longer than this.
        queue.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, !self.isClosed, self.winner == nil, self.nw == nil else { return }
            self.finish(.io(self.lastError ?? "unreachable"))
        }
    }

    private func launch(_ c: DialCandidate) {
        pendingStarts -= 1
        guard !isClosed, winner == nil else { return }
        let conn = NWConnection(to: c.endpoint, using: Self.parameters())
        let key = ObjectIdentifier(conn)
        racers[key] = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .ready:
                if let req = c.proxyRequest {
                    self.proxyHandshake(conn, request: req, candidate: c)
                } else {
                    self.win(conn, c)
                }
            case .waiting(let error), .failed(let error):
                self.lose(conn, error.localizedDescription)
            case .cancelled:
                self.lose(conn, nil)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func proxyHandshake(_ conn: NWConnection, request: String, candidate: DialCandidate) {
        conn.send(content: Data(request.utf8), completion: .contentProcessed { [weak self, weak conn] error in
            guard let self, let conn else { return }
            if let error { self.lose(conn, error.localizedDescription); return }
            let timeout = DispatchWorkItem { [weak self, weak conn] in
                guard let self, let conn else { return }
                self.lose(conn, "tailnet dial timed out")
            }
            self.queue.asyncAfter(deadline: .now() + 15, execute: timeout)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self, weak conn] data, _, _, error in
                timeout.cancel()
                guard let self, let conn else { return }
                if let data, data.first == 0 {
                    self.win(conn, candidate)
                } else {
                    let code = data?.first.map { Int($0) } ?? -1
                    self.lose(conn, error?.localizedDescription ?? "tailnet dial failed (\(code))")
                }
            }
        })
    }

    private func win(_ conn: NWConnection, _ c: DialCandidate) {
        guard !isClosed, winner == nil else {
            if racers[ObjectIdentifier(conn)] != nil { racers[ObjectIdentifier(conn)] = nil; conn.cancel() }
            return
        }
        winner = c
        nw = conn
        racers[ObjectIdentifier(conn)] = nil
        for other in racers.values { other.stateUpdateHandler = nil; other.cancel() }
        racers = [:]
        adopt(conn)
        isReady = true
        onReady?()
        readHeader()
    }

    private func lose(_ conn: NWConnection, _ error: String?) {
        let key = ObjectIdentifier(conn)
        guard racers[key] != nil else { return }
        racers[key] = nil
        conn.stateUpdateHandler = nil
        conn.cancel()
        if let error { lastError = error }
        if winner == nil, racers.isEmpty, pendingStarts <= 0 {
            finish(.io(lastError ?? "unreachable"))
        }
    }

    /// Installs the steady-state handler on the connection that carries the session.
    private func adopt(_ conn: NWConnection) {
        let accepted = winner == nil
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, !self.isClosed else { return }
            switch state {
            case .ready:
                if accepted && !self.isReady {
                    self.isReady = true
                    self.onReady?()
                    self.readHeader()
                }
            case .waiting(let error):
                // Fail fast: peers on the LAN either answer or are gone; the engine retries later.
                self.finish(.io(error.localizedDescription))
            case .failed(let error):
                self.finish(.io(error.localizedDescription))
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
    }

    func send(_ payload: Data, completion: (() -> Void)? = nil) {
        guard !isClosed, let nw else { return }
        var frame = Data(capacity: payload.count + 4)
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        nw.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error { self.finish(.io(error.localizedDescription)); return }
            completion?()
        })
    }

    func close() { finish(nil) }

    private func finish(_ error: NearclipError?) {
        guard !isClosed else { return }
        isClosed = true
        let cb = onClose
        onClose = nil
        onFrame = nil
        onReady = nil
        nw?.cancel()
        for other in racers.values { other.stateUpdateHandler = nil; other.cancel() }
        racers = [:]
        cb?(error)
    }

    private func readHeader() {
        nw?.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let error { self.finish(.io(error.localizedDescription)); return }
            guard let data, data.count == 4 else {
                self.finish(isComplete ? nil : .io("short read"))
                return
            }
            var length: UInt32 = 0
            for b in data { length = (length << 8) | UInt32(b) }
            guard length >= 1, length <= UInt32(Wire.maxFrame) else {
                self.finish(.protocolViolation("frame length \(length)"))
                return
            }
            self.readBody(Int(length))
        }
    }

    private func readBody(_ length: Int) {
        nw?.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let error { self.finish(.io(error.localizedDescription)); return }
            guard let data, data.count == length else {
                self.finish(isComplete ? nil : .io("short read"))
                return
            }
            self.onFrame?(Data(data))
            if !self.isClosed { self.readHeader() }
        }
    }
}

enum LocalAddresses {
    /// Non-loopback, non-link-local IPv4 addresses, Wi-Fi/Ethernet first.
    static func ipv4() -> [String] {
        var found: [(String, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            let ifa = p.pointee
            let flags = Int32(ifa.ifa_flags)
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
               (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let addr = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                    let name = String(cString: ifa.ifa_name)
                    if !addr.hasPrefix("169.254.") { found.append((name, addr)) }
                }
            }
            cursor = ifa.ifa_next
        }
        func rank(_ n: String) -> Int {
            if n == "en0" { return 0 }
            if n.hasPrefix("en") { return 1 }
            if n.hasPrefix("bridge") || n.hasPrefix("vnic") { return 2 }
            if n.hasPrefix("utun") || n.hasPrefix("ipsec") { return 4 }
            return 3
        }
        var seen = Set<String>()
        return found.sorted { rank($0.0) < rank($1.0) }.map(\.1).filter { seen.insert($0).inserted }
    }
}

