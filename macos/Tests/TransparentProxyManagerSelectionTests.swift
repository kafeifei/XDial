import XCTest

final class TransparentProxyManagerSelectionTests: XCTestCase {
    private let expectedBundle = "com.example.xdial.provider"
    private let configurationName = "XDial Transparent Proxy"

    func testRuntimePrefersCurrentExactManagerIdentity() {
        let candidates = [
            candidate(bundle: expectedBundle, state: .connected),
            candidate(
                bundle: expectedBundle,
                state: .disconnected,
                isCurrent: true
            ),
        ]

        XCTAssertEqual(select(candidates, purpose: .runtime), 1)
    }

    func testRuntimeRanksExactBundleByConnectionState() {
        let candidates = [
            candidate(bundle: expectedBundle, state: .disconnected),
            candidate(bundle: expectedBundle, state: .connecting),
            candidate(bundle: expectedBundle, state: .reasserting),
            candidate(bundle: expectedBundle, state: .connected),
        ]

        XCTAssertEqual(select(candidates, purpose: .runtime), 3)
    }

    func testRuntimeExactBundleBeatsConnectedNameFallback() {
        let candidates = [
            candidate(
                bundle: "com.example.legacy",
                name: configurationName,
                state: .connected
            ),
            candidate(bundle: expectedBundle, state: .disconnected),
        ]

        XCTAssertEqual(select(candidates, purpose: .runtime), 1)
    }

    func testRuntimeUsesNameOnlyAsFinalMigrationFallback() {
        let candidates = [
            candidate(
                bundle: "com.example.unrelated",
                name: "Unrelated",
                state: .connected
            ),
            candidate(
                bundle: "com.example.legacy",
                name: configurationName,
                state: .connecting
            ),
            candidate(
                bundle: "com.example.legacy",
                name: configurationName,
                state: .connected
            ),
        ]

        XCTAssertEqual(select(candidates, purpose: .runtime), 2)
    }

    func testDiagnosticsRequiresExactConnectedBundle() {
        let candidates = [
            candidate(
                bundle: expectedBundle,
                state: .disconnected,
                isCurrent: true
            ),
            candidate(
                bundle: "com.example.legacy",
                name: configurationName,
                state: .connected
            ),
            candidate(bundle: expectedBundle, state: .connected),
        ]

        XCTAssertEqual(select(candidates, purpose: .diagnostics), 2)
    }

    func testDiagnosticsNeverFallsBackToNameOrNonConnectedState() {
        let candidates = [
            candidate(
                bundle: "com.example.legacy",
                name: configurationName,
                state: .connected
            ),
            candidate(bundle: expectedBundle, state: .reasserting),
        ]

        XCTAssertNil(select(candidates, purpose: .diagnostics))
    }

    private func select(
        _ candidates: [TransparentProxyManagerCandidate],
        purpose: TransparentProxyManagerSelectionPurpose
    ) -> Int? {
        TransparentProxyManagerSelector.selectIndex(
            from: candidates,
            expectedBundleIdentifier: expectedBundle,
            configurationName: configurationName,
            purpose: purpose
        )
    }

    private func candidate(
        bundle: String?,
        name: String? = nil,
        state: TransparentProxyManagerCandidateState,
        isCurrent: Bool = false
    ) -> TransparentProxyManagerCandidate {
        TransparentProxyManagerCandidate(
            providerBundleIdentifier: bundle,
            localizedDescription: name,
            state: state,
            isCurrentManager: isCurrent
        )
    }
}
