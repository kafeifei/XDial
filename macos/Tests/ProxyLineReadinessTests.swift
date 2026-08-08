import XCTest

final class ProxyResourceReadinessTests: XCTestCase {
    func testTargetsEveryActiveProxyResourceInPlanOrder() throws {
        let plan = ConnectionPlan(
            schemaVersion: 3,
            scenario: ConnectionPlanScenario(id: "scenario", name: "Scenario"),
            tasks: [
                lineTask(id: "direct", type: "direct"),
                lineTask(id: "corp", type: "vpn"),
                lineTask(id: "tailnet", type: "tailscale"),
                lineTask(id: "secure", type: "anytls"),
                lineTask(id: "legacy", type: "trojan"),
                lineTask(id: "cipher", type: "shadowsocks"),
                lineTask(id: "mesh", type: "vmess"),
                lineTask(id: "future", type: "future-proxy"),
                subscriptionTask(id: "imported"),
            ]
        )

        XCTAssertEqual(
            try ProxyResourceReadiness.targets(
                plan: plan,
                lineOutbounds: [
                    "direct": "direct",
                    "corp": "vpn",
                    "tailnet": "tailscale-tailnet",
                    "secure": "anytls-secure",
                    "legacy": "trojan-legacy",
                    "cipher": "shadowsocks-cipher",
                    "mesh": "vmess-mesh",
                    "future": "future-proxy-future",
                    "not-in-plan": "anytls-not-in-plan",
                ],
                subscriptionOutbounds: [
                    "imported": [
                        "subscription-imported",
                        "subscription-streaming",
                    ],
                    "not-in-plan": ["subscription-not-in-plan"],
                ]
            ),
            [
                ProxyResourceReadinessTarget(
                    taskID: "line:secure",
                    taskKind: "line",
                    resourceID: "secure",
                    resourceType: "anytls",
                    outboundTags: ["anytls-secure"]
                ),
                ProxyResourceReadinessTarget(
                    taskID: "line:legacy",
                    taskKind: "line",
                    resourceID: "legacy",
                    resourceType: "trojan",
                    outboundTags: ["trojan-legacy"]
                ),
                ProxyResourceReadinessTarget(
                    taskID: "line:cipher",
                    taskKind: "line",
                    resourceID: "cipher",
                    resourceType: "shadowsocks",
                    outboundTags: ["shadowsocks-cipher"]
                ),
                ProxyResourceReadinessTarget(
                    taskID: "line:mesh",
                    taskKind: "line",
                    resourceID: "mesh",
                    resourceType: "vmess",
                    outboundTags: ["vmess-mesh"]
                ),
                ProxyResourceReadinessTarget(
                    taskID: "line:future",
                    taskKind: "line",
                    resourceID: "future",
                    resourceType: "future-proxy",
                    outboundTags: ["future-proxy-future"]
                ),
                ProxyResourceReadinessTarget(
                    taskID: "subscription:imported",
                    taskKind: "subscription",
                    resourceID: "imported",
                    resourceType: "subscription",
                    outboundTags: [
                        "subscription-imported",
                        "subscription-streaming",
                    ]
                ),
            ]
        )
    }

    func testAnyTLSBecomesReadyOnlyAfterExactOutboundProbe() throws {
        let target = ProxyResourceReadinessTarget(
            taskID: "line:secure",
            taskKind: "line",
            resourceID: "secure",
            resourceType: "anytls",
            outboundTags: ["anytls-secure"]
        )
        var events: [String] = []

        ProxyResourceReadiness.verify(
            [target],
            probe: {
                events.append(
                    "probe:\($0.outboundTags.joined(separator: ","))"
                )
            },
            markReady: {
                events.append("ready:\($0.taskID)")
            }
        )

        XCTAssertEqual(events, [
            "probe:anytls-secure",
            "ready:line:secure",
        ])
    }

    func testSubscriptionBecomesReadyOnlyAfterExactOutboundProbe() {
        let target = ProxyResourceReadinessTarget(
            taskID: "subscription:imported",
            taskKind: "subscription",
            resourceID: "imported",
            resourceType: "subscription",
            outboundTags: [
                "subscription-imported",
                "subscription-streaming",
            ]
        )
        var events: [String] = []

        ProxyResourceReadiness.verify(
            [target],
            probe: {
                events.append(
                    "probe:\($0.outboundTags.joined(separator: ","))"
                )
            },
            markReady: {
                events.append("ready:\($0.taskID)")
            }
        )

        XCTAssertEqual(events, [
            "probe:subscription-imported,subscription-streaming",
            "ready:subscription:imported",
        ])
    }

    func testProbeFailureStopsReadinessAndIsAttributedToLine() {
        let first = ProxyResourceReadinessTarget(
            taskID: "line:secure",
            taskKind: "line",
            resourceID: "secure",
            resourceType: "anytls",
            outboundTags: ["anytls-secure"]
        )
        let second = ProxyResourceReadinessTarget(
            taskID: "line:next",
            taskKind: "line",
            resourceID: "next",
            resourceType: "trojan",
            outboundTags: ["trojan-next"]
        )
        var events: [String] = []

        XCTAssertThrowsError(
            try ProxyResourceReadiness.verify(
                [first, second],
                probe: { target in
                    events.append("probe:\(target.taskID)")
                    throw ProxyResourceReadiness.failure(
                        target: target,
                        reason: "dial failed"
                    )
                },
                markReady: {
                    events.append("ready:\($0.taskID)")
                }
            )
        ) { error in
            guard let failure = error as? ConnectionRuntimeFailure else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(
                failure.code,
                ProxyResourceReadiness.lineFailureCode
            )
            XCTAssertEqual(failure.attributedTaskID, "line:secure")
        }
        XCTAssertEqual(events, ["probe:line:secure"])
    }

    func testSubscriptionProbeFailureUsesSubscriptionCode() {
        let target = ProxyResourceReadinessTarget(
            taskID: "subscription:imported",
            taskKind: "subscription",
            resourceID: "imported",
            resourceType: "subscription",
            outboundTags: ["subscription-imported"]
        )

        let failure = ProxyResourceReadiness.failure(
            target: target,
            reason: "dial failed"
        )

        XCTAssertEqual(
            failure.code,
            ProxyResourceReadiness.subscriptionFailureCode
        )
        XCTAssertEqual(
            failure.attributedTaskID,
            "subscription:imported"
        )
    }

    func testConcurrentFailureDoesNotMarkAnyTaskReady() {
        let line = ProxyResourceReadinessTarget(
            taskID: "line:secure",
            taskKind: "line",
            resourceID: "secure",
            resourceType: "anytls",
            outboundTags: ["anytls-secure"]
        )
        let subscription = ProxyResourceReadinessTarget(
            taskID: "subscription:imported",
            taskKind: "subscription",
            resourceID: "imported",
            resourceType: "subscription",
            outboundTags: [
                "subscription-imported",
                "subscription-streaming",
            ]
        )
        let lock = NSLock()
        var ready: [String] = []

        XCTAssertThrowsError(
            try ProxyResourceReadiness.verifyConcurrently(
                [line, subscription],
                maxConcurrentProbes: 2,
                probe: { target, outboundTag in
                    if outboundTag == "subscription-streaming" {
                        throw ProxyResourceReadiness.failure(
                            target: target,
                            reason: "dial failed"
                        )
                    }
                },
                markReady: {
                    lock.lock()
                    ready.append($0.taskID)
                    lock.unlock()
                }
            )
        ) { error in
            guard let failure = error as? ConnectionRuntimeFailure else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(
                failure.code,
                ProxyResourceReadiness.subscriptionFailureCode
            )
            XCTAssertEqual(
                failure.attributedTaskID,
                "subscription:imported"
            )
        }
        XCTAssertTrue(ready.isEmpty)
    }

    func testMissingExactLineOutboundFailsClosed() {
        let plan = ConnectionPlan(
            schemaVersion: 3,
            scenario: ConnectionPlanScenario(id: "scenario", name: "Scenario"),
            tasks: [lineTask(id: "secure", type: "anytls")]
        )

        XCTAssertThrowsError(
            try ProxyResourceReadiness.targets(
                plan: plan,
                lineOutbounds: [:],
                subscriptionOutbounds: [:]
            )
        ) {
            XCTAssertEqual(
                $0 as? ProxyResourceReadinessPlanError,
                .missingOutbound(kind: "line", resourceID: "secure")
            )
        }
    }

    func testMissingExactSubscriptionOutboundFailsClosed() {
        let plan = ConnectionPlan(
            schemaVersion: 3,
            scenario: ConnectionPlanScenario(id: "scenario", name: "Scenario"),
            tasks: [subscriptionTask(id: "imported")]
        )

        XCTAssertThrowsError(
            try ProxyResourceReadiness.targets(
                plan: plan,
                lineOutbounds: [:],
                subscriptionOutbounds: [:]
            )
        ) {
            XCTAssertEqual(
                $0 as? ProxyResourceReadinessPlanError,
                .missingOutbound(
                    kind: "subscription",
                    resourceID: "imported"
                )
            )
        }
    }

    private func lineTask(
        id: String,
        type: String
    ) -> ConnectionPlanTask {
        ConnectionPlanTask(
            id: "line:\(id)",
            kind: "line",
            name: id,
            preparation: "start-with-data-plane",
            resourceID: id,
            resourceType: type
        )
    }

    private func subscriptionTask(
        id: String
    ) -> ConnectionPlanTask {
        ConnectionPlanTask(
            id: "subscription:\(id)",
            kind: "subscription",
            name: id,
            preparation: "start-with-data-plane",
            resourceID: id,
            resourceType: "subscription"
        )
    }
}
