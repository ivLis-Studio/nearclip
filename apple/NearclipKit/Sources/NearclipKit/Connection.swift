import Foundation
import Network

/// Length-prefixed frames over a Network.framework TCP connection. All callbacks run on `queue`.
final class FramedConnection {
    let nw: NWConnection
    let queue: DispatchQueue
    var onReady: (() -> Void)?
    var onFrame: ((Data) -> Void)?
    var onClose: ((NearclipError?) -> Void)?
    private(set) var isClosed = false
    private(set) var isReady = false

    init(nw: NWConnection, queue: DispatchQueue) {
        self.nw = nw
        self.queue = queue
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
        guard case .hostPort(let host, _) = nw.endpoint else { return nil }
        return Self.describe(host)
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
        nw.stateUpdateHandler = { [weak self] state in
            guard let self, !self.isClosed else { return }
            switch state {
            case .ready:
                self.isReady = true
                self.onReady?()
                self.readHeader()
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
        nw.start(queue: queue)
    }

    func send(_ payload: Data, completion: (() -> Void)? = nil) {
        guard !isClosed else { return }
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
        nw.cancel()
        cb?(error)
    }

    private func readHeader() {
        nw.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
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
        nw.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
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

