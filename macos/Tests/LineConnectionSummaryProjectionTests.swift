import XCTest

final class LineConnectionSummaryProjectionTests: XCTestCase {
    func testAddressFamilyCapabilityUsesLatestValidCurrentLineFacts() {
        var report = makeReport()
        report.note(
            code: "line-ipv6-egress-unavailable",
            message: "older IPv4-only result",
            taskID: "line:company",
            facts: [
                "ipv4_available": true,
                "ipv6_available": false,
                "degraded": true,
            ]
        )
        report.note(
            code: "line-address-family-ready",
            message: "latest dual-stack result",
            taskID: "line:company",
            facts: [
                "ipv4_available": true,
                "ipv6_available": true,
                "degraded": false,
            ]
        )

        XCTAssertEqual(
            LineConnectionSummaryProjection.addressFamilyCapability(
                taskID: "line:company",
                report: report
            ),
            .dualStack
        )
    }

    func testAddressFamilyCapabilityRejectsOtherLineAndInvalidFacts() {
        var report = makeReport()
        report.note(
            code: "line-address-family-ready",
            message: "belongs to another Line",
            taskID: "line:japan",
            facts: [
                "ipv4_available": true,
                "ipv6_available": true,
                "degraded": false,
            ]
        )
        report.note(
            code: "line-address-family-ready",
            message: "degraded flag contradicts dual-stack facts",
            taskID: "line:company",
            facts: [
                "ipv4_available": true,
                "ipv6_available": true,
                "degraded": true,
            ]
        )
        report.note(
            code: "line-address-family-ready",
            message: "missing structured facts",
            taskID: "line:company"
        )

        XCTAssertNil(
            LineConnectionSummaryProjection.addressFamilyCapability(
                taskID: "line:company",
                report: report
            )
        )
    }

    func testAddressFamilyCapabilityDoesNotInferUnknownLine() {
        let report = makeReport()
        XCTAssertNil(
            LineConnectionSummaryProjection.addressFamilyCapability(
                taskID: "line:unknown",
                report: report
            )
        )
    }

    func testProjectsLatestValidDiagnosticForExactTask() {
        var report = makeReport()
        report.note(
            code: "line-ipv6-egress-unavailable",
            message: "this text is not parsed",
            taskID: "line:company",
            facts: [
                "ipv4_available": true,
                "ipv6_available": false,
                "degraded": true,
            ]
        )
        report.note(
            code: "line-ipv4-egress-unavailable",
            message: "newer valid capability wins",
            taskID: "line:company",
            facts: [
                "ipv4_available": false,
                "ipv6_available": true,
                "degraded": true,
            ]
        )

        XCTAssertEqual(
            LineConnectionSummaryProjection.addressFamilyDegradation(
                taskID: "line:company",
                report: report
            ),
            .ipv6Only
        )
    }

    func testRejectsOtherTaskAndInconsistentOrTextOnlyEvents() {
        var report = makeReport()
        report.note(
            code: "line-ipv6-egress-unavailable",
            message: "must not leak across Line tasks",
            taskID: "line:japan",
            facts: [
                "ipv4_available": true,
                "ipv6_available": false,
                "degraded": true,
            ]
        )
        report.note(
            code: "unrelated-code",
            message: "line-ipv6-egress-unavailable",
            taskID: "line:company",
            facts: [
                "ipv4_available": true,
                "ipv6_available": false,
                "degraded": true,
            ]
        )
        report.note(
            code: "line-ipv4-egress-unavailable",
            message: "facts contradict code",
            taskID: "line:company",
            facts: [
                "ipv4_available": true,
                "ipv6_available": false,
                "degraded": true,
            ]
        )
        report.note(
            code: "line-ipv6-egress-unavailable",
            message: "facts are required",
            taskID: "line:company"
        )

        XCTAssertNil(
            LineConnectionSummaryProjection.addressFamilyDegradation(
                taskID: "line:company",
                report: report
            )
        )

        report.note(
            code: "line-ipv6-egress-unavailable",
            message: "unknown task must not invent a Line summary",
            taskID: "line:opaque-runtime",
            facts: [
                "ipv4_available": true,
                "ipv6_available": false,
                "degraded": true,
            ]
        )
        XCTAssertNil(
            LineConnectionSummaryProjection.addressFamilyDegradation(
                taskID: "line:opaque-runtime",
                report: report
            )
        )
    }

    func testSummaryKeepsPublicIPAndAppendsLocalizedSignal() {
        XCTAssertEqual(
            LineConnectionSummaryProjection.summary(
                publicNetworkSummary: "203.0.113.8 (US)",
                degradation: .ipv4Only,
                ipv4OnlyLabel: "仅 IPv4",
                ipv6OnlyLabel: "仅 IPv6"
            ),
            "203.0.113.8 (US) · 仅 IPv4"
        )
    }

    func testSummaryShowsSignalWithoutPublicIP() {
        XCTAssertEqual(
            LineConnectionSummaryProjection.summary(
                publicNetworkSummary: nil,
                degradation: .ipv6Only,
                ipv4OnlyLabel: "IPv4 only",
                ipv6OnlyLabel: "IPv6 only"
            ),
            "IPv6 only"
        )
        XCTAssertEqual(
            LineConnectionSummaryProjection.summary(
                publicNetworkSummary: "",
                degradation: nil,
                ipv4OnlyLabel: "IPv4 only",
                ipv6OnlyLabel: "IPv6 only"
            ),
            "—"
        )
    }

    private func makeReport() -> ConnectionReport {
        ConnectionReport(
            transactionID: "transaction-summary",
            plan: ConnectionPlan(
                schemaVersion: 3,
                scenario: ConnectionPlanScenario(
                    id: "scenario",
                    name: "Scenario"
                ),
                tasks: [
                    ConnectionPlanTask(
                        id: "line:company",
                        kind: "line",
                        name: "Company",
                        preparation: "connect",
                        resourceID: "company",
                        resourceType: "vpn"
                    ),
                    ConnectionPlanTask(
                        id: "line:japan",
                        kind: "line",
                        name: "Japan",
                        preparation: "connect",
                        resourceID: "japan",
                        resourceType: "tailscale"
                    ),
                ]
            )
        )
    }
}
