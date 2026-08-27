import CoreLocation

enum WiFiSSIDAccessState: Equatable {
    case ready
    case permissionRequired
    case denied
    case unavailable

    var logValue: String {
        switch self {
        case .ready: "ready"
        case .permissionRequired: "permission-required"
        case .denied: "denied"
        case .unavailable: "unavailable"
        }
    }
}

enum WiFiSSIDAccessRequestDisposition: Equatable {
    case refreshed
    case authorizationRequested
    case openSystemSettings
    case unavailable
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
