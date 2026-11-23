import Foundation
import Testing
@testable import SideInstaller

struct CompanionOperationLeaseTests {
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
