import Foundation

/// Account management has its own IPC contract; diagnostics remain read-only.
/// The committed Provider is the authority for whether an identity is in use.
enum TailscaleControlCommand: String, Codable {
    case status, login, logout
}

struct TailscaleControlRequest: Codable {
    let kind: String
    let version: Int
    let requestID: String
    let transactionID: String
    let identityProfileID: String
    let command: TailscaleControlCommand

    init(transactionID: String, identityProfileID: String, command: TailscaleControlCommand) {
        kind = "tailscale-control"
        version = 1
        requestID = UUID().uuidString
        self.transactionID = transactionID
        self.identityProfileID = identityProfileID
        self.command = command
    }

    var isValid: Bool {
        kind == "tailscale-control" && version == 1 && !requestID.isEmpty
            && !transactionID.isEmpty && !identityProfileID.isEmpty
            && identityProfileID.utf8.count <= 80
    }
}

struct TailscaleControlResponse: Codable {
    let requestID: String
    let transactionID: String
    let code: String
    let statusJSON: String?
}

enum TailscaleControlPolicy {
    static func rejection(request: TailscaleControlRequest, transactionID: String,
                          committed: Bool, switching: Bool, activeIdentity: String?) -> String? {
        guard request.isValid else { return "invalid-request" }
        guard request.transactionID == transactionID else { return "transaction-mismatch" }
        guard committed, !switching else { return "connection-busy" }
        guard activeIdentity == request.identityProfileID else { return "identity-not-active" }
        // Logout revokes the very identity carrying the committed connection.
        // Require the user to stop using it first; never silently cut traffic.
        if request.command == .logout { return "identity-in-use" }
        return nil
    }
}
