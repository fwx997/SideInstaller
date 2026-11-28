import Foundation
import Testing
@testable import SideInstaller

/// Mobile Data Mode's rules that don't need an iPhone: what counts as mobile
/// data only, which tasks are part of what the user started, and that nothing
/// asks outside one.
@Suite("Mobile Data Mode")
@MainActor
struct MobileDataModeTests {

    private enum Failure: Error { case expected }

    @Test("Mobile Data Mode and tunnel reuse stay off until the offer is accepted")
    func startsDisabled() async throws {
        let mode = MobileDataMode.shared
        #expect(!mode.isOn)
        #expect(!DeviceConnection.keepsOpenTunnel)
        await mode.run(.pairing) {
            #expect(MobileDataAction.current?.accepted == nil)
        }
        #expect(!mode.isOn)
        #expect(!DeviceConnection.keepsOpenTunnel)
        #expect(mode.prompt == nil)
    }

    @Test("Failed actions end their context and propagate their original error")
    func failedActions() async {
        let mode = MobileDataMode.shared
        let features: [MobileDataFeature] = [.install, .refresh, .pairing, .developerMode, .jit, .location]
        for feature in features {
            var action: MobileDataActionContext?
            do {
                try await mode.run(feature) {
                    action = MobileDataAction.current
                    throw Failure.expected
                }
                Issue.record("The action should have failed")
            } catch {
                #expect(error is Failure)
            }
            #expect(action?.ended == true)
            #expect(MobileDataAction.current == nil)
        }
    }

    @Test("Cancellation still finishes the current action")
    func cancelledAction() async {
        var action: MobileDataActionContext?
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await MobileDataMode.shared.run(.install) {
                action = MobileDataAction.current
                try Task.checkCancellation()
            }
        }
        do {
            try await task.value
            Issue.record("The cancelled action should have failed")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(action?.ended == true)
        #expect(MobileDataAction.current == nil)
    }

    @Test("Mobile data only is mobile data without Wi-Fi")
    func mobileDataOnly() {
        #expect(NetworkStatus.Links(wifi: false, mobileData: true).mobileDataOnly)
        #expect(!NetworkStatus.Links(wifi: true, mobileData: true).mobileDataOnly)
        #expect(!NetworkStatus.Links(wifi: true, mobileData: false).mobileDataOnly)
        // Airplane Mode: neither.
        #expect(!NetworkStatus.Links(wifi: false, mobileData: false).mobileDataOnly)
        #expect(NetworkStatus.Links(wifi: false, mobileData: true).summary == "Wi-Fi off, mobile data on")
    }

    @Test("An action's tasks, its nested actions and the tasks it starts share it")
    func actionsNest() async {
        let mode = MobileDataMode.shared
        #expect(MobileDataAction.current == nil)
        await mode.run(.location) {
            let outer = MobileDataAction.current
            #expect(outer?.feature == .location)
            // A step that is an action of its own elsewhere joins this one.
            await mode.run(.pairing) {
                #expect(MobileDataAction.current === outer)
            }
            // A task started inside it is part of it too.
            let inner = await Task { MobileDataAction.current }.value
            #expect(inner === outer)
            // A quiet attempt is part of nothing, even here.
            await MobileDataMode.quietly {
                #expect(MobileDataAction.current == nil)
            }
        }
        #expect(MobileDataAction.current == nil)
    }

    @Test("An action that has ended asks nothing more")
    func endedActions() async throws {
        let mode = MobileDataMode.shared
        var kept: MobileDataActionContext?
        await mode.run(.apps) { kept = MobileDataAction.current }
        let action = try #require(kept)
        #expect(action.ended)
        // Outside any action, nothing is asked whatever the network.
        #expect(try await mode.prepareNewTunnel() == false)
        try await mode.requireInternet(.signIn)
        #expect(mode.prompt == nil)
    }

    @Test("Every internet need says what comes next")
    func internetNeeds() {
        let needs: [MobileDataInternetNeed] = [.install, .signIn, .signing, .diskImageDownload, .diskImage]
        for need in needs {
            #expect(need.sentence.hasSuffix("."))
            #expect(!need.logName.isEmpty)
        }
        #expect(Set(needs.map(\.sentence)).count == needs.count)
    }
}
