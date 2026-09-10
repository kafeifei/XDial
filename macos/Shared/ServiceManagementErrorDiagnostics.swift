import Foundation

/// Service-management error numbers overlap POSIX and filesystem errors. Only
/// the API's own domain can identify AlreadyRegistered or JobNotFound.
enum ServiceManagementErrorDiagnostics {
    static func matches(_ error: Error, domain: String, code: Int) -> Bool {
        let value = error as NSError
        return value.domain == domain && value.code == code
    }

    /// Retain the error chain without logging arbitrary userInfo payloads.
    static func summary(_ error: Error?) -> String {
        guard let error else { return "error=none" }
        var current: NSError? = error as NSError
        var visited = Set<ObjectIdentifier>()
        var parts: [String] = []
        for depth in 0..<4 {
            guard let value = current, visited.insert(ObjectIdentifier(value)).inserted else { break }
            let domain = value.domain
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            let prefix = depth == 0 ? "error" : "underlying\(depth)"
            parts.append("\(prefix).domain=\(domain) \(prefix).code=\(value.code)")
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return parts.joined(separator: " ")
    }
}
