import XCTest

final class ScenarioSwitchSourceRetentionTests: XCTestCase {
    private let samePath = HostUnderlayIdentity(
        defaultInterface: .init(name: "en0", index: 7, type: "wifi"),
        interfaces: [.init(name: "en0", index: 7, type: "wifi")],
        systemDNSJSON: "[\"192.168.1.1\"]",
        interfaceAddresses: [
            HostInterfaceAddressFact(
                interfaceName: "en0",
                family: .ipv4,
                address: "192.168.1.23"
            ),
        ],
        routers: HostDefaultRouterFacts(ipv4: "192.168.1.1", ipv6: nil)
    ).pathIdentity

    private let movedPath = HostUnderlayIdentity(
        defaultInterface: .init(name: "en0", index: 7, type: "wifi"),
        interfaces: [.init(name: "en0", index: 7, type: "wifi")],
        systemDNSJSON: "[\"192.168.1.1\"]",
        interfaceAddresses: [
            HostInterfaceAddressFact(
                interfaceName: "en0",
                family: .ipv4,
                address: "192.168.1.77"
            ),
        ],
        routers: HostDefaultRouterFacts(ipv4: "192.168.1.1", ipv6: nil)
    ).pathIdentity

    private func facts(
        networkEpochSwitch: Bool = true,
        targetScenarioID: String = "office",
        targetConfigurationFingerprint: String = "config-1",
        sourcePath: String?? = .none,
        targetPath: String?? = .none
    ) -> ScenarioSwitchSourceDrainFacts {
        ScenarioSwitchSourceDrainFacts(
            networkEpochSwitch: networkEpochSwitch,
            sourceScenarioID: "office",
            targetScenarioID: targetScenarioID,
            sourceConfigurationFingerprint: "config-1",
            targetConfigurationFingerprint: targetConfigurationFingerprint,
            sourcePathIdentity: sourcePath ?? samePath,
            targetPathIdentity: targetPath ?? samePath
        )
    }

    func testSamePathNetworkEpochRetainsFlowsWithHardBound() {
        XCTAssertEqual(
            ScenarioSwitchSourceDrainPolicy.decide(facts()),
            .retainFlows(limit: 600)
        )
        XCTAssertEqual(
            ScenarioSwitchSourceDrainPolicy.retainedFlowLimit,
            600
        )
        XCTAssertEqual(ScenarioSwitchSourceDrainPolicy.handoffGrace, 1)
    }

    func testPathChangeKeepsBoundedDrain() {
        XCTAssertEqual(
            ScenarioSwitchSourceDrainPolicy.decide(
                facts(targetPath: .some(movedPath))
            ),
            .boundedDrain
        )
    }

    func testScenarioOrConfigurationChangeKeepsBoundedDrain() {
        XCTAssertEqual(
            ScenarioSwitchSourceDrainPolicy.decide(
                facts(targetScenarioID: "home")
            ),
            .boundedDrain
        )
        XCTAssertEqual(
            ScenarioSwitchSourceDrainPolicy.decide(
                facts(targetConfigurationFingerprint: "config-2")
            ),
            .boundedDrain
        )
    }

    /// A user-initiated Switch or reconnect carries no network epoch; it
    /// keeps today's drain even when nothing else changed.
    func testUserInitiatedSwitchKeepsBoundedDrain() {
        XCTAssertEqual(
            ScenarioSwitchSourceDrainPolicy.decide(
                facts(networkEpochSwitch: false)
            ),
            .boundedDrain
        )
    }

    /// An older host, or a start without the token, never proves the path.
    func testUnknownPathIdentityKeepsBoundedDrain() {
        XCTAssertEqual(
            ScenarioSwitchSourceDrainPolicy.decide(
                facts(sourcePath: .some(nil))
            ),
            .boundedDrain
        )
        XCTAssertEqual(
            ScenarioSwitchSourceDrainPolicy.decide(
                facts(targetPath: .some(nil))
            ),
            .boundedDrain
        )
        XCTAssertEqual(
            ScenarioSwitchSourceDrainPolicy.decide(
                facts(sourcePath: .some("same"), targetPath: .some("same"))
            ),
            .boundedDrain
        )
    }

    func testEmptyIdentitiesNeverRetain() {
        XCTAssertEqual(
            ScenarioSwitchSourceDrainPolicy.decide(
                ScenarioSwitchSourceDrainFacts(
                    networkEpochSwitch: true,
                    sourceScenarioID: "",
                    targetScenarioID: "",
                    sourceConfigurationFingerprint: "",
                    targetConfigurationFingerprint: "",
                    sourcePathIdentity: samePath,
                    targetPathIdentity: samePath
                )
            ),
            .boundedDrain
        )
    }

    func testRetentionIsBoundedAndBlocksCandidateUntilSuccessorEndsIt() {
        var retention = ScenarioSwitchSourceRetention()
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(retention.admitsCandidate)

        let retained = try! XCTUnwrap(retention.begin(
            sourceGeneration: "A",
            committedGeneration: "B",
            flowCount: 3,
            limit: ScenarioSwitchSourceDrainPolicy.retainedFlowLimit,
            now: now
        ))

        XCTAssertEqual(retained.deadline, now.addingTimeInterval(600))
        XCTAssertTrue(retention.holdsSource)
        // Committed B + retained A: no candidate may borrow a third lease set.
        XCTAssertFalse(retention.admitsCandidate)

        XCTAssertEqual(retention.endCurrent(), retained)
        XCTAssertTrue(retention.admitsCandidate)
        XCTAssertNil(retention.endCurrent())
    }

    func testSecondSourceCannotBeRetainedWhileOneIsHeld() {
        var retention = ScenarioSwitchSourceRetention()
        let first = retention.begin(
            sourceGeneration: "A",
            committedGeneration: "B",
            flowCount: 1,
            limit: 600
        )
        XCTAssertNotNil(first)

        XCTAssertNil(retention.begin(
            sourceGeneration: "B",
            committedGeneration: "C",
            flowCount: 1,
            limit: 600
        ))
        XCTAssertEqual(retention.retained, first)
    }

    func testStaleCallbackCannotEndANewerRetention() {
        var retention = ScenarioSwitchSourceRetention()
        let older = try! XCTUnwrap(retention.begin(
            sourceGeneration: "A",
            committedGeneration: "B",
            flowCount: 1,
            limit: 600
        ))
        // Successor candidate C ended A; C committed and retained B.
        XCTAssertEqual(retention.endCurrent(), older)
        let newer = try! XCTUnwrap(retention.begin(
            sourceGeneration: "B",
            committedGeneration: "C",
            flowCount: 2,
            limit: 600
        ))

        // A's limit timer or completion notification fires late.
        XCTAssertNil(retention.end(token: older.token))
        XCTAssertEqual(retention.retained, newer)

        XCTAssertEqual(retention.end(token: newer.token), newer)
        XCTAssertNil(retention.end(token: newer.token))
        XCTAssertTrue(retention.admitsCandidate)
    }

    func testNothingToRetainIsRetiredImmediately() {
        var retention = ScenarioSwitchSourceRetention()

        XCTAssertNil(retention.begin(
            sourceGeneration: "A",
            committedGeneration: "B",
            flowCount: 0,
            limit: 600
        ))
        XCTAssertNil(retention.begin(
            sourceGeneration: "A",
            committedGeneration: "A",
            flowCount: 1,
            limit: 600
        ))
        XCTAssertNil(retention.begin(
            sourceGeneration: "A",
            committedGeneration: "B",
            flowCount: 1,
            limit: 0
        ))
        XCTAssertTrue(retention.admitsCandidate)
    }

    func testStopEndsRetention() {
        var retention = ScenarioSwitchSourceRetention()
        let retained = retention.begin(
            sourceGeneration: "A",
            committedGeneration: "B",
            flowCount: 4,
            limit: 600
        )

        XCTAssertEqual(retention.endCurrent(), retained)
        XCTAssertFalse(retention.holdsSource)
        XCTAssertEqual(
            ScenarioSwitchSourceRetention.EndReason.stopped.rawValue,
            "stopped"
        )
    }
}
