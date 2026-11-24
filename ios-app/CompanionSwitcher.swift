import Foundation

/// The host asks immediately before restarting into another built-in app.
/// Keep weak references to the managers owned by RootView, not copied flags.
@MainActor
@objc(SICompanionBridge)
final class SICompanionBridge: NSObject {
    private static weak var pairing: PairingManager?
    private static weak var certificates: CertManager?
    private static weak var entitlements: EntitlementsManager?
    private static weak var location: LocationManager?
    private static weak var apps: SideloadedAppsManager?
    private static weak var sideBySide: SideBySideManager?

    static func bind(pairing: PairingManager, certificates: CertManager,
                     entitlements: EntitlementsManager, location: LocationManager,
                     apps: SideloadedAppsManager, sideBySide: SideBySideManager) {
        self.pairing = pairing
        self.certificates = certificates
        self.entitlements = entitlements
        self.location = location
        self.apps = apps
        self.sideBySide = sideBySide
    }

    @objc static func switchBlockReason() -> String? {
        if CompanionShortcutReceiver.shared.isRunning {
            return "SideInstaller 正在执行快捷指令，请等待完成或停止快捷指令后再切换。"
        }
        let engine = Engine.shared
        if engine.isRunning || engine.isCancelling || engine.isImportingIPA || engine.isImportingPairing {
            return "SideInstaller 正在安装或导入，请完成后再切换。"
        }
        if engine.twoFactor != nil || engine.teamQuestion != nil {
            return "请先完成或取消 Apple ID 登录。"
        }
        if pairing?.isBusy == true || sideBySide?.isRunning == true || sideBySide?.isCancelling == true || sideBySide?.isImportingIPA == true {
            return "正在配对或安装另一台设备，请完成后再切换。"
        }
        if certificates?.isBusy == true || entitlements?.isBusy == true {
            return "正在处理证书或权限，请完成后再切换。"
        }
        if apps?.isWorking == true || apps?.isRefreshing == true {
            return "正在管理或续签应用，请完成后再切换。"
        }
        if location?.isSimulating == true || location?.isPlayingRoute == true {
            return "请先在虚拟定位中停止模拟，再切换应用。"
        }
        if location?.isBusy == true || location?.isPlanningRoute == true || location?.isImportingRoute == true {
            return "正在准备定位或路线，请完成后再切换。"
        }
        return nil
    }
}
