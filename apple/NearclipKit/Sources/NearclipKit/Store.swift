import Foundation
import Security

/// Where the group key lives. Apps use the Keychain, the CLI a file.
public protocol SecretStore: AnyObject {
    func load(_ account: String) -> Data?
    func loadChecked(_ account: String) throws -> Data?
    func save(_ data: Data, account: String) throws
    func delete(_ account: String)
}

public extension SecretStore {
    func loadChecked(_ account: String) throws -> Data? { load(account) }
}

public final class FileSecretStore: SecretStore {
    let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(_ account: String) -> URL { directory.appendingPathComponent(account + ".secret") }

    public func load(_ account: String) -> Data? { try? Data(contentsOf: url(account)) }

    public func save(_ data: Data, account: String) throws {
        let u = url(account)
        try data.write(to: u, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path)
    }

    public func delete(_ account: String) { try? FileManager.default.removeItem(at: url(account)) }
}

public final class KeychainSecretStore: SecretStore {
    let service: String

    public init(service: String = "studio.ivlis.nearclip") { self.service = service }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load(_ account: String) -> Data? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    public func loadChecked(_ account: String) throws -> Data? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw NearclipError.io("keychain \(status)") }
        return data
    }

    public func save(_ data: Data, account: String) throws {
        // Updating in place preserves the previous key if the Keychain is temporarily unavailable.
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updated = SecItemUpdate(base(account) as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw NearclipError.io("keychain \(updated)") }
        var q = base(account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw NearclipError.io("keychain \(status)") }
    }

    public func delete(_ account: String) { SecItemDelete(base(account) as CFDictionary) }
}

struct PersistedState: Codable {
    var deviceId: String
    var deviceName: String
    var groupId: String
    var joinedAt: Int64
    var members: [MemberRecord]
    var endpoints: [String: [Endpoint]]
    var lastSeen: [String: Int64]
    var tombstones: [String: Int64]
    var newestLocalTs: Int64?
    var policies: [String: SyncPolicy]?
}

private struct PersistedHistory: Codable { var clips: [StoredClip] }

/// Persistent node state. Only touched on the node queue; writes happen on a background queue.
final class NodeStore {
    let directory: URL
    let blobs: URL
    private let vault: LocalVault
    private let cache: URL
    private let cacheLock = NSLock()
    var state: PersistedState
    var members: [String: MemberRecord]
    private(set) var history: [StoredClip] = []
    private var ids = Set<String>()
    var retentionDays = 30
    var maxItems = 1000
    private let io = DispatchQueue(label: "studio.ivlis.nearclip.store", qos: .utility)
    private var saveScheduled = false
    private let owner: DispatchQueue
    static let inlineTextLimit = 256 * 1024

    init(directory: URL, defaultName: String, owner: DispatchQueue, secrets: SecretStore) throws {
        vault = try LocalVault(secrets: secrets)
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("nearclip-preview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.directory = directory
        self.blobs = directory.appendingPathComponent("blobs", isDirectory: true)
        self.owner = owner
        try? FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let dec = JSONDecoder()
        for name in ["state.json", "history.json"] {
            let u = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: u.path) { _ = try vault.read(u) }
        }
        for u in (try? FileManager.default.contentsOfDirectory(at: blobs, includingPropertiesForKeys: nil)) ?? [] {
            if ["bin", "txt"].contains(u.pathExtension) { _ = try vault.read(u) }
        }
        if let d = try? vault.read(directory.appendingPathComponent("state.json")),
           let s = try? dec.decode(PersistedState.self, from: d) {
            state = s
        } else {
            state = PersistedState(deviceId: newNearclipId(), deviceName: defaultName, groupId: newNearclipId(),
                                   joinedAt: nowMs(), members: [], endpoints: [:], lastSeen: [:], tombstones: [:])
        }
        members = Dictionary(state.members.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b })
        if let d = try? vault.read(directory.appendingPathComponent("history.json")),
           let h = try? dec.decode(PersistedHistory.self, from: d) {
            var loaded: [StoredClip] = []
            for var c in h.clips {
                if c.textFile == true {
                    guard let bytes = try? vault.read(textURL(c.id)), let t = String(data: bytes, encoding: .utf8) else { continue }
                    c.clip.text = t
                }
                loaded.append(c)
            }
            history = loaded.sorted { $0.clip.ts > $1.clip.ts }
            ids = Set(history.map(\.id))
        }
    }

    func blobURL(_ id: String) -> URL { blobs.appendingPathComponent(id + ".bin") }
    func textURL(_ id: String) -> URL { blobs.appendingPathComponent(id + ".txt") }
    func blobData(_ id: String) -> Data? { try? vault.read(blobURL(id)) }
    func previewURL(_ id: String) -> URL {
        cacheLock.lock(); defer { cacheLock.unlock() }
        let url = cache.appendingPathComponent(id + ".bin")
        if !FileManager.default.fileExists(atPath: url.path), let data = blobData(id) {
            try? data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return url
    }
    deinit { try? FileManager.default.removeItem(at: cache) }

    func has(_ id: String) -> Bool { ids.contains(id) }
    func clip(_ id: String) -> StoredClip? { history.first { $0.id == id } }

    func add(_ clip: StoredClip, blob: Data?) {
        guard !ids.contains(clip.id) else { return }
        if let blob { try? vault.write(blob, to: blobURL(clip.id)) }
        let idx = history.firstIndex { $0.clip.ts < clip.clip.ts } ?? history.count
        history.insert(clip, at: idx)
        ids.insert(clip.id)
        saveSoon()
    }

    @discardableResult
    func remove(_ id: String) -> Bool {
        guard ids.contains(id) else { return false }
        history.removeAll { $0.id == id }
        ids.remove(id)
        try? FileManager.default.removeItem(at: blobURL(id))
        try? FileManager.default.removeItem(at: textURL(id))
        cacheLock.lock()
        try? FileManager.default.removeItem(at: cache.appendingPathComponent(id + ".bin"))
        cacheLock.unlock()
        saveSoon()
        return true
    }

    func setPinned(_ id: String, _ pinned: Bool) -> StoredClip? {
        guard let i = history.firstIndex(where: { $0.id == id }) else { return nil }
        history[i].pinned = pinned
        saveSoon()
        return history[i]
    }

    /// Applies retention and the item cap to unpinned clips. Returns removed ids (local only, no tombstones).
    func prune(now: Int64 = nowMs()) -> [String] {
        var drop = Set<String>()
        if retentionDays > 0 {
            let cutoff = now - Int64(retentionDays) * 86_400_000
            for c in history where !c.pinned && c.clip.ts < cutoff { drop.insert(c.id) }
        }
        let unpinned = history.filter { !$0.pinned && !drop.contains($0.id) }
        if unpinned.count > maxItems { for c in unpinned.suffix(unpinned.count - maxItems) { drop.insert(c.id) } }
        for id in drop { remove(id) }
        let tombCutoff = now - 30 * 86_400_000
        let before = state.tombstones.count
        state.tombstones = state.tombstones.filter { $0.value >= tombCutoff }
        if before != state.tombstones.count { saveSoon() }
        return Array(drop)
    }

    func saveSoon() {
        guard !saveScheduled else { return }
        saveScheduled = true
        owner.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            self.writeSnapshot(sync: false)
        }
    }

    func saveNow() { writeSnapshot(sync: true) }

    private func writeSnapshot(sync: Bool) {
        var s = state
        s.members = Array(members.values).sorted { $0.addedAt < $1.addedAt }
        var clips: [StoredClip] = []
        var sideTexts: [(URL, String)] = []
        for var c in history {
            if let t = c.clip.text, t.utf8.count > Self.inlineTextLimit {
                sideTexts.append((textURL(c.id), t))
                c.clip.text = nil
                c.textFile = true
            }
            clips.append(c)
        }
        let dir = directory
        let vault = self.vault
        let work = {
            let enc = JSONEncoder()
            for (url, text) in sideTexts where !FileManager.default.fileExists(atPath: url.path) {
                try? vault.write(Data(text.utf8), to: url)
            }
            if let d = try? enc.encode(s) { try? vault.write(d, to: dir.appendingPathComponent("state.json")) }
            if let d = try? enc.encode(PersistedHistory(clips: clips)) { try? vault.write(d, to: dir.appendingPathComponent("history.json")) }
        }
        if sync { io.sync(execute: work) } else { io.async(execute: work) }
    }
}

