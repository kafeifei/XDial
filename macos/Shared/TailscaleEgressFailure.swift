import Foundation

enum TailscaleEgressFailure {
    static func wrap(
        _ underlying: Error,
        taskID: String
    ) -> ConnectionRuntimeFailure {
        // Libbox's typed cause has already crossed gomobile through the
        // structured LineReadiness snapshot. Localizing the Tailscale message
        // must not discard that retry/cancellation/terminal classification.
        let classified = underlying as? ConnectionRuntimeFailure
        return ConnectionRuntimeFailure(
            code: classified?.code ?? "scenario-switch-prepare-failed",
            message: "内置 Tailscale 出口无法承载真实流量（\(underlying.localizedDescription)）",
            taskID: taskID,
            evidence: classified?.evidence
        )
    }
}
