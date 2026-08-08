import Foundation

enum TransparentProxyManagerCandidateState: Equatable {
    case connected
    case reasserting
    case connecting
    case disconnecting
    case disconnected
    case invalid
    case unknown
}

struct TransparentProxyManagerCandidate: Equatable {
    let providerBundleIdentifier: String?
    let localizedDescription: String?
    let state: TransparentProxyManagerCandidateState
    let isCurrentManager: Bool
}

enum TransparentProxyManagerSelectionPurpose: Equatable {
    case runtime
    case diagnostics
}

/// Selects one Network Extension preference record without depending on the
/// unspecified ordering returned by `loadAllFromPreferences`.
///
/// Runtime lifecycle operations may use the localized name only as the final
/// migration fallback. Provider diagnostics are transaction capabilities and
/// therefore require the exact provider bundle and a connected session.
enum TransparentProxyManagerSelector {
    static func selectIndex(
        from candidates: [TransparentProxyManagerCandidate],
        expectedBundleIdentifier: String,
        configurationName: String,
        purpose: TransparentProxyManagerSelectionPurpose
    ) -> Int? {
        let indexed = Array(candidates.enumerated())
        let exact = indexed.filter {
            $0.element.providerBundleIdentifier ==
                expectedBundleIdentifier
        }

        switch purpose {
        case .diagnostics:
            let connected = exact.filter {
                $0.element.state == .connected
            }
            return (
                connected.first(where: {
                    $0.element.isCurrentManager
                }) ?? connected.first
            )?.offset
        case .runtime:
            if let current = exact.first(where: {
                $0.element.isCurrentManager
            }) {
                return current.offset
            }
            if let selected = bestRuntimeCandidate(exact) {
                return selected.offset
            }
            let migrationFallback = indexed.filter {
                $0.element.localizedDescription == configurationName
            }
            return bestRuntimeCandidate(migrationFallback)?.offset
        }
    }

    private static func bestRuntimeCandidate(
        _ candidates: [
            EnumeratedSequence<
                [TransparentProxyManagerCandidate]
            >.Element
        ]
    ) -> EnumeratedSequence<
        [TransparentProxyManagerCandidate]
    >.Element? {
        candidates.min {
            let left = runtimeRank($0.element.state)
            let right = runtimeRank($1.element.state)
            if left == right {
                return $0.offset < $1.offset
            }
            return left < right
        }
    }

    private static func runtimeRank(
        _ state: TransparentProxyManagerCandidateState
    ) -> Int {
        switch state {
        case .connected:
            0
        case .reasserting:
            1
        case .connecting:
            2
        case .disconnecting:
            3
        case .disconnected:
            4
        case .invalid:
            5
        case .unknown:
            6
        }
    }
}
