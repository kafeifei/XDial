import XCTest

final class FlightStatusIconTests: XCTestCase {
    func testEngineStatusMapping() {
        XCTAssertEqual(
            FlightStatusIconModel.visualState(for: "disconnected"),
            .landing
        )
        XCTAssertEqual(
            FlightStatusIconModel.visualState(for: "disconnecting"),
            .landing
        )
        XCTAssertEqual(
            FlightStatusIconModel.visualState(for: "connecting"),
            .takingOff
        )
        XCTAssertEqual(
            FlightStatusIconModel.visualState(for: "reconnecting"),
            .takingOff
        )
        XCTAssertEqual(
            FlightStatusIconModel.visualState(for: "connected"),
            .cruising
        )
        XCTAssertEqual(
            FlightStatusIconModel.visualState(
                for: "disconnected",
                hasError: true
            ),
            .crashed
        )
    }

    func testFourStatesHaveDistinctPitches() {
        let pitches = FlightVisualState.allCases.map {
            FlightStatusIconModel.pitch(for: $0)
        }
        XCTAssertEqual(Set(pitches).count, 4)
        XCTAssertGreaterThan(
            FlightStatusIconModel.pitch(for: .takingOff),
            FlightStatusIconModel.pitch(for: .cruising)
        )
        XCTAssertLessThan(
            FlightStatusIconModel.pitch(for: .landing),
            FlightStatusIconModel.pitch(for: .cruising)
        )
        XCTAssertLessThan(
            FlightStatusIconModel.pitch(for: .crashed),
            FlightStatusIconModel.pitch(for: .landing)
        )
    }

    func testApprovedBrightnessLevels() {
        for state in FlightVisualState.allCases {
            let levels = FlightStatusIconModel.trailOpacities(
                for: state,
                phase: 0.6
            )
            XCTAssertTrue(levels.allSatisfy {
                [0.4, 0.7, 1].contains($0)
            })
        }
    }
}
