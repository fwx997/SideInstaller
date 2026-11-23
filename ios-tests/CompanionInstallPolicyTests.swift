import Foundation
import Testing
@testable import SideInstaller

struct CompanionInstallPolicyTests {
    private let host = "com.kdt.livecontainer.TEAMID1234"

    @Test func blocksBothOriginalAndAlreadySignedHostPackages() {
        #expect(throws: CompanionInstallPolicy.Failure.self) {
            try CompanionInstallPolicy.validateTarget("com.kdt.livecontainer", signingTeam: "TEAMID1234", hostIdentifier: host)
        }
        #expect(throws: CompanionInstallPolicy.Failure.self) {
            try CompanionInstallPolicy.validateTarget(host, signingTeam: "TEAMID1234", hostIdentifier: host)
        }
        #expect(throws: CompanionInstallPolicy.Failure.self) {
            try CompanionInstallPolicy.validateTarget(host, hostIdentifier: host)
        }
    }

    @Test func permitsDifferentApplicationsAndDifferentInstalledIdentities() throws {
        for package in ["com.kdt.livecontainer2", "com.SideStore.SideStore", "com.example.app"] {
            try CompanionInstallPolicy.validateTarget(package, signingTeam: "TEAMID1234", hostIdentifier: host)
        }
        try CompanionInstallPolicy.validateTarget("com.kdt.livecontainer", signingTeam: "OTHER12345", hostIdentifier: host)
    }

    @Test func finalInstallGuardReadsTheActualSignedIdentity() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: CompanionInstallPolicy.Failure.self) {
            try CompanionInstallPolicy.validateSignedBundle(at: folder.path, hostIdentifier: host)
        }
        let bytes = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": host], format: .binary, options: 0)
        try bytes.write(to: folder.appendingPathComponent("Info.plist"))
        #expect(throws: CompanionInstallPolicy.Failure.self) {
            try CompanionInstallPolicy.validateSignedBundle(at: folder.path, hostIdentifier: host)
        }
        let other = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.app.TEAMID1234"], format: .binary, options: 0)
        try other.write(to: folder.appendingPathComponent("Info.plist"))
        try CompanionInstallPolicy.validateSignedBundle(at: folder.path, hostIdentifier: host)
    }
}
