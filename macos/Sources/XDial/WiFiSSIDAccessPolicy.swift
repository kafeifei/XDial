import CoreLocation

enum WiFiSSIDAccessState: Equatable {
    case checking
    case ready
    case permissionRequired
    case denied
    case unavailable

    var logValue: String {
        switch self {
        case .checking: "checking"
        case .ready: "ready"
        case .permissionRequired: "permission-required"
        case .denied: "denied"
        case .unavailable: "unavailable"
        }
    }
}

enum WiFiSSIDAccessRequestDisposition: Equatable {
    case checking
    case refreshed
    case authorizationRequested
    case openSystemSettings
    case unavailable
}

/// The initial CLLocationManager property can precede its authorization callback.
/// Invalidate queued observations before an authorization change schedules a new SSID read.
struct WiFiSSIDAccessLifecycle {
    private(set) var hasReceivedAuthorization = false
    private(set) var revision: UInt64 = 0

    mutating func authorizationDidChange() {
        hasReceivedAuthorization = true
        invalidatePendingUpdates()
    }

    @discardableResult
    mutating func invalidatePendingUpdates() -> UInt64 {
        revision += 1
        return revision
    }

    func accessState(for status: CLAuthorizationStatus) -> WiFiSSIDAccessState {
        hasReceivedAuthorization
            ? WiFiSSIDAccessPolicy.accessState(for: status) : .checking
    }

    func isCurrentUpdate(_ candidate: UInt64) -> Bool {
        candidate == revision
    }
}

struct WiFiSSIDInitialAccessCheck {
    private var evaluated = false

    mutating func shouldPresent(
        accessState: WiFiSSIDAccessState, requiresSSIDAccess: Bool
    ) -> Bool {
        guard !evaluated, accessState != .checking else { return false }
        evaluated = true
        return requiresSSIDAccess && accessState != .ready
    }
}

enum WiFiSSIDAccessPolicy {
    static func accessState(
        for authorizationStatus: CLAuthorizationStatus
    ) -> WiFiSSIDAccessState {
        switch authorizationStatus {
        case .authorizedAlways:
            .ready
        case .notDetermined:
            .permissionRequired
        case .denied, .restricted:
            .denied
        @unknown default:
            .unavailable
        }
    }

    static func requestDisposition(
        for authorizationStatus: CLAuthorizationStatus
    ) -> WiFiSSIDAccessRequestDisposition {
        switch accessState(for: authorizationStatus) {
        case .checking:
            .checking
        case .ready:
            .refreshed
        case .permissionRequired:
            .authorizationRequested
        case .denied:
            .openSystemSettings
        case .unavailable:
            .unavailable
        }
    }
}
