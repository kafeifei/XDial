import Foundation

struct ProxyResourceReadinessTarget: Equatable {
    let taskID: String
    let taskKind: String
    let resourceID: String
    let resourceType: String
    let outboundTags: [String]

    var failureCode: String {
        switch taskKind {
        case "subscription":
            ProxyResourceReadiness.subscriptionFailureCode
        default:
            ProxyResourceReadiness.lineFailureCode
        }
    }

    var readyCode: String {
        switch taskKind {
        case "subscription":
            "proxy-subscription-egress-ready"
        default:
            "proxy-line-egress-ready"
        }
    }

    var readyMessage: String {
        switch taskKind {
        case "subscription":
            "代理订阅已通过真实出口探测"
        default:
            "代理线路已通过真实出口探测"
        }
    }

    var failureMessagePrefix: String {
        switch taskKind {
        case "subscription":
            "代理订阅无法承载真实流量"
        default:
            "代理线路无法承载真实流量"
        }
    }
}

enum ProxyResourceReadinessPlanError: LocalizedError, Equatable {
    case missingOutbound(kind: String, resourceID: String)

    var errorDescription: String? {
        switch self {
        case let .missingOutbound(kind, resourceID):
            switch kind {
            case "subscription":
                "订阅 \(resourceID) 缺少本次连接对应的精确出口"
            default:
                "线路 \(resourceID) 缺少本次连接对应的精确出口"
            }
        }
    }
}

/// Selects and verifies active proxy resources whose protocol readiness cannot
/// be inferred merely because sing-box accepted and started the full config.
///
/// Direct, AnyConnect, and Tailscale have separate readiness contracts. Every
/// other active Line and every active Subscription must prove that its exact
/// outbound can carry a real HTTPS request before the system Transparent Proxy
/// is committed.
enum ProxyResourceReadiness {
    static let lineFailureCode = "proxy-line-egress-unavailable"
    static let subscriptionFailureCode =
        "proxy-subscription-egress-unavailable"

    static func targets(
        plan: ConnectionPlan,
        lineOutbounds: [String: String],
        subscriptionOutbounds: [String: [String]]
    ) throws -> [ProxyResourceReadinessTarget] {
        try plan.tasks.compactMap { task in
            let outboundTags: [String]?
            switch task.kind {
            case "line"
                where !["direct", "vpn", "tailscale"].contains(
                    task.resourceType
                ):
                outboundTags = lineOutbounds[task.resourceID].map { [$0] }
            case "subscription":
                outboundTags = subscriptionOutbounds[task.resourceID]
            default:
                return nil
            }
            guard
                !task.resourceID.isEmpty,
                let outboundTags,
                !outboundTags.isEmpty,
                outboundTags.allSatisfy({ !$0.isEmpty }),
                Set(outboundTags).count == outboundTags.count
            else {
                throw ProxyResourceReadinessPlanError.missingOutbound(
                    kind: task.kind,
                    resourceID: task.resourceID
                )
            }
            return ProxyResourceReadinessTarget(
                taskID: task.id,
                taskKind: task.kind,
                resourceID: task.resourceID,
                resourceType: task.resourceType,
                outboundTags: outboundTags
            )
        }
    }

    static func verify(
        _ targets: [ProxyResourceReadinessTarget],
        probe: (ProxyResourceReadinessTarget) throws -> Void,
        markReady: (ProxyResourceReadinessTarget) -> Void
    ) rethrows {
        for target in targets {
            try probe(target)
            markReady(target)
        }
    }

    /// Probes distinct active outbounds with a bounded fan-out. A subscription
    /// can route to several generated groups; probing them serially would turn
    /// the per-probe timeout into an unbounded Network Extension start time.
    /// No task is marked ready until every exact outbound in the batch passed.
    static func verifyConcurrently(
        _ targets: [ProxyResourceReadinessTarget],
        maxConcurrentProbes: Int = 4,
        probe:
            @escaping (
                ProxyResourceReadinessTarget,
                String
            ) throws -> Void,
        markReady: (ProxyResourceReadinessTarget) -> Void
    ) throws {
        let requests = targets.flatMap { target in
            target.outboundTags.map { (target, $0) }
        }
        guard !requests.isEmpty else { return }

        let state = ProxyResourceProbeState()
        let queue = OperationQueue()
        queue.name = "com.kafeifei.xdial.proxy-readiness"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = max(
            1,
            min(maxConcurrentProbes, requests.count)
        )
        for (target, outboundTag) in requests {
            queue.addOperation {
                guard state.shouldStart else { return }
                do {
                    try probe(target, outboundTag)
                } catch {
                    state.record(error)
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        if let failure = state.failure {
            throw failure
        }
        for target in targets {
            markReady(target)
        }
    }

    static func failure(
        target: ProxyResourceReadinessTarget,
        reason: String
    ) -> ConnectionRuntimeFailure {
        ConnectionRuntimeFailure(
            code: target.failureCode,
            message: "\(target.failureMessagePrefix)（\(reason)）",
            taskID: target.taskID,
            evidence: nil
        )
    }
}

private final class ProxyResourceProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFailure: Error?

    var shouldStart: Bool {
        lock.lock()
        let value = storedFailure == nil
        lock.unlock()
        return value
    }

    var failure: Error? {
        lock.lock()
        let value = storedFailure
        lock.unlock()
        return value
    }

    func record(_ error: Error) {
        lock.lock()
        if storedFailure == nil {
            storedFailure = error
        }
        lock.unlock()
    }
}
