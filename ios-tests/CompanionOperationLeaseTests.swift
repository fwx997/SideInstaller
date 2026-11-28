import Foundation
import Testing
@testable import SideInstaller

struct CompanionOperationLeaseTests {
    @Test @MainActor func earlyDebuggerEndKeepsPreparationLease() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let pool = CompanionOperationLease.Pool()
        let competitor = CompanionOperationLease.Pool()
        var action: MobileDataActionContext?
        do {
            let preparationLease = try pool.acquire(at: file)
            defer { preparationLease.release() }
            try await MobileDataMode.shared.run(.jit) {
                action = MobileDataAction.current
                let sessionLease = try pool.acquire(at: file)
                // The debugger ends while its launch task still awaits cleanup.
                sessionLease.release()
                await Task.yield()
                #expect(action?.ended == false)
                #expect(throws: CompanionOperationLease.Failure.self) { try competitor.acquire(at: file) }
            }
            #expect(action?.ended == true)
            #expect(throws: CompanionOperationLease.Failure.self) { try competitor.acquire(at: file) }
        }
        let next = try competitor.acquire(at: file)
        next.release()
    }

    @Test @MainActor func mobileDataActionKeepsLeaseAcrossSuspensionAndFailure() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let pool = CompanionOperationLease.Pool()
        let competitor = CompanionOperationLease.Pool()
        var action: MobileDataActionContext?
        do {
            let lease = try pool.acquire(at: file)
            defer { lease.release() }
            try await MobileDataMode.shared.run(.refresh) {
                action = MobileDataAction.current
                await Task.yield()
                #expect(throws: CompanionOperationLease.Failure.self) { try competitor.acquire(at: file) }
                try await MobileDataMode.shared.run(.pairing) {
                    #expect(MobileDataAction.current === action)
                    throw CancellationError()
                }
            }
            Issue.record("The cancelled action should have failed")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(action?.ended == true)
        let next = try competitor.acquire(at: file)
        next.release()
    }

    @Test func independentDescriptorsCannotOverlap() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let first = CompanionOperationLease.Pool()
        let second = CompanionOperationLease.Pool()
        let token = try first.acquire(at: file)
        #expect(throws: CompanionOperationLease.Failure.self) { try second.acquire(at: file) }
        token.release()
        let next = try second.acquire(at: file)
        next.release()
    }

    @Test func nestedCallsKeepTheLockUntilTheLastTokenEnds() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let pool = CompanionOperationLease.Pool()
        let competitor = CompanionOperationLease.Pool()
        let outer = try pool.acquire(at: file)
        let inner = try pool.acquire(at: file)
        outer.release()
        outer.release()
        #expect(throws: CompanionOperationLease.Failure.self) { try competitor.acquire(at: file) }
        inner.release()
        let next = try competitor.acquire(at: file)
        next.release()
    }
}
