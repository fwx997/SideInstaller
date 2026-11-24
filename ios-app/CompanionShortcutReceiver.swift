import Foundation
import UIKit

/// Execution remains in SI's process, while the native intent waits in its
/// extension. Each explicit URL selects one request; background files are not
/// a queue that can silently start an installation.
@MainActor
final class CompanionShortcutReceiver {
    static let shared = CompanionShortcutReceiver(
        execute: { try await CompanionShortcutActions.perform($0) },
        refresh: { CompanionShortcutReceiver.refreshCaches() })

    typealias Execute = @MainActor (CompanionShortcutRequest) async throws -> [String: Any]
    private let execute: Execute
    private let refresh: @MainActor () -> Void
    private(set) var operation: Task<Void, Never>?
    private var activeIdentifier: String?
    var isRunning: Bool { operation != nil }

    init(execute: @escaping Execute, refresh: @escaping @MainActor () -> Void) {
        self.execute = execute
        self.refresh = refresh
    }

    /// Returns true for the RPC URL even when its payload is rejected, so it
    /// does not also become a normal install/deep-link popup.
    @discardableResult
    func receive(_ url: URL) -> Bool {
        guard Engine.isBuiltInCompanion, url.scheme?.lowercased() == "sideinstaller",
              url.host?.lowercased() == "shortcut" else { return false }
        do {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard items.count == 1, items[0].name == "request", let identifier = items[0].value else {
                throw CompanionShortcutFailure("快捷指令启动链接无效。")
            }
            let (root, host) = try Self.configuration()
            let request = try CompanionShortcutRequest(root: root, hostBundleID: host, identifier: identifier)
            try accept(request)
        } catch {
            Engine.shared.log("⛔️ SI shortcut: \(Self.message(error))")
        }
        return true
    }

    func accept(_ request: CompanionShortcutRequest) throws {
        guard activeIdentifier != request.identifier, !request.hasResponse else { return }
        try request.checkLive()
        guard operation == nil else {
            request.discardInput()
            try request.reply(["error": "SideInstaller 正在执行另一项快捷指令，请等待完成后重试。"])
            return
        }
        guard try request.claim() else {
            request.discardInput()
            try request.reply(["error": "这项快捷指令先前的执行已中断，请重新运行。"])
            return
        }
        activeIdentifier = request.identifier
        let execute = self.execute
        operation = Task { @MainActor in
            defer { operation = nil; activeIdentifier = nil }
            let work = Task { @MainActor in try await execute(request) }
            let watcher = Task { @MainActor in await Self.monitor(request) { work.cancel() } }
            defer { watcher.cancel() }
            let result = Self.validate(await work.result, request: request)
            // The extension removes the request directory as soon as it reads
            // a response, including the files it originally handed over.
            request.discardInput()
            refresh()
            let response = Self.response(result)
            do { try request.reply(response) }
            catch { Engine.shared.log("⛔️ SI shortcut reply: \(Self.message(error))") }
        }
    }

    private static func monitor(_ request: CompanionShortcutRequest, cancel: () -> Void) async {
        do {
            while !Task.isCancelled {
                try request.checkLive()
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        } catch { cancel() }
    }

    static func response(_ result: Result<[String: Any], Error>) -> [String: Any] {
        switch result {
        case .success(let value): return value
        case .failure(let error): return ["error": message(error)]
        }
    }

    private static func validate(_ result: Result<[String: Any], Error>, request: CompanionShortcutRequest) -> Result<[String: Any], Error> {
        guard case .success = result else { return result }
        do { try request.checkLive(); return result }
        catch { return .failure(error) }
    }

    private static func message(_ error: Error) -> String {
        if error is CancellationError { return "快捷指令已停止。" }
        if let error = error as? ShortcutError { return error.message }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func configuration() throws -> (root: URL, host: String) {
        guard Engine.isBuiltInCompanion, let host = Engine.companionHostBundle?.bundleIdentifier,
              !host.isEmpty, host != ".", host != "..", !host.contains("/"), !host.contains("\\"),
              let group = sharedGroup() else {
            throw CompanionShortcutFailure("此动作需要完整三合一安装包及其共享目录。")
        }
        let root = group.resolvingSymlinksInPath().appendingPathComponent("LiveContainer/SideInstallerShortcuts", isDirectory: true)
            .appendingPathComponent(host, isDirectory: true)
        guard root.resolvingSymlinksInPath().path == root.path else {
            throw CompanionShortcutFailure("快捷指令共享目录无效。")
        }
        return (root, host)
    }

    private static func sharedGroup() -> URL? {
        let selector = NSSelectorFromString("lcAppGroupPath")
        let defaults = UserDefaults.self as AnyObject
        if defaults.responds(to: selector),
           let path = defaults.perform(selector)?.takeUnretainedValue() as? String, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let groups = Engine.companionHostBundle?.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
        return groups.lazy.compactMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }.first
    }

    static func refreshCaches() {
        guard Engine.isBuiltInCompanion else { return }
        do {
            let (root, _) = try configuration()
            let cache = root.appendingPathComponent("caches", isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try CompanionShortcutRequest.write(["value": CompanionShortcutActions.savedPlaces(),
                                                "updatedAt": Date().timeIntervalSince1970],
                                               to: cache.appendingPathComponent("SavedPlaceQuery.json"))
            try CompanionShortcutRequest.write(["value": CompanionShortcutActions.sideloadedApps(),
                                                "updatedAt": Date().timeIntervalSince1970],
                                               to: cache.appendingPathComponent("SideloadedAppQuery.json"))
            pruneExpired(root: root, excluding: shared.activeIdentifier)
        } catch {
            Engine.shared.log("SI shortcut cache: \(message(error))")
        }
    }

    private static func pruneExpired(root: URL, excluding active: String?) {
        let requests = root.appendingPathComponent("requests", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(at: requests, includingPropertiesForKeys: nil)) ?? []
        for folder in folders.prefix(64) {
            guard folder.lastPathComponent != active, UUID(uuidString: folder.lastPathComponent) != nil,
                  folder.resolvingSymlinksInPath().path == folder.path,
                  let request = try? CompanionShortcutRequest.read(folder.appendingPathComponent("request.json")),
                  let expires = CompanionShortcutRequest.number(request["expiresAt"]),
                  expires < Date().timeIntervalSince1970 - 60 else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
