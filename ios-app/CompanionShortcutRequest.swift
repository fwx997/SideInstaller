import CoreFoundation
import Darwin
import Foundation

struct CompanionShortcutFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A request is usable only inside this physical host's mailbox, with a live
/// client. Reading the directory never schedules an action by itself.
struct CompanionShortcutRequest {
    static let actions: Set<String> = [
        "GetSideloadedAppsIntent", "RefreshAllAppsIntent", "RefreshAppIntent",
        "InstallAppIntent", "InstallIPAIntent", "InstallIPAFromURLIntent",
        "IsTunnelConnectedIntent", "ConnectLocalDevVPNIntent", "GetPairingFileIntent",
        "ImportPairingFileIntent", "InstallPairingIntoAppsIntent", "ShowDeveloperModeIntent",
        "GetActivityLogIntent", "SetLocationIntent", "SetCoordinatesIntent",
        "SetSavedPlaceIntent", "ResetLocationIntent", "GetSpoofedLocationIntent",
        "IsLocationSpoofedIntent", "SavePlaceIntent", "DeleteSavedPlaceIntent",
        "PlayGPXRouteIntent", "TravelToPlaceIntent", "StopRouteIntent",
    ]

    let identifier: String
    let hostBundleID: String
    let action: String
    let parameters: [String: Any]
    let folder: URL
    let expiresAt: Date

    init(root: URL, hostBundleID: String, identifier: String, now: Date = Date()) throws {
        guard UUID(uuidString: identifier)?.uuidString == identifier else {
            throw CompanionShortcutFailure("快捷指令请求编号无效。")
        }
        let candidate = root.resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent("requests", isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
        guard candidate.resolvingSymlinksInPath().path == candidate.path else {
            throw CompanionShortcutFailure("快捷指令请求目录无效。")
        }
        let request = try Self.read(candidate.appendingPathComponent("request.json"))
        guard Self.number(request["version"]) == 1, request["id"] as? String == identifier,
              request["hostBundleID"] as? String == hostBundleID,
              let action = request["action"] as? String, Self.actions.contains(action),
              let parameters = request["parameters"] as? [String: Any],
              let created = Self.number(request["createdAt"]),
              let expires = Self.number(request["expiresAt"]),
              created <= now.timeIntervalSince1970 + 5, expires > now.timeIntervalSince1970,
              expires > created, expires - created <= 600.1 else {
            throw CompanionShortcutFailure("快捷指令请求已过期或不属于当前三合一应用。")
        }
        self.identifier = identifier
        self.hostBundleID = hostBundleID
        self.action = action
        self.parameters = parameters
        folder = candidate
        expiresAt = Date(timeIntervalSince1970: expires)
        try checkLive(now: now)
    }

    func checkLive(now: Date = Date()) throws {
        guard now < expiresAt else { throw CompanionShortcutFailure("快捷指令执行超时。") }
        guard !FileManager.default.fileExists(atPath: folder.appendingPathComponent("cancelled").path) else {
            throw CancellationError()
        }
        let heartbeat = folder.appendingPathComponent("heartbeat")
        let attributes = try? FileManager.default.attributesOfItem(atPath: heartbeat.path)
        guard heartbeat.resolvingSymlinksInPath().path == heartbeat.path,
              let modified = attributes?[.modificationDate] as? Date,
              now.timeIntervalSince(modified) <= 15, modified.timeIntervalSince(now) <= 5 else {
            throw CompanionShortcutFailure("快捷指令已停止等待，SI 已取消这次请求。")
        }
    }

    /// O_EXCL prevents duplicate URL delivery or another process replaying work.
    func claim() throws -> Bool {
        let path = folder.appendingPathComponent("started").path
        let descriptor = Darwin.open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, mode_t(0o600))
        if descriptor < 0, errno == EEXIST { return false }
        guard descriptor >= 0 else {
            throw CompanionShortcutFailure("无法接收快捷指令请求（错误 \(errno)）。")
        }
        Darwin.close(descriptor)
        return true
    }

    var hasResponse: Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("response.json").path)
    }

    func reply(_ result: [String: Any]) throws {
        var response = result
        response["version"] = 1
        response["id"] = identifier
        response["hostBundleID"] = hostBundleID
        if response["value"] == nil { response["value"] = NSNull() }
        try Self.write(response, to: folder.appendingPathComponent("response.json"))
    }

    func inputFile() throws -> (url: URL, name: String) {
        guard let file = parameters["file"] as? [String: Any],
              let path = file["relativePath"] as? String, let name = file["filename"] as? String,
              !path.contains("\\"), !path.hasPrefix("/"), !path.contains(":") else {
            throw CompanionShortcutFailure("快捷指令没有提供有效文件。")
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "input", !parts[1].isEmpty,
              parts[1] != ".", parts[1] != ".." else {
            throw CompanionShortcutFailure("快捷指令文件路径无效。")
        }
        let input = folder.appendingPathComponent(path).standardizedFileURL
        guard input.resolvingSymlinksInPath().path == input.path,
              try input.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CompanionShortcutFailure("快捷指令文件不在本次请求目录中。")
        }
        let filename = (name as NSString).lastPathComponent
        return (input, filename.isEmpty ? input.lastPathComponent : filename)
    }

    /// Imports first make their own temporary copy; no response is published
    /// until the original input has been removed.
    func discardInput() {
        let input = folder.appendingPathComponent("input", isDirectory: true)
        guard input.resolvingSymlinksInPath().path == input.path else { return }
        try? FileManager.default.removeItem(at: input)
    }

    static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    static func read(_ url: URL) throws -> [String: Any] {
        guard url.resolvingSymlinksInPath().path == url.path,
              let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
              size.intValue <= 8 * 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw CompanionShortcutFailure("快捷指令数据格式无效。")
        }
        return object
    }

    static func write(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url, options: .atomic)
    }
}
