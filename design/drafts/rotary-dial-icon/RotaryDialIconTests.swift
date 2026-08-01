import XCTest

final class RotaryDialIconTests: XCTestCase {
    func testEngineStatusMapping() {
        XCTAssertEqual(RotaryDialIconModel.visualState(for: "disconnected"), .idle)
        XCTAssertEqual(RotaryDialIconModel.visualState(for: "disconnecting"), .idle)
        XCTAssertEqual(RotaryDialIconModel.visualState(for: "failed"), .idle)
        XCTAssertEqual(RotaryDialIconModel.visualState(for: "connecting"), .dialing)
        XCTAssertEqual(RotaryDialIconModel.visualState(for: "reconnecting"), .dialing)
        XCTAssertEqual(RotaryDialIconModel.visualState(for: "connected"), .connected)
    }

    func testRotaryDialGeometryAndOpacities() {
        XCTAssertEqual(RotaryDialIconModel.canvasSize, 252)
        XCTAssertEqual(RotaryDialIconModel.holeCount, 10)
        XCTAssertEqual(RotaryDialIconModel.stopOpacity(for: .idle), 0.4)
        XCTAssertEqual(RotaryDialIconModel.stopOpacity(for: .dialing), 0.7)
        XCTAssertEqual(RotaryDialIconModel.stopOpacity(for: .connected), 1)
    }

    func testDialTurnsPausesAndReturns() {
        XCTAssertEqual(RotaryDialIconModel.dialRotation(for: 0), 0, accuracy: 0.0001)
        XCTAssertGreaterThan(RotaryDialIconModel.dialRotation(for: 0.34), 1.2)
        XCTAssertEqual(
            RotaryDialIconModel.dialRotation(for: 0.34),
            RotaryDialIconModel.dialRotation(for: 0.42),
            accuracy: 0.0001
        )
        XCTAssertEqual(RotaryDialIconModel.dialRotation(for: 1), 0, accuracy: 0.0001)
    }

    func testDialingFrameUsesOnlyApprovedBrightnessLevels() {
        let opacities = (0..<RotaryDialIconModel.holeCount).map {
            RotaryDialIconModel.holeOpacity(
                index: $0,
                state: .dialing,
                phase: 0.4
            )
        }
        XCTAssertTrue(opacities.contains(1))
        XCTAssertTrue(opacities.contains(0.7))
        XCTAssertTrue(opacities.allSatisfy { [0.4, 0.7, 1].contains($0) })
    }
}
