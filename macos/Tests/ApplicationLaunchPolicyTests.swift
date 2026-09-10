import AppKit
import XCTest

final class ApplicationLaunchPolicyTests: XCTestCase {
    func testMenuBarRelaunchDoesNotCreateRecentApplicationTile() {
        let configuration = NSWorkspace.OpenConfiguration()

        ApplicationLaunchPolicy.configure(configuration)

        XCTAssertFalse(configuration.addsToRecentItems)
        XCTAssertFalse(configuration.activates)
        XCTAssertTrue(configuration.createsNewApplicationInstance)
        XCTAssertFalse(
            configuration.arguments.contains(
                ApplicationLaunchPolicy.installedSuccessorArgument
            )
        )
    }

    func testRelocationRelaunchCarriesPredecessorProcessIdentifier() {
        let configuration = NSWorkspace.OpenConfiguration()

        ApplicationLaunchPolicy.configure(
            configuration,
            relocationPredecessorProcessIdentifier: 42
        )

        XCTAssertEqual(
            configuration.arguments,
            [
                ApplicationLaunchPolicy.relocationPredecessorArgument,
                "42",
            ]
        )
        XCTAssertEqual(
            ApplicationLaunchPolicy
                .relocationPredecessorProcessIdentifier(
                    arguments: ["XDial"] + configuration.arguments
                ),
            42
        )
    }

    func testRelocationRelaunchRejectsInvalidPredecessorArgument() {
        XCTAssertNil(
            ApplicationLaunchPolicy
                .relocationPredecessorProcessIdentifier(
                    arguments: [
                        "XDial",
                        ApplicationLaunchPolicy
                            .relocationPredecessorArgument,
                    ]
                )
        )
        XCTAssertNil(
            ApplicationLaunchPolicy
                .relocationPredecessorProcessIdentifier(
                    arguments: [
                        "XDial",
                        ApplicationLaunchPolicy
                            .relocationPredecessorArgument,
                        "0",
                    ]
                )
        )
        XCTAssertNil(
            ApplicationLaunchPolicy
                .relocationPredecessorProcessIdentifier(
                    arguments: [
                        "XDial",
                        ApplicationLaunchPolicy
                            .relocationPredecessorArgument,
                        "not-a-pid",
                    ]
                )
        )
    }

    func testInstalledSuccessorCarriesDistinctMarkerAndPredecessor() {
        let configuration = NSWorkspace.OpenConfiguration()

        ApplicationLaunchPolicy.configure(
            configuration,
            relocationPredecessorProcessIdentifier: 42,
            isInstalledSuccessor: true
        )

        XCTAssertEqual(
            configuration.arguments,
            [
                ApplicationLaunchPolicy.relocationPredecessorArgument,
                "42",
                ApplicationLaunchPolicy.installedSuccessorArgument,
            ]
        )
        XCTAssertEqual(
            ApplicationLaunchPolicy.relocationPredecessorProcessIdentifier(
                arguments: ["XDial"] + configuration.arguments
            ),
            42
        )
        XCTAssertTrue(
            ApplicationLaunchPolicy.shouldRejectInstalledSuccessor(
                currentIsCanonical: false,
                arguments: ["XDial"] + configuration.arguments
            )
        )
        XCTAssertFalse(
            ApplicationLaunchPolicy.shouldRejectInstalledSuccessor(
                currentIsCanonical: true,
                arguments: ["XDial"] + configuration.arguments
            )
        )
    }

    func testInstalledSuccessorMarkerDoesNotRequirePredecessorPID() {
        let configuration = NSWorkspace.OpenConfiguration()

        ApplicationLaunchPolicy.configure(
            configuration,
            isInstalledSuccessor: true
        )

        XCTAssertEqual(
            configuration.arguments,
            [ApplicationLaunchPolicy.installedSuccessorArgument]
        )
        XCTAssertTrue(
            ApplicationLaunchPolicy.shouldRejectInstalledSuccessor(
                currentIsCanonical: false,
                arguments: ["XDial"] + configuration.arguments
            )
        )
    }

    func testDownloadAndStagedUpdateMayStartOutsideCanonicalLocation() {
        XCTAssertFalse(
            ApplicationLaunchPolicy.shouldRejectInstalledSuccessor(
                currentIsCanonical: false,
                arguments: ["XDial"]
            )
        )

        let stagedConfiguration = NSWorkspace.OpenConfiguration()
        ApplicationLaunchPolicy.configure(
            stagedConfiguration,
            relocationPredecessorProcessIdentifier: 42
        )

        XCTAssertFalse(
            stagedConfiguration.arguments.contains(
                ApplicationLaunchPolicy.installedSuccessorArgument
            )
        )
        XCTAssertFalse(
            ApplicationLaunchPolicy.shouldRejectInstalledSuccessor(
                currentIsCanonical: false,
                arguments: ["XDial"] + stagedConfiguration.arguments
            )
        )
    }

    func testRelaunchHandoffOnlyIgnoresExactNonCanonicalPredecessor() {
        XCTAssertTrue(
            ApplicationRelaunchHandoffPolicy.shouldIgnoreCandidate(
                currentIsCanonical: true,
                candidateProcessIdentifier: 42,
                candidateBundleIdentifierMatches: true,
                candidateBundleIsCanonical: false,
                expectedPredecessorProcessIdentifier: 42
            )
        )
        XCTAssertFalse(
            ApplicationRelaunchHandoffPolicy.shouldIgnoreCandidate(
                currentIsCanonical: true,
                candidateProcessIdentifier: 43,
                candidateBundleIdentifierMatches: true,
                candidateBundleIsCanonical: false,
                expectedPredecessorProcessIdentifier: 42
            )
        )
        XCTAssertFalse(
            ApplicationRelaunchHandoffPolicy.shouldIgnoreCandidate(
                currentIsCanonical: true,
                candidateProcessIdentifier: 42,
                candidateBundleIdentifierMatches: false,
                candidateBundleIsCanonical: false,
                expectedPredecessorProcessIdentifier: 42
            )
        )
        XCTAssertFalse(
            ApplicationRelaunchHandoffPolicy.shouldIgnoreCandidate(
                currentIsCanonical: true,
                candidateProcessIdentifier: 42,
                candidateBundleIdentifierMatches: true,
                candidateBundleIsCanonical: true,
                expectedPredecessorProcessIdentifier: 42
            )
        )
        XCTAssertFalse(
            ApplicationRelaunchHandoffPolicy.shouldIgnoreCandidate(
                currentIsCanonical: false,
                candidateProcessIdentifier: 42,
                candidateBundleIdentifierMatches: true,
                candidateBundleIsCanonical: false,
                expectedPredecessorProcessIdentifier: 42
            )
        )
    }
}
