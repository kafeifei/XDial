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

/// One host Underlay capture resolves exactly once: with the first usable
/// path, or with the evidence held when its deadline fires. A deadline that
/// fires after the capture already resolved is not a timeout.
struct HostUnderlayCaptureResolution {
    private(set) var isResolved = false
    private var latestEvidence: HostUnderlayCaptureEvidence?

    mutating func observe(_ evidence: HostUnderlayCaptureEvidence) {
        guard !isResolved else { return }
        latestEvidence = evidence
    }

    /// True only for the call that resolves the capture.
    mutating func resolve() -> Bool {
        guard !isResolved else { return false }
        isResolved = true
        return true
    }

    /// Timeout evidence when the deadline resolves the capture; nil when a
    /// path or an earlier failure already did.
    mutating func expire() -> HostUnderlayCaptureEvidence? {
        guard resolve() else { return nil }
        return latestEvidence ?? .missingPathUpdate
    }
}
