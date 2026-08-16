import XCTest

final class MenuBarErrorPresentationPolicyTests: XCTestCase {
    func testAcknowledgedSwitchFailureClearsMenuBadge() {
        let acknowledgement = ScenarioSwitchFailureAcknowledgement(
            candidateTransactionID: "candidate-1",
            messages: ["AnyConnect capability is unavailable"]
        )

        XCTAssertFalse(MenuBarErrorPresentationPolicy.hasError(
            installationFailed: false,
            connectionReportHasError: false,
            visibleScenarioSwitchFailureID: nil,
            currentScenarioSwitchFailureID: "candidate-1",
            engineError: "AnyConnect capability is unavailable",
            acknowledgement: acknowledgement
        ))
    }

    func testVisibleSwitchFailureShowsMenuBadge() {
        XCTAssertTrue(MenuBarErrorPresentationPolicy.hasError(
            installationFailed: false,
            connectionReportHasError: false,
            visibleScenarioSwitchFailureID: "candidate-1",
            currentScenarioSwitchFailureID: "candidate-1",
            engineError: nil,
            acknowledgement: nil
        ))
    }

    func testAcknowledgementCannotHideNewCandidateFailure() {
        let acknowledgement = ScenarioSwitchFailureAcknowledgement(
            candidateTransactionID: "candidate-1",
            messages: ["candidate failed"]
        )

        XCTAssertTrue(MenuBarErrorPresentationPolicy.hasError(
            installationFailed: false,
            connectionReportHasError: false,
            visibleScenarioSwitchFailureID: "candidate-2",
            currentScenarioSwitchFailureID: "candidate-2",
            engineError: "candidate failed",
            acknowledgement: acknowledgement
        ))
    }

    func testAcknowledgementCannotHideUnrelatedNewError() {
        let acknowledgement = ScenarioSwitchFailureAcknowledgement(
            candidateTransactionID: "candidate-1",
            messages: ["candidate failed"]
        )

        XCTAssertTrue(MenuBarErrorPresentationPolicy.hasError(
            installationFailed: false,
            connectionReportHasError: false,
            visibleScenarioSwitchFailureID: nil,
            currentScenarioSwitchFailureID: "candidate-1",
            engineError: "helper socket unavailable",
            acknowledgement: acknowledgement
        ))
    }

    func testInstallationAndConnectionFailuresRemainVisible() {
        XCTAssertTrue(MenuBarErrorPresentationPolicy.hasError(
            installationFailed: true,
            connectionReportHasError: false,
            visibleScenarioSwitchFailureID: nil,
            currentScenarioSwitchFailureID: nil,
            engineError: nil,
            acknowledgement: nil
        ))
        XCTAssertTrue(MenuBarErrorPresentationPolicy.hasError(
            installationFailed: false,
            connectionReportHasError: true,
            visibleScenarioSwitchFailureID: nil,
            currentScenarioSwitchFailureID: nil,
            engineError: nil,
            acknowledgement: nil
        ))
    }
}
