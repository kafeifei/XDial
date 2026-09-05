import Foundation

enum LineAddressFamilyDegradation: Equatable {
    case ipv4Only
    case ipv6Only
}

/// Projects structured, per-task connection facts into the Line summary.
///
/// The diagnostic message is deliberately ignored: UI state comes only from
/// the stable event code and its matching capability facts.
enum LineConnectionSummaryProjection {
    static func addressFamilyCapability(
        taskID: String,
        report: ConnectionReport
    ) -> LineAddressFamilyCapability? {
        guard report.tasks.contains(where: {
            $0.id == taskID && $0.kind == "line"
        }) else { return nil }

        var latest: (sequence: Int, capability: LineAddressFamilyCapability)?
        for event in report.events {
            guard event.type == "diagnostic", event.taskID == taskID,
                  let facts = event.facts,
                  let ipv4 = facts["ipv4_available"],
                  let ipv6 = facts["ipv6_available"] else {
                continue
            }
            let capability = LineAddressFamilyCapability(
                ipv4Available: ipv4, ipv6Available: ipv6
            )
            guard event.code == capability.reportCode,
                  facts["degraded"] == capability.isDegraded else { continue }
            if latest == nil || event.sequence >= latest!.sequence {
                latest = (event.sequence, capability)
            }
        }
        return latest?.capability
    }

    static func addressFamilyDegradation(
        taskID: String,
        report: ConnectionReport
    ) -> LineAddressFamilyDegradation? {
        guard report.tasks.contains(where: {
            $0.id == taskID && $0.kind == "line"
        }) else {
            return nil
        }

        return report.events.enumerated().compactMap {
            offset,
            event -> (Int, Int, LineAddressFamilyDegradation)? in
            guard
                event.type == "diagnostic",
                event.taskID == taskID,
                let degradation = degradation(from: event)
            else {
                return nil
            }
            return (event.sequence, offset, degradation)
        }.max {
            lhs,
            rhs in
            lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
        }?.2
    }

    static func summary(
        publicNetworkSummary: String?,
        degradation: LineAddressFamilyDegradation?,
        ipv4OnlyLabel: String,
        ipv6OnlyLabel: String,
        unavailablePlaceholder: String = "—"
    ) -> String {
        let degradationLabel: String?
        switch degradation {
        case .ipv4Only:
            degradationLabel = ipv4OnlyLabel
        case .ipv6Only:
            degradationLabel = ipv6OnlyLabel
        case nil:
            degradationLabel = nil
        }

        let components = [publicNetworkSummary, degradationLabel]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
        return components.isEmpty
            ? unavailablePlaceholder
            : components.joined(separator: " · ")
    }

    private static func degradation(
        from event: ConnectionReportEvent
    ) -> LineAddressFamilyDegradation? {
        guard
            let facts = event.facts,
            facts["degraded"] == true
        else {
            return nil
        }

        switch event.code {
        case "line-ipv6-egress-unavailable":
            guard
                facts["ipv4_available"] == true,
                facts["ipv6_available"] == false
            else {
                return nil
            }
            return .ipv4Only
        case "line-ipv4-egress-unavailable":
            guard
                facts["ipv4_available"] == false,
                facts["ipv6_available"] == true
            else {
                return nil
            }
            return .ipv6Only
        default:
            return nil
        }
    }
}
