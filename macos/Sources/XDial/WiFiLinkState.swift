import Foundation

/// Wi-Fi association read from configd, independent of location permission.
/// It carries no SSID and exists only to separate a confirmed departure from
/// Wi-Fi from an SSID that is merely unreadable.
enum WiFiLinkState: Equatable {
    /// configd did not positively describe every Wi-Fi interface.
    case unknown
    /// At least one Wi-Fi interface reports an active link.
    case associated
    /// Every Wi-Fi interface reports power off or an inactive link.
    case disconnected

    var logValue: String {
        switch self {
        case .unknown: "unknown"
        case .associated: "associated"
        case .disconnected: "disconnected"
        }
    }
}

/// One interface's state keys. nil means configd did not provide the value,
/// which proves nothing either way.
struct WiFiInterfaceLinkFacts: Equatable {
    /// `State:/Network/Interface/<bsd>/AirPort` → `Power Status`.
    var powerOn: Bool?
    /// `State:/Network/Interface/<bsd>/Link` → `Active`.
    var linkActive: Bool?
}

enum WiFiLinkStatePolicy {
    static func state(
        for interfaces: [WiFiInterfaceLinkFacts]
    ) -> WiFiLinkState {
        guard !interfaces.isEmpty else { return .unknown }
        let states = interfaces.map(state(for:))
        if states.contains(.associated) {
            return .associated
        }
        return states.allSatisfy { $0 == .disconnected }
            ? .disconnected : .unknown
    }

    private static func state(
        for facts: WiFiInterfaceLinkFacts
    ) -> WiFiLinkState {
        switch (facts.powerOn, facts.linkActive) {
        case (false?, true?):
            // Contradictory adjacent reads are a transition, not proof.
            .unknown
        case (false?, _), (_, false?):
            .disconnected
        case (_, true?):
            .associated
        default:
            .unknown
        }
    }
}

extension SSIDScenarioSelectionState {
    /// Host entry for one Wi-Fi sample. Only a confirmed disconnect with no
    /// readable SSID opens a new activation boundary; a nil SSID while the
    /// link is associated or unknown keeps the manual selection.
    mutating func observe(
        ssid: String?,
        link: WiFiLinkState,
        matchedScenarioID: String?,
        forceMatching: Bool = false
    ) -> String? {
        if ssid?.isEmpty ?? true, link == .disconnected {
            noteWiFiDisconnected()
        }
        return resolve(
            ssid: ssid,
            matchedScenarioID: matchedScenarioID,
            forceMatching: forceMatching
        )
    }
}
