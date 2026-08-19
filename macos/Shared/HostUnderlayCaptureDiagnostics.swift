import Foundation

enum HostUnderlayCaptureFailureReason: String, Codable, Equatable {
    case pathUpdateMissing = "underlay-path-update-missing"
    case pathUnsatisfied = "underlay-path-unsatisfied"
    case defaultRouteUnavailable = "underlay-default-route-unavailable"
    case routePathMismatch = "underlay-route-path-mismatch"
    case interfaceIndexUnavailable =
        "underlay-interface-index-unavailable"
    case snapshotEncodingFailed =
        "underlay-interface-snapshot-encoding-failed"
}

struct HostUnderlayCaptureEvidence: Codable, Equatable {
    let schemaVersion: Int
    let reason: HostUnderlayCaptureFailureReason
    let pathStatus: String
    let routeInterface: String
    let candidateInterfaces: [String]
    let invalidCandidateInterfaces: [String]
    let routeError: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case reason
        case pathStatus = "path_status"
        case routeInterface = "route_interface"
        case candidateInterfaces = "candidate_interfaces"
        case invalidCandidateInterfaces =
            "invalid_candidate_interfaces"
        case routeError = "route_error"
    }

    static let missingPathUpdate = HostUnderlayCaptureEvidence(
        schemaVersion: 1,
        reason: .pathUpdateMissing,
        pathStatus: "unknown",
        routeInterface: "",
        candidateInterfaces: [],
        invalidCandidateInterfaces: [],
        routeError: ""
    )

    var logSummary: String {
        [
            "reason=\(reason.rawValue)",
            "path-status=\(pathStatus)",
            "route-interface=\(routeInterface.isEmpty ? "-" : routeInterface)",
            "candidates=\(candidateInterfaces.joined(separator: ","))",
            "invalid-candidates=\(invalidCandidateInterfaces.joined(separator: ","))",
            "route-error=\(routeError.isEmpty ? "-" : routeError)",
        ].joined(separator: " ")
    }
}

enum HostUnderlayCaptureDiagnosticClassifier {
    static func classify(
        pathStatus: String,
        routeInterface: String,
        routeError: String,
        candidateInterfaces: [String],
        indexedInterfaces: [String]
    ) -> HostUnderlayCaptureEvidence? {
        let reason: HostUnderlayCaptureFailureReason?
        if pathStatus != "satisfied" {
            reason = .pathUnsatisfied
        } else if !routeError.isEmpty || routeInterface.isEmpty {
            reason = .defaultRouteUnavailable
        } else if !candidateInterfaces.contains(routeInterface) {
            reason = .routePathMismatch
        } else if !indexedInterfaces.contains(routeInterface) {
            reason = .interfaceIndexUnavailable
        } else {
            reason = nil
        }
        guard let reason else { return nil }
        return HostUnderlayCaptureEvidence(
            schemaVersion: 1,
            reason: reason,
            pathStatus: pathStatus,
            routeInterface: routeInterface,
            candidateInterfaces: candidateInterfaces,
            invalidCandidateInterfaces: candidateInterfaces.filter {
                !indexedInterfaces.contains($0)
            },
            routeError: routeError
        )
    }
}
