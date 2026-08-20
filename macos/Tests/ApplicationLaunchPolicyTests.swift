import AppKit
import XCTest

final class ApplicationLaunchPolicyTests: XCTestCase {
    func testMenuBarRelaunchDoesNotCreateRecentApplicationTile() {
        let configuration = NSWorkspace.OpenConfiguration()

        ApplicationLaunchPolicy.configure(configuration)

        XCTAssertFalse(configuration.addsToRecentItems)
        XCTAssertFalse(configuration.activates)
        XCTAssertTrue(configuration.createsNewApplicationInstance)
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
