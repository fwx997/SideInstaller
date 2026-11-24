import Foundation
import Testing
@testable import SideInstaller

/// Exercise the on-disk RPC independently of Apple, VPN and signing services.
/// The injected executor still must finish before the real receiver replies.
@Suite("Embedded SideInstaller shortcut requests")
@MainActor
struct CompanionShortcutTests {
    private struct Fixture {
        let root: URL
        let folder: URL
        let identifier: String
        let host = "com.example.LiveContainer.TEAM"
        var json: [String: Any]

        init(parameters: [String: Any] = [:], now: Date = Date()) throws {
            let requestID = UUID().uuidString
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                .resolvingSymlinksInPath()
            root = directory
            identifier = requestID
            folder = directory.appendingPathComponent("requests", isDirectory: true).appendingPathComponent(requestID, isDirectory: true)
            json = ["version": 1, "id": requestID, "hostBundleID": host,
                    "action": "GetActivityLogIntent", "parameters": parameters,
                    "createdAt": now.timeIntervalSince1970, "expiresAt": now.addingTimeInterval(600).timeIntervalSince1970]
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try save()
            try Data().write(to: folder.appendingPathComponent("heartbeat"), options: .atomic)
        }

        func save() throws { try CompanionShortcutRequest.write(json, to: folder.appendingPathComponent("request.json")) }
        func load(now: Date = Date()) throws -> CompanionShortcutRequest {
            try CompanionShortcutRequest(root: root, hostBundleID: host, identifier: identifier, now: now)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("The response keeps physical-host and request identity, including a void value")
    func roundTrip() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let request = try fixture.load()
        #expect(try request.claim())
        try request.reply(["dialog": "Finished"])
        let reply = try CompanionShortcutRequest.read(fixture.folder.appendingPathComponent("response.json"))
        #expect(reply["id"] as? String == fixture.identifier)
        #expect(reply["hostBundleID"] as? String == fixture.host)
        #expect(reply["value"] is NSNull)
    }

    @Test("Another host, expired requests, Boolean versions and unknown actions are rejected")
    func invalidMetadata() throws {
        var fixture = try Fixture()
        defer { fixture.remove() }
        let original = fixture.json
        let invalid: [[String: Any]] = [
            ["hostBundleID": "com.example.LC2.TEAM"], ["version": true], ["version": 2],
            ["expiresAt": Date().addingTimeInterval(-1).timeIntervalSince1970],
            ["createdAt": Date().addingTimeInterval(30).timeIntervalSince1970],
            ["action": "InstallSomethingUnspecified"], ["parameters": "not a dictionary"],
        ]
        for change in invalid {
            fixture.json = original.merging(change) { _, new in new }
            try fixture.save()
            #expect(throws: CompanionShortcutFailure.self) { try fixture.load() }
        }
    }

    @Test("Missing, stale and cancelled clients cannot schedule work")
    func liveness() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let request = try fixture.load()
        let heartbeat = fixture.folder.appendingPathComponent("heartbeat")
        try FileManager.default.removeItem(at: heartbeat)
        #expect(throws: CompanionShortcutFailure.self) { try request.checkLive() }
        try Data().write(to: heartbeat, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-20)], ofItemAtPath: heartbeat.path)
        #expect(throws: CompanionShortcutFailure.self) { try request.checkLive() }
        try Data().write(to: heartbeat, options: .atomic)
        try Data().write(to: fixture.folder.appendingPathComponent("cancelled"))
        #expect(throws: CancellationError.self) { try request.checkLive() }
    }

    @Test("A cancellation marker cancels in-flight work and releases the receiver")
    func cancellationMonitor() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let receiver = CompanionShortcutReceiver(execute: { _ in
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return ["value": "Should not finish"]
        }, refresh: {})
        try receiver.accept(fixture.load())
        await Task.yield()
        let started = ProcessInfo.processInfo.systemUptime
        try Data().write(to: fixture.folder.appendingPathComponent("cancelled"))
        await receiver.operation?.value
        #expect(ProcessInfo.processInfo.systemUptime - started < 5)
        #expect(!receiver.isRunning)
        let reply = try CompanionShortcutRequest.read(fixture.folder.appendingPathComponent("response.json"))
        #expect(reply["error"] is String)
        #expect(reply["value"] is NSNull)
    }

    @Test("Claiming the same UUID twice never executes it twice")
    func claim() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.load()
        let second = try fixture.load()
        #expect(try first.claim())
        #expect(try !second.claim())
    }

    @Test("Input files stay in input and filename paths are reduced to a name")
    func fileContainment() throws {
        var fixture = try Fixture(parameters: ["file": ["filename": "../Route.gpx", "relativePath": "input/route.gpx"]])
        defer { fixture.remove() }
        let input = fixture.folder.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try Data("<gpx/>".utf8).write(to: input.appendingPathComponent("route.gpx"))
        #expect(try fixture.load().inputFile().name == "Route.gpx")
        for path in ["../request.json", "input/../request.json", "/etc/passwd", "input\\route.gpx", "input//route.gpx"] {
            fixture.json["parameters"] = ["file": ["filename": "Route.gpx", "relativePath": path]]
            try fixture.save()
            #expect(throws: CompanionShortcutFailure.self) { try fixture.load().inputFile() }
        }
    }

    @Test("A symbolic-link input cannot expose a file outside the request")
    func symlinkInput() throws {
        let fixture = try Fixture(parameters: ["file": ["filename": "secret", "relativePath": "input/link"]])
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("outside")
        try Data("secret".utf8).write(to: outside)
        let input = fixture.folder.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: input.appendingPathComponent("link"), withDestinationURL: outside)
        #expect(throws: CompanionShortcutFailure.self) { try fixture.load().inputFile() }
    }

    @Test("Coordinates reject Boolean, string, nonfinite and out-of-range numbers")
    func coordinates() throws {
        #expect(try CompanionShortcutActions.coordinate(["latitude": 90, "longitude": -180]).latitude == 90)
        let bad: [[String: Any]] = [
            ["latitude": true, "longitude": 1], ["latitude": "45", "longitude": 1],
            ["latitude": Double.nan, "longitude": 1], ["latitude": 91, "longitude": 1],
            ["latitude": 45, "longitude": 181],
        ]
        for value in bad { #expect(throws: ShortcutError.self) { try CompanionShortcutActions.coordinate(value) } }
    }

    @Test("The receiver waits for execution and removes input before publishing its result")
    func executionResult() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let input = fixture.folder.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try Data("input".utf8).write(to: input.appendingPathComponent("file"))
        var calls = 0
        var refreshCalled = false
        let receiver = CompanionShortcutReceiver(execute: { _ in
            calls += 1
            try await Task.sleep(nanoseconds: 20_000_000)
            return ["value": "Actual result"]
        }, refresh: {
            #expect(!FileManager.default.fileExists(atPath: input.path))
            #expect(!FileManager.default.fileExists(atPath: fixture.folder.appendingPathComponent("response.json").path))
            refreshCalled = true
        })
        let request = try fixture.load()
        try receiver.accept(request)
        try receiver.accept(request)
        #expect(receiver.isRunning)
        #expect(!request.hasResponse)
        await receiver.operation?.value
        #expect(calls == 1)
        #expect(refreshCalled)
        #expect(!receiver.isRunning)
        let reply = try CompanionShortcutRequest.read(fixture.folder.appendingPathComponent("response.json"))
        #expect(reply["value"] as? String == "Actual result")
        try receiver.accept(request)
        #expect(calls == 1)
    }

    @Test("A cancelled client gets an error even when work ignores cancellation")
    func lateSuccessRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let receiver = CompanionShortcutReceiver(execute: { request in
            try Data().write(to: request.folder.appendingPathComponent("cancelled"))
            return ["value": true]
        }, refresh: {})
        try receiver.accept(fixture.load())
        await receiver.operation?.value
        let reply = try CompanionShortcutRequest.read(fixture.folder.appendingPathComponent("response.json"))
        #expect(reply["error"] is String)
        #expect(reply["value"] is NSNull)
    }

    @Test("Execution errors are returned as errors, without inventing a result")
    func executionFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let receiver = CompanionShortcutReceiver(execute: { _ in throw ShortcutError("VPN is unavailable") }, refresh: {})
        try receiver.accept(fixture.load())
        await receiver.operation?.value
        let reply = try CompanionShortcutRequest.read(fixture.folder.appendingPathComponent("response.json"))
        #expect(reply["error"] as? String == "VPN is unavailable")
        #expect(reply["value"] is NSNull)
    }
}
