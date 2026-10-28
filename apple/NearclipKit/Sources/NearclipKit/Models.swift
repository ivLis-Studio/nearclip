import Foundation

public func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }
public func newNearclipId() -> String { UUID().uuidString.lowercased() }

public struct Endpoint: Codable, Hashable, Sendable {
    public var h: String
    public var p: Int
    public init(h: String, p: Int) { self.h = h; self.p = p }
}

/// A member of the group (PROTOCOL.md §1.1).
public struct MemberRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var platform: String
    public var model: String?
    public var app: String?
    public var addedAt: Int64
    public var updatedAt: Int64
    public var removed: Bool

    public init(id: String, name: String, platform: String, model: String? = nil, app: String? = nil,
                addedAt: Int64, updatedAt: Int64, removed: Bool = false) {
        self.id = id; self.name = name; self.platform = platform; self.model = model; self.app = app
        self.addedAt = addedAt; self.updatedAt = updatedAt; self.removed = removed
    }

    enum CodingKeys: String, CodingKey { case id, name, platform, model, app, addedAt, updatedAt, removed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id).lowercased()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model)
        app = try c.decodeIfPresent(String.self, forKey: .app)
        addedAt = try c.decodeIfPresent(Int64.self, forKey: .addedAt) ?? 0
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
        removed = try c.decodeIfPresent(Bool.self, forKey: .removed) ?? false
    }
}

/// Wire form of a clip (PROTOCOL.md §6.1). `otp`: a verification code a phone found in a message (§6.7), offered
/// rather than copied by the devices that receive it.
public struct Clip: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var ts: Int64
    public var src: String
    public var kind: String
    public var text: String?
    public var mime: String?
    public var size: Int?
    public var sha: String?
    public var w: Int?
    public var h: Int?
    public var otp: Bool?
    public var recipients: [String]?

    public init(id: String, ts: Int64, src: String, kind: String, text: String? = nil, mime: String? = nil,
                size: Int? = nil, sha: String? = nil, w: Int? = nil, h: Int? = nil, otp: Bool? = nil, recipients: [String]? = nil) {
        self.id = id; self.ts = ts; self.src = src; self.kind = kind; self.text = text; self.mime = mime
        self.size = size; self.sha = sha; self.w = w; self.h = h; self.otp = otp; self.recipients = recipients
    }

    public var isImage: Bool { kind == "image" }
    public var isText: Bool { kind == "text" }
    public var isCode: Bool { otp == true && isText }
}

/// A clip in local history.
public struct StoredClip: Codable, Hashable, Identifiable, Sendable {
    public var clip: Clip
    public var groupId: String
    public var pinned: Bool
    public var receivedAt: Int64
    /// Name of the origin device when the clip arrived (members may later be removed or renamed).
    public var srcName: String?
    public var srcPlatform: String?
    /// Large texts are kept in a side file on disk (in memory the text is always present).
    var textFile: Bool?

    public var id: String { clip.id }
}

public struct NearbyDevice: Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var platform: String
    public var pairingMode: Bool
}

public struct PairPrompt: Hashable, Sendable {
    public var peerId: String
    public var name: String
    public var platform: String
    public var code: String
}

/// `nearclip://pair?…` (PROTOCOL.md §5.1).
public struct PairingInvite: Hashable, Sendable {
    public var inviterId: String
    public var name: String
    public var platform: String
    public var hosts: [String]
    public var port: UInt16
    public var secret: Data

    public init(inviterId: String, name: String, platform: String, hosts: [String], port: UInt16, secret: Data) {
        self.inviterId = inviterId; self.name = name; self.platform = platform
        self.hosts = hosts; self.port = port; self.secret = secret
    }

    public init?(uri: String) {
        guard let comps = URLComponents(string: uri.trimmingCharacters(in: .whitespacesAndNewlines)),
              comps.scheme?.lowercased() == "nearclip", comps.host?.lowercased() == "pair" else { return nil }
        var q: [String: String] = [:]
        for item in comps.queryItems ?? [] { q[item.name] = item.value ?? "" }
        guard q["v"] == "1", let id = q["id"], !id.isEmpty, let p = q["p"].flatMap(UInt16.init), p > 0,
              let s = q["s"].flatMap(Base64URL.decode), s.count >= 16 else { return nil }
        inviterId = id.lowercased()
        name = q["nm"] ?? ""
        platform = q["pf"] ?? ""
        hosts = (q["h"] ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        port = p
        secret = s
    }

    public var uri: String {
        var c = URLComponents()
        c.scheme = "nearclip"
        c.host = "pair"
        c.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "id", value: inviterId),
            URLQueryItem(name: "nm", value: name),
            URLQueryItem(name: "pf", value: platform),
            URLQueryItem(name: "h", value: hosts.joined(separator: ",")),
            URLQueryItem(name: "p", value: String(port)),
            URLQueryItem(name: "s", value: Base64URL.encode(secret)),
        ]
        // URLComponents leaves "+" alone in queries; encode it so other platforms never read it as a space.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.string ?? ""
    }
}

public struct PairingTicket: Hashable, Sendable {
    public var invite: PairingInvite
    public var expiresAt: Date
    public var uri: String { invite.uri }
}

/// A live image arriving from another device (PROTOCOL.md §6.6), for progress UI. A transfer ends with the clip's
/// `clipAdded` event, or with `state == .failed`.
public struct IncomingTransfer: Hashable, Sendable {
    public enum State: String, Sendable {
        /// Announced: the other device is still encoding the image (`total` is 0).
        case preparing
        case receiving
        /// Ended without the clip: `reason` is cancelled, disconnected, corrupt or timeout.
        case failed
    }

    /// Id of the clip being transferred.
    public var id: String
    /// The device the image was copied on.
    public var from: String
    public var state: State
    public var received: Int
    public var total: Int
    public var reason: String?

    public init(id: String, from: String, state: State, received: Int, total: Int, reason: String? = nil) {
        self.id = id; self.from = from; self.state = state; self.received = received; self.total = total; self.reason = reason
    }

    /// 0…1, or nil while the size is unknown.
    public var fraction: Double? { total > 0 ? min(1, Double(received) / Double(total)) : nil }
}

public enum NodeEvent: Sendable {
    case ready(port: UInt16, groupId: String, groupTag: String)
    case ticket(PairingTicket)
    case ticketExpired
    /// Joiner side of code pairing: show this code and wait.
    case pairCode(code: String, peerName: String)
    /// Inviter side of code pairing: ask the user.
    case pairPrompt(PairPrompt)
    case pairPromptDismissed
    case paired(groupId: String, peerId: String, peerName: String, joined: Bool)
    case pairFailed(reason: String)
    case peerUp(MemberRecord, PeerRoute)
    case peerDown(String)
    /// `local`: produced on this device. `apply`: a live clip from another device that should go to the system clipboard.
    case clipAdded(StoredClip, live: Bool, apply: Bool, local: Bool)
    /// Progress of a live image from another device (PROTOCOL.md §6.6).
    case transfer(IncomingTransfer)
    case clipsDeleted([String])
    case clipUpdated(StoredClip)
    case membersChanged([MemberRecord])
    case nearbyChanged([NearbyDevice])
    case left(reason: String)
    case tooLarge(kind: String)
    /// The embedded Tailscale node changed state (remote connection).
    case tailnetChanged(TailnetStatus)
    case log(String)
}

public struct NodeSnapshot: Sendable {
    public var deviceId: String
    public var deviceName: String
    public var platform: String
    public var groupId: String
    public var members: [MemberRecord]
    public var online: Set<String>
    public var lastSeen: [String: Int64]
    public var history: [StoredClip]
    public var nearby: [NearbyDevice]
    public var port: UInt16
    public var paused: Bool
    public var addresses: [String]
    /// Route of every connected member.
    public var routes: [String: PeerRoute]
    public var remoteEnabled: Bool
    public var tailnet: TailnetStatus
}

