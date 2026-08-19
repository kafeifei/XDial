import Foundation
import XCTest

final class HostUnderlayCaptureDiagnosticsTests: XCTestCase {
    func testClassifiesUnsatisfiedPathBeforeRouteFacts() {
        let evidence = HostUnderlayCaptureDiagnosticClassifier.classify(
            pathStatus: "unsatisfied",
            routeInterface: "",
            routeError: "",
            candidateInterfaces: ["en0"],
            indexedInterfaces: ["en0"]
        )

        XCTAssertEqual(evidence?.reason, .pathUnsatisfied)
        XCTAssertEqual(evidence?.pathStatus, "unsatisfied")
    }

    func testClassifiesDefaultRouteFailure() {
        let evidence = HostUnderlayCaptureDiagnosticClassifier.classify(
            pathStatus: "satisfied",
            routeInterface: "",
            routeError: "default route has no interface",
            candidateInterfaces: ["en0"],
            indexedInterfaces: ["en0"]
        )

        XCTAssertEqual(evidence?.reason, .defaultRouteUnavailable)
        XCTAssertEqual(
            evidence?.routeError,
            "default route has no interface"
        )
    }

    func testClassifiesRoutePathMismatch() {
        let evidence = HostUnderlayCaptureDiagnosticClassifier.classify(
            pathStatus: "satisfied",
            routeInterface: "utun7",
            routeError: "",
            candidateInterfaces: ["en0"],
            indexedInterfaces: ["en0"]
        )

        XCTAssertEqual(evidence?.reason, .routePathMismatch)
        XCTAssertEqual(evidence?.routeInterface, "utun7")
        XCTAssertEqual(evidence?.candidateInterfaces, ["en0"])
    }

    func testClassifiesMissingInterfaceIndex() {
        let evidence = HostUnderlayCaptureDiagnosticClassifier.classify(
            pathStatus: "satisfied",
            routeInterface: "en0",
            routeError: "",
            candidateInterfaces: ["en0", "utun7"],
            indexedInterfaces: ["utun7"]
        )

        XCTAssertEqual(evidence?.reason, .interfaceIndexUnavailable)
        XCTAssertEqual(evidence?.invalidCandidateInterfaces, ["en0"])
    }

    func testReturnsNoFailureForCoherentSnapshot() {
        XCTAssertNil(HostUnderlayCaptureDiagnosticClassifier.classify(
            pathStatus: "satisfied",
            routeInterface: "en0",
            routeError: "",
            candidateInterfaces: ["en0", "utun7"],
            indexedInterfaces: ["en0", "utun7"]
        ))
    }

    func testMissingPathUpdateHasStableStructuredReason() {
        XCTAssertEqual(
            HostUnderlayCaptureEvidence.missingPathUpdate.reason,
            .pathUpdateMissing
        )
        XCTAssertEqual(
            HostUnderlayCaptureEvidence.missingPathUpdate.pathStatus,
            "unknown"
        )
    }

    func testEvidenceRoundTripsThroughConnectionFailure() throws {
        let evidence = HostUnderlayCaptureEvidence(
            schemaVersion: 1,
            reason: .routePathMismatch,
            pathStatus: "satisfied",
            routeInterface: "utun7",
            candidateInterfaces: ["en0"],
            invalidCandidateInterfaces: [],
            routeError: ""
        )
        let failureEvidence = ConnectionFailureEvidence(
            underlayCapture: evidence
        )

        let data = try JSONEncoder().encode(failureEvidence)
        XCTAssertEqual(
            try JSONDecoder().decode(
                ConnectionFailureEvidence.self,
                from: data
            ),
            failureEvidence
        )
    }
}
