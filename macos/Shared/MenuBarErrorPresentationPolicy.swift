import Foundation

/// An explicit acknowledgement is scoped to one failed Scenario candidate.
///
/// The Popover can be recreated every time the menu-bar item opens, so this
/// state cannot live in a View. Capturing the messages also prevents the
/// acknowledgement from hiding an unrelated error that arrives later.
struct ScenarioSwitchFailureAcknowledgement: Equatable {
    let candidateTransactionID: String
    private let messages: Set<String>

    init(
        candidateTransactionID: String,
        messages: [String?]
    ) {
        self.candidateTransactionID = candidateTransactionID
        self.messages = Set(messages.compactMap(Self.normalized))
    }

    func suppresses(
        candidateTransactionID: String?,
        engineError: String?
    ) -> Bool {
        guard candidateTransactionID == self.candidateTransactionID,
              let engineError = Self.normalized(engineError) else {
            return false
        }
        return messages.contains(engineError)
    }

    private static func normalized(_ message: String?) -> String? {
        guard let message else { return nil }
        let value = message.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return value.isEmpty ? nil : value
    }
}

/// Keeps the menu-bar badge and Popover acknowledgement on the same state.
enum MenuBarErrorPresentationPolicy {
    static func hasError(
        installationFailed: Bool,
        connectionReportHasError: Bool,
        visibleScenarioSwitchFailureID: String?,
        currentScenarioSwitchFailureID: String?,
        engineError: String?,
        acknowledgement: ScenarioSwitchFailureAcknowledgement?
    ) -> Bool {
        if installationFailed || connectionReportHasError {
            return true
        }
        if visibleScenarioSwitchFailureID != nil {
            return true
        }
        guard let engineError = normalized(engineError) else {
            return false
        }
        return acknowledgement?.suppresses(
            candidateTransactionID: currentScenarioSwitchFailureID,
            engineError: engineError
        ) != true
    }

    private static func normalized(_ message: String?) -> String? {
        guard let message else { return nil }
        let value = message.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return value.isEmpty ? nil : value
    }
}
