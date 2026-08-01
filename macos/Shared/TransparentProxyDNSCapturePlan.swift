import Foundation

enum TransparentProxyDNSCapturePlanError: LocalizedError {
    case invalidDomain
    case tooManyDomains

    var errorDescription: String? {
        switch self {
        case .invalidDomain:
            return "Tailscale DNS 下发了无效的分域范围"
        case .tooManyDomains:
            return "Tailscale DNS 下发的分域范围过多"
        }
    }
}

enum TransparentProxyDNSCapturePlan {
    static let maximumDomainCount = 2_048

    static func validate(_ rawDomains: [String]) throws -> [String] {
        guard rawDomains.count <= maximumDomainCount else {
            throw TransparentProxyDNSCapturePlanError.tooManyDomains
        }
        guard !rawDomains.isEmpty else {
            throw TransparentProxyDNSCapturePlanError.invalidDomain
        }
        var domains = Set<String>()
        for rawDomain in rawDomains {
            let domain = rawDomain
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            guard isValid(domain) else {
                throw TransparentProxyDNSCapturePlanError.invalidDomain
            }
            domains.insert(domain)
        }
        return domains.sorted()
    }

    private static func isValid(_ domain: String) -> Bool {
        guard
            !domain.isEmpty,
            domain.utf8.count <= 253,
            domain.utf8.allSatisfy({ byte in
                (byte >= 97 && byte <= 122) ||
                    (byte >= 48 && byte <= 57) ||
                    byte == 45 || byte == 46 || byte == 95
            })
        else {
            return false
        }
        return domain.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { label in
                !label.isEmpty && label.utf8.count <= 63
            }
    }
}
