import Foundation
import NCTailnet

/// Another Nearclip node in the user's tailnet (PROTOCOL.md §10.2).
public struct TailnetPeer: Codable, Hashable, Sendable {
    public var host: String
    public var idPrefix: String?
    public var ip: String
    public var online: Bool
    public var os: String?
    public var direct: Bool
    public var relay: String?
}

/// Status of the embedded Tailscale node (tailnet/README.md).
public struct TailnetStatus: Codable, Hashable, Sendable {
    /// off, starting, needsLogin, needsApproval, running, stopped, error
    public var state: String
    public var backend: String?
    public var authURL: String?
    public var ip: String?
    public var ip6: String?
    public var hostname: String?
    public var dnsName: String?
    public var account: String?
    public var tailnet: String?
    public var proxyPort: Int?
    public var token: String?
    public var ports: [Int]?
    public var peers: [TailnetPeer]
    public var health: [String]?
    public var error: String?
    public var version: String?

    public init(state: String, peers: [TailnetPeer] = [], error: String? = nil) {
        self.state = state
        self.peers = peers
        self.error = error
    }

    public static let off = TailnetStatus(state: "off")

    public var isRunning: Bool { state == "running" && ip != nil }
    public var needsLogin: Bool { state == "needsLogin" }

    /// What the UI and the engine care about (ignores health chatter).
    func sameEssentials(_ o: TailnetStatus) -> Bool {
        state == o.state && authURL == o.authURL && ip == o.ip && account == o.account && error == o.error
            && proxyPort == o.proxyPort && token == o.token && peers == o.peers
    }
}

/// Options for the embedded node. The node only runs while remote connection is enabled.
public struct TailnetOptions: Sendable {
    public var directory: URL
    public var controlURL: String?
    public var logPath: String?
    /// Test control servers: ephemeral nodes and no interface binding.
    public var testMode: Bool

    public init(directory: URL, controlURL: String? = nil, logPath: String? = nil, testMode: Bool = false) {
        self.directory = directory; self.controlURL = controlURL; self.logPath = logPath; self.testMode = testMode
    }
}

/// Thin wrapper over the C interface of tailnet/capi. Calls block; never call them on the node queue.
enum TailnetBridge {
    private static func decode(_ p: UnsafeMutablePointer<CChar>?) -> TailnetStatus {
        guard let p else { return TailnetStatus(state: "error", error: "no result") }
        defer { NCTailnetFree(p) }
        let data = Data(bytes: p, count: strlen(p))
        return (try? JSONDecoder().decode(TailnetStatus.self, from: data)) ?? TailnetStatus(state: "error", error: "bad status")
    }

    static func start(_ config: [String: Any]) -> TailnetStatus {
        guard let data = try? JSONSerialization.data(withJSONObject: config),
              let json = String(data: data, encoding: .utf8) else { return TailnetStatus(state: "error", error: "bad config") }
        return json.withCString { decode(NCTailnetStart(UnsafeMutablePointer(mutating: $0))) }
    }

    static func status() -> TailnetStatus { decode(NCTailnetStatus()) }
    static func login() -> TailnetStatus { decode(NCTailnetLogin()) }
    static func logout() -> TailnetStatus { decode(NCTailnetLogout()) }
    static func stop() -> TailnetStatus { decode(NCTailnetStop()) }
    static func networkChanged() { NCTailnetNetworkChanged() }
}

/// Tailnet addresses: 100.64.0.0/10 (CGNAT range used by Tailscale) and fd7a:115c:a1e0::/48.
public enum TailnetAddress {
    public static func contains(_ host: String) -> Bool {
        let h = host.lowercased()
        if h.hasPrefix("fd7a:115c:a1e0:") { return true }
        let parts = h.split(separator: ".")
        guard parts.count == 4, let a = Int(parts[0]), let b = Int(parts[1]) else { return false }
        return a == 100 && (64...127).contains(b)
    }
}

/// How a session reaches its peer (PROTOCOL.md §10.3).
public enum PeerRoute: String, Sendable, Hashable {
    case lan
    case remote
}
