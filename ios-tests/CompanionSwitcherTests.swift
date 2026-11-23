import XCTest
@testable import SideInstaller

@MainActor
final class CompanionSwitcherTests: XCTestCase {
    func testActiveInstallCannotSwitchAndCompletionUnblocks() {
        let engine = Engine.shared
        let previous = engine.isRunning
        defer { engine.isRunning = previous }
        engine.isRunning = true
        XCTAssertNotNil(SICompanionBridge.switchBlockReason())
        engine.isRunning = false
        XCTAssertNil(SICompanionBridge.switchBlockReason())
    }
}
