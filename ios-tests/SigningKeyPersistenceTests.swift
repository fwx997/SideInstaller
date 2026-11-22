import Foundation
import Security
import Testing
@testable import SideInstaller

struct SigningKeyPersistenceTests {
    private let account = String(repeating: "a", count: 64)

    @Test func restoresTheSameKeyAfterTheAppDirectoryIsRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var vault: [String: Data] = [:]
        let store = SigningKeyPersistence(root: root,
            vault: .init(read: { vault[$0] }, write: { vault[$0] = $1 }))
        let folder = root.appendingPathComponent(account)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = Data([0x30, 1, 2, 3, 4])
        try original.write(to: folder.appendingPathComponent("key"))
        try store.preserve(account + "/key")
        try FileManager.default.removeItem(at: root)
        try store.restore(account + "/key")
        #expect(try Data(contentsOf: folder.appendingPathComponent("key")) == original)
        #expect(vault.count == 1)
    }

    @Test func doesNotReplaceANewerLocalKeyDuringRestore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SigningKeyPersistence(root: root,
            vault: .init(read: { _ in Data([1]) }, write: { _, _ in }))
        let folder = root.appendingPathComponent(account)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let current = Data([2])
        try current.write(to: folder.appendingPathComponent("key"))
        try store.restore(account + "/key")
        #expect(try Data(contentsOf: folder.appendingPathComponent("key")) == current)
    }

    @Test func lockedKeychainIsAnErrorInsteadOfAnAbsentKey() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SigningKeyPersistence(root: root,
            vault: .init(read: { _ in throw SigningKeyPersistence.Failure(status: errSecInteractionNotAllowed) },
                         write: { _, _ in }))
        #expect(throws: SigningKeyPersistence.Failure.self) { try store.restore(account + "/key") }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func refusesAnAccountPathOutsideItsDirectory() {
        let store = SigningKeyPersistence(root: FileManager.default.temporaryDirectory,
            vault: .init(read: { _ in nil }, write: { _, _ in }))
        #expect(throws: SigningKeyPersistence.Failure.self) { try store.restore("../key") }
        #expect(throws: SigningKeyPersistence.Failure.self) { try store.restore(account + "/token") }
    }
}
