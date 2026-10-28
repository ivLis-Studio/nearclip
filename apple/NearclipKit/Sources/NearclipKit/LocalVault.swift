import CryptoKit
import Foundation

/// Device-local storage key, independent of the sync group. File names are authenticated as AAD.
final class LocalVault {
    private let key: SymmetricKey
    private let lock = NSRecursiveLock()
    private static let magic = Data("NCV1".utf8)
    init(secrets: SecretStore) throws {
        let account = "local-history-v1"
        if let bytes = secrets.load(account) {
            guard bytes.count == 32 else { throw NearclipError.crypto("invalid local history key") }
            key = SymmetricKey(data: bytes)
        } else {
            let bytes = NCCrypto.random(32)
            try secrets.save(bytes, account: account)
            key = SymmetricKey(data: bytes)
        }
    }
    func read(_ url: URL) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let data = try Data(contentsOf: url)
        if data.starts(with: Self.magic) {
            let box = try AES.GCM.SealedBox(combined: data.dropFirst(4))
            return try AES.GCM.open(box, using: key, authenticating: Data(url.lastPathComponent.utf8))
        }
        // Upgrade only after a successful atomic encrypted write; never discard the old content on failure.
        try write(data, to: url)
        return data
    }
    func write(_ data: Data, to url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        let box = try AES.GCM.seal(data, using: key, authenticating: Data(url.lastPathComponent.utf8))
        try (Self.magic + box.combined!).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
