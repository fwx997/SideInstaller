import Foundation
import Darwin

/// SideStore's background process and the embedded installer share this flock.
/// The kernel releases it on process exit; the file itself must never be deleted.
enum CompanionOperationLease {
    static let fileName = "LCCompanionSigning.lock"
    private static let pool = Pool()

    static func acquire() throws -> Token {
        guard Engine.isBuiltInCompanion else { return Token(release: {}) }
        guard let folder = sharedFolder() else { throw Failure.unavailable }
        return try pool.acquire(at: folder.appendingPathComponent(fileName))
    }

    private static func sharedFolder() -> URL? {
        let selector = NSSelectorFromString("lcAppGroupPath")
        let defaults = UserDefaults.self as AnyObject
        if defaults.responds(to: selector),
           let path = defaults.perform(selector)?.takeUnretainedValue() as? String,
           !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let groups = Engine.companionHostBundle?.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
        for group in groups {
            if let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
                return folder
            }
        }
        return nil
    }

    enum Failure: LocalizedError {
        case busy, unavailable, system(Int32)

        var errorDescription: String? {
            switch self {
            case .busy:
                return "SideStore 正在续签或安装，请等待完成后重试。"
            case .unavailable:
                return "无法访问组合包的共享目录，请在 SideStore 中重新签名后重试。"
            case .system(let code):
                return "无法协调组合包的设备连接（错误 \(code)），请稍后重试。"
            }
        }
    }

    final class Token: @unchecked Sendable {
        private let mutex = NSLock()
        private var finish: (() -> Void)?

        fileprivate init(release: @escaping () -> Void) { finish = release }

        func release() {
            mutex.lock()
            let action = finish
            finish = nil
            mutex.unlock()
            action?()
        }

        deinit { release() }
    }

    /// One descriptor per process. Nested tool calls retain the same flock.
    final class Pool: @unchecked Sendable {
        private let mutex = NSLock()
        private var descriptor: Int32 = -1
        private var holders = 0

        func acquire(at url: URL) throws -> Token {
            mutex.lock()
            defer { mutex.unlock() }
            if descriptor == -1 {
                descriptor = try Self.openLocked(url)
            }
            holders += 1
            return Token { [self] in relinquish() }
        }

        private static func openLocked(_ url: URL) throws -> Int32 {
            let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
            guard descriptor >= 0 else { throw Failure.system(errno) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                Darwin.close(descriptor)
                if code == EWOULDBLOCK || code == EAGAIN { throw Failure.busy }
                throw Failure.system(code)
            }
            return descriptor
        }

        private func relinquish() {
            mutex.lock()
            defer { mutex.unlock() }
            holders -= 1
            guard holders == 0 else { return }
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            descriptor = -1
        }
    }
}
