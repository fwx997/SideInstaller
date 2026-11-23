import Foundation

/// The running companion package is renewed and updated by its SideStore.
enum CompanionInstallPolicy {
    enum Failure: LocalizedError {
        case replacesHost
        case unreadableIdentity

        var errorDescription: String? {
            switch self {
            case .replacesHost:
                return "请在 SideStore 中续签或更新当前组合包。内置 SideInstaller 不能覆盖正在运行的组合包。"
            case .unreadableIdentity:
                return "无法核对安装包标识，已停止安装。请重新导入 IPA，或在 SideStore 中更新组合包。"
            }
        }
    }

    static func validateTarget(_ packageID: String, signingTeam: String? = nil,
                               hostIdentifier: String) throws {
        let target: String
        if let team = signingTeam, !team.isEmpty, !packageID.hasSuffix(".\(team)") {
            target = "\(packageID).\(team)"
        } else {
            target = packageID
        }
        guard target != hostIdentifier else { throw Failure.replacesHost }
    }

    static func validateSignedBundle(at path: String, hostIdentifier: String) throws {
        let url = URL(fileURLWithPath: path).appendingPathComponent("Info.plist")
        guard let bytes = try? Data(contentsOf: url),
              let fields = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              let identifier = fields["CFBundleIdentifier"] as? String, !identifier.isEmpty else {
            throw Failure.unreadableIdentity
        }
        try validateTarget(identifier, hostIdentifier: hostIdentifier)
    }
}
