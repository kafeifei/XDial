import Combine
import XCTest

// The unit-test target does not link GoEngine, which owns production logging.
func appLog(_ message: String) {}

final class MenuBarRecoveryControllerTests: XCTestCase {
    @MainActor
    func testSceneStateWriteBackOnlyPublishesRealChanges() {
        let controller = MenuBarRecoveryController()
        var publications = 0
        let subscription = controller.objectWillChange.sink { publications += 1 }
        let binding = controller.insertion

        // AppKit/SwiftUI reconciliation may write the current value repeatedly.
        for _ in 0..<100 { binding.wrappedValue = true }
        XCTAssertEqual(publications, 0)
        binding.wrappedValue = false
        XCTAssertEqual(publications, 1)
        for _ in 0..<100 { binding.wrappedValue = false }
        XCTAssertEqual(publications, 1)
        controller.suppressMenuRemovalTermination()
        controller.suppressMenuRemovalTermination()
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(controller.suppressedTerminations, 2)
        binding.wrappedValue = true
        XCTAssertEqual(publications, 2)
        withExtendedLifetime(subscription) {}
    }
}
