import CoreLocation
import Foundation

/// The native extension's fields are translated into the same shared managers
/// and async operations that SI's pages and upstream AppIntents use.
@MainActor
enum CompanionShortcutActions {
    static func perform(_ request: CompanionShortcutRequest) async throws -> [String: Any] {
        try Task.checkCancellation()
        while !Shortcuts.isInForeground {
            try request.checkLive()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let result = try await Shortcuts.run(request.action) {
            try await dispatch(request)
        }
        try Task.checkCancellation()
        return result
    }

    private static func dispatch(_ request: CompanionShortcutRequest) async throws -> [String: Any] {
        let parameters = request.parameters
        switch request.action {
        case "GetSideloadedAppsIntent":
            try await ensureTunnel()
            try await SideloadedAppsManager.shared.loadForShortcut()
            return answer(sideloadedApps())
        case "RefreshAllAppsIntent":
            return try await refreshApps(nil)
        case "RefreshAppIntent":
            return try await refreshApps([try string(parameters["app"])])
        case "InstallAppIntent":
            return try await installApp(parameters)
        case "InstallIPAIntent":
            return try await installIPA(request)
        case "InstallIPAFromURLIntent":
            return try await installURL(parameters)
        case "IsTunnelConnectedIntent":
            await Engine.shared.settleNetworkStatus()
            return answer(Engine.shared.vpnConnected)
        case "ConnectLocalDevVPNIntent":
            return try await connectVPN()
        case "GetPairingFileIntent":
            return try exportPairing()
        case "ImportPairingFileIntent":
            let copy = try temporaryInput(request, defaultName: "pairingFile.plist")
            defer { Shortcuts.discard(copy) }
            try Engine.shared.importPairingFile(data: Data(contentsOf: copy), name: copy.lastPathComponent)
            return answer()
        case "InstallPairingIntoAppsIntent":
            return try await installPairing()
        case "ShowDeveloperModeIntent":
            return try await revealDeveloperMode()
        case "GetActivityLogIntent":
            return answer(LogStore.shared.text)
        case "SetLocationIntent":
            return try await setLocation(object(parameters["place"]))
        case "SetCoordinatesIntent":
            return try await setLocation(parameters)
        case "SetSavedPlaceIntent":
            let chosen = try savedPlace(object(parameters["place"]))
            try await ensureTunnel()
            try await LocationManager.shared.setLocation(chosen.coordinate)
            return answer(place(chosen), dialog: L("Location set to %@.", chosen.name))
        case "ResetLocationIntent":
            try await LocationManager.shared.resetLocation()
            return answer(dialog: L("Location reset. The device is using its own again."))
        case "GetSpoofedLocationIntent":
            return await spoofedLocation()
        case "IsLocationSpoofedIntent":
            return answer(LocationManager.shared.isSimulating)
        case "SavePlaceIntent":
            let location = try object(parameters["place"])
            let coordinate = try coordinate(location)
            let name = try optionalString(parameters["name"]) ?? optionalString(location["name"]) ?? ""
            return answer(place(LocationManager.shared.savePlace(named: name, at: coordinate)))
        case "DeleteSavedPlaceIntent":
            let identifier = try uuid(parameters["place"])
            if let saved = LocationManager.shared.savedPlaces.first(where: { $0.id == identifier }) {
                LocationManager.shared.deletePlace(saved)
            }
            return answer()
        case "PlayGPXRouteIntent":
            return try await playGPX(request)
        case "TravelToPlaceIntent":
            return try await travel(parameters)
        case "StopRouteIntent":
            let stopped = LocationManager.shared.stopRouteForShortcut()
            return answer(dialog: stopped ? L("Route stopped. The device stays where it got to.") : L("No route is playing."))
        default:
            throw CompanionShortcutFailure("SideInstaller 不支持这项快捷指令。")
        }
    }

    private static func answer(_ value: Any = NSNull(), dialog: String? = nil) -> [String: Any] {
        var result: [String: Any] = ["value": value]
        if let dialog { result["dialog"] = dialog }
        return result
    }

    private static func ensureTunnel() async throws {
        let engine = Engine.shared
        await engine.settleNetworkStatus()
        guard !engine.vpnConnected else { return }
        guard engine.startsVPNWhenNeeded else {
            throw ShortcutError(ErrorHelp.explained(L("LocalDevVPN isn't connected. Connect it before this action runs: Shortcuts' Set VPN action can, or turn on “Start LocalDevVPN when needed” in SideInstaller's Settings.")))
        }
        guard await engine.tunnelUp() else {
            try Task.checkCancellation()
            throw ShortcutError(L("LocalDevVPN isn't connected. Connect it, then try again."))
        }
    }

    private static func refreshApps(_ identifiers: Set<String>?) async throws -> [String: Any] {
        try await ensureTunnel()
        let outcome = try await SideloadedAppsManager.shared.refreshForShortcut(identifiers)
        let report = try Shortcuts.report(outcome)
        return answer(report, dialog: report)
    }

    private static func installApp(_ parameters: [String: Any]) async throws -> [String: Any] {
        guard let app = InstallableApp(rawValue: try string(parameters["app"])),
              let release = ReleaseTrack(rawValue: try string(parameters["release"])) else {
            throw CompanionShortcutFailure("快捷指令的应用或版本选项无效。")
        }
        try Shortcuts.requireNoInstall()
        let engine = Engine.shared
        engine.installSource = app.source
        await engine.checkStableRelease(for: app.source)
        engine.releaseChannel = release.channel
        return answer(dialog: try await Shortcuts.install(named: app.source.displayName))
    }

    private static func installIPA(_ request: CompanionShortcutRequest) async throws -> [String: Any] {
        try Shortcuts.requireNoInstall()
        let copy = try temporaryInput(request, defaultName: "App.ipa")
        defer { Shortcuts.discard(copy) }
        let engine = Engine.shared
        engine.installSource = .custom
        engine.lastError = nil
        await engine.importCustomIPA(from: copy)
        if let error = engine.lastError { throw ShortcutError(error) }
        return answer(dialog: try await Shortcuts.install(named: engine.customIPAName ?? copy.lastPathComponent))
    }

    private static func installURL(_ parameters: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: try string(parameters["url"])),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw CompanionShortcutFailure("快捷指令需要有效的 IPA 下载链接。")
        }
        try Shortcuts.requireNoInstall()
        let engine = Engine.shared
        engine.installSource = .custom
        engine.lastError = nil
        guard await engine.importCustomIPA(fromLink: url.absoluteString) else {
            throw ShortcutError(engine.lastError ?? L("The install didn't start. Open SideInstaller to see why."))
        }
        return answer(dialog: try await Shortcuts.install(named: engine.customIPAName ?? url.lastPathComponent))
    }

    private static func connectVPN() async throws -> [String: Any] {
        let engine = Engine.shared
        await engine.settleNetworkStatus()
        if !engine.vpnConnected {
            guard await engine.startLocalDevVPN() else {
                throw ShortcutError(L("Install LocalDevVPN from the App Store and open it."))
            }
            var foregroundWait: TimeInterval = 0
            while foregroundWait < 15 {
                try await Task.sleep(nanoseconds: 500_000_000)
                engine.refreshNetworkStatus()
                if engine.vpnConnected && Shortcuts.isInForeground { break }
                if Shortcuts.isInForeground { foregroundWait += 0.5 }
            }
            guard engine.vpnConnected && Shortcuts.isInForeground else {
                throw ShortcutError(L("LocalDevVPN isn't connected. Connect it, then try again."))
            }
        }
        return answer(true, dialog: L("LocalDevVPN is connected."))
    }

    private static func exportPairing() throws -> [String: Any] {
        let path = PairingController.pairingFilePath()
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
        guard size > 0 else {
            throw ShortcutError(Engine.deviceCanSelfPair ? L("No pairing file yet — tap “Generate pairing file” first.")
                                                       : L("No pairing file yet — tap “Import pairing file” first."))
        }
        let url = URL(fileURLWithPath: CompositePairingFile.existingPath() ?? path)
        return answer(["filename": url.lastPathComponent, "dataBase64": try Data(contentsOf: url).base64EncodedString()])
    }

    private static func installPairing() async throws -> [String: Any] {
        try Shortcuts.requireNoInstall()
        try await ensureTunnel()
        let targets = try await Engine.shared.installedPairingTargets()
        guard !targets.isEmpty else {
            throw ShortcutError(L("Install an app like SideStore, StikDebug, or Feather first, then rescan."))
        }
        try await Engine.shared.installPairing(intoAll: targets)
        let dialog = targets.count == 1 ? L("Pairing file installed into %@.", targets[0].name)
                                       : L("Pairing file installed into all %d apps.", targets.count)
        return answer(targets.map(\.name), dialog: dialog)
    }

    private static func revealDeveloperMode() async throws -> [String: Any] {
        try await ensureTunnel()
        switch try await Engine.shared.requestDeveloperMode(.reveal) {
        case .alreadyOn: return answer(dialog: L("Developer Mode is already on."))
        case .revealed, .enabling:
            return answer(dialog: L("Developer Mode now shows under Settings › Privacy & Security, near the bottom. Turn it on there, and iOS restarts to finish."))
        }
    }

    private static func setLocation(_ value: [String: Any]) async throws -> [String: Any] {
        let coordinate = try coordinate(value)
        let name = try optionalString(value["name"]) ?? LocationManager.format(coordinate)
        try await ensureTunnel()
        try await LocationManager.shared.setLocation(coordinate)
        return answer(["latitude": coordinate.latitude, "longitude": coordinate.longitude, "name": name],
                      dialog: L("Location set to %@.", name))
    }

    private static func spoofedLocation() async -> [String: Any] {
        guard let coordinate = LocationManager.shared.simulated else { return answer(dialog: L("Not simulating")) }
        let name = await RoutePlanner.placeName(at: coordinate) ?? LocationManager.format(coordinate)
        return answer(["latitude": coordinate.latitude, "longitude": coordinate.longitude, "name": name], dialog: name)
    }

    private static func playGPX(_ request: CompanionShortcutRequest) async throws -> [String: Any] {
        let copy = try temporaryInput(request, defaultName: "Route.gpx")
        defer { Shortcuts.discard(copy) }
        let route = try await Task.detached(priority: .userInitiated) { try GPXRoute(contentsOf: copy) }.value
        try await ensureTunnel()
        if route.isSinglePlace, let point = route.points.first {
            try await LocationManager.shared.setLocation(point)
            return answer(dialog: L("Location set to %@.", route.name))
        }
        let speedName = try optionalString(request.parameters["speed"])
        let speed = try speedName.map { value -> RouteSpeed in
            guard let option = RouteSpeedOption(rawValue: value) else { throw CompanionShortcutFailure("路线速度无效。") }
            return option.speed
        } ?? (route.times == nil ? .walk : .recorded)
        let manager = LocationManager.shared
        try await manager.play(route, at: speed)
        return answer(dialog: PlayGPXRouteIntent.started(distance: route.distance, duration: route.duration(at: manager.routeSpeed)))
    }

    private static func travel(_ parameters: [String: Any]) async throws -> [String: Any] {
        let destination = try object(parameters["destination"])
        let start = try parameters["start"].map { try object($0) }
        guard let mode = TravelModeOption(rawValue: try string(parameters["mode"])) else {
            throw CompanionShortcutFailure("路线出行方式无效。")
        }
        let to = try RouteStop(coordinate: coordinate(destination), name: optionalString(destination["name"]))
        let from = try start.map { try RouteStop(coordinate: coordinate($0), name: optionalString($0["name"])) }
        try await ensureTunnel()
        let route = try await LocationManager.shared.travel(to: to, from: from, by: mode.mode)
        return answer(dialog: PlayGPXRouteIntent.started(distance: route.distance, duration: route.duration))
    }

    private static func temporaryInput(_ request: CompanionShortcutRequest, defaultName: String) throws -> URL {
        let input = try request.inputFile()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShortcutsInput-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = ["", ".", ".."].contains(input.name) ? defaultName : input.name
        let destination = folder.appendingPathComponent(name)
        do { try FileManager.default.copyItem(at: input.url, to: destination) }
        catch { try? FileManager.default.removeItem(at: folder); throw error }
        return destination
    }

    static func savedPlaces() -> [[String: Any]] { LocationManager.shared.savedPlaces.map(place) }

    private static func place(_ value: SavedPlace) -> [String: Any] {
        ["id": value.id.uuidString, "name": value.name, "latitude": value.latitude, "longitude": value.longitude]
    }

    static func sideloadedApps() -> [[String: Any]] {
        let manager = SideloadedAppsManager.shared
        let refreshable = Set(manager.refreshable.map(\.bundleID))
        return manager.entries.map { status in
            var value: [String: Any] = ["id": status.app.bundleID, "bundleID": status.app.bundleID,
                                       "name": status.app.name, "canBeRefreshed": refreshable.contains(status.app.bundleID),
                                       "expiry": ExpiryUrgency.text(for: status.current)]
            if let version = status.app.version { value["version"] = version }
            if let date = status.current?.expirationDate { value["expirationDate"] = date.timeIntervalSince1970 }
            if let days = status.current?.daysRemaining { value["daysLeft"] = days }
            return value
        }
    }

    static func coordinate(_ value: [String: Any]) throws -> CLLocationCoordinate2D {
        guard let latitude = CompanionShortcutRequest.number(value["latitude"]),
              let longitude = CompanionShortcutRequest.number(value["longitude"]),
              (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw ShortcutError(L("That isn't a valid coordinate."))
        }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private static func object(_ value: Any?) throws -> [String: Any] {
        guard let value = value as? [String: Any] else { throw CompanionShortcutFailure("快捷指令参数无效。") }
        return value
    }

    private static func string(_ value: Any?) throws -> String {
        guard let value = value as? String, !value.isEmpty else { throw CompanionShortcutFailure("快捷指令参数无效。") }
        return value
    }

    private static func optionalString(_ value: Any?) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let value = value as? String else { throw CompanionShortcutFailure("快捷指令参数无效。") }
        return value
    }

    private static func uuid(_ value: Any?) throws -> UUID {
        guard let identifier = UUID(uuidString: try string(value)) else { throw CompanionShortcutFailure("收藏地点编号无效。") }
        return identifier
    }

    private static func savedPlace(_ value: [String: Any]) throws -> SavedPlace {
        let identifier = try uuid(value["id"])
        guard let saved = LocationManager.shared.savedPlaces.first(where: { $0.id == identifier }) else {
            throw CompanionShortcutFailure("这个收藏地点已删除，请重新选择。")
        }
        return saved
    }
}
