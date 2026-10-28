import Foundation

/// A readonly snapshot exported to the iOS extension's shared Keychain. No clipboard history is included.
public struct ShareSeed: Codable, Sendable {
    public var state: Data
    public var groupId: String
    public var groupKey: Data
    public var deviceName: String
    public var members: [MemberRecord]
    public var paused: Bool
    public var images: Bool
}

public final class MemorySecretStore: SecretStore {
    private var values: [String: Data] = [:]
    public init() {}
    public func load(_ account: String) -> Data? { values[account] }
    public func save(_ data: Data, account: String) throws { values[account] = data }
    public func delete(_ account: String) { values[account] = nil }
}

public extension NearclipNode {
    /// The extension owns a separate temporary engine; it never opens the main app's live history files.
    static func shareNode(seed: ShareSeed, directory: URL) throws -> NearclipNode {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try seed.state.write(to: directory.appendingPathComponent("state.json"), options: [.atomic])
        let secrets = MemorySecretStore()
        try secrets.save(seed.groupKey, account: "group-key-" + seed.groupId)
        return try NearclipNode(config: .init(stateDirectory: directory, deviceName: seed.deviceName, platform: "ios",
                                               port: 0, bonjour: true, secretStore: secrets))
    }
}
