import Foundation
import Security

/// Signing identities belong to the account, not to an installation of the
/// app. Keep them on this device through an uninstall, without iCloud sync.
struct SigningKeyPersistence {
    struct Vault {
        var read: (String) throws -> Data?
        var write: (String, Data) throws -> Void
    }

    struct Failure: Error {
        let status: OSStatus
    }

    let root: URL
    let vault: Vault

    func restore(_ relative: String) throws {
        let (account, file) = try location(relative)
        if FileManager.default.fileExists(atPath: file.path) { return }
        guard let data = try vault.read(account) else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func preserve(_ relative: String) throws {
        let (account, file) = try location(relative)
        let data = try Data(contentsOf: file)
        guard !data.isEmpty, data.count <= 16384 else { throw Failure(status: errSecDecode) }
        if try vault.read(account) == data { return }
        try vault.write(account, data)
    }

    private func location(_ relative: String) throws -> (String, URL) {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1] == "key", parts[0].utf8.count == 64,
              parts[0].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw Failure(status: errSecParam)
        }
        return (String(parts[0]), root.appendingPathComponent(relative))
    }
}

private enum DeviceSigningKeys {
    static let lock = NSLock()
    static let service = "com.frizzlem.sideinstaller.signing-keys.v1"

    static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    static func read(_ account: String) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SigningKeyPersistence.Failure(status: status == errSecSuccess ? errSecDecode : status)
        }
        return data
    }

    static func write(_ account: String, _ data: Data) throws {
        var item = query(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let values: [String: Any] = [kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            status = SecItemUpdate(query(account) as CFDictionary, values as CFDictionary)
        }
        guard status == errSecSuccess else { throw SigningKeyPersistence.Failure(status: status) }
    }
}

/// Called by FsStorage only for a validated account's signing key. The
/// temporary folders used by Side by Side remain temporary and are excluded.
@_cdecl("si_signing_key_sync")
func signingKeySync(_ storage: UnsafePointer<CChar>?, _ key: UnsafePointer<CChar>?, _ mode: Int32) -> Int32 {
    guard let storage, let key else { return errSecParam }
    let root = URL(fileURLWithPath: String(cString: storage)).standardizedFileURL
    guard root.path == PrivateStore.isideload.standardizedFileURL.path else { return errSecSuccess }
    DeviceSigningKeys.lock.lock()
    defer { DeviceSigningKeys.lock.unlock() }
    let store = SigningKeyPersistence(root: root,
        vault: .init(read: DeviceSigningKeys.read, write: DeviceSigningKeys.write))
    do {
        switch mode {
        case 1: try store.restore(String(cString: key))
        case 2: try store.preserve(String(cString: key))
        default: return errSecParam
        }
        return errSecSuccess
    } catch let failure as SigningKeyPersistence.Failure {
        return failure.status
    } catch {
        return errSecIO
    }
}
