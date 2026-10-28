import Foundation

/// Local policy for a particular peer. Defaults preserve bidirectional sync.
public struct SyncPolicy: Codable, Equatable, Sendable {
    public var send = true
    public var receive = true
    public var images = true
    public var codes = true
    public init(send: Bool = true, receive: Bool = true, images: Bool = true, codes: Bool = true) {
        self.send = send; self.receive = receive; self.images = images; self.codes = codes
    }
    public func permits(_ clip: Clip, sending: Bool) -> Bool {
        (sending ? send : receive) && (!clip.isImage || images) && (!clip.isCode || codes)
    }
}

public extension Clip {
    static let codeLifetime: Int64 = 180_000
    func isExpired(at now: Int64 = nowMs()) -> Bool {
        isCode && (ts <= now - Self.codeLifetime || ts > now + 60_000)
    }
}
