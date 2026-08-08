import Foundation

enum TransparentProxyDNSCapturePlanError: LocalizedError {
    case invalidDomain
    case invalidRuntimeMetadata
    case noUsableRecords
    case tooManyDomains
    case tooManyRecords

    var errorDescription: String? {
        switch self {
        case .invalidDomain:
            return "Tailscale DNS 下发了无效的分域范围"
        case .invalidRuntimeMetadata:
            return "内置 Tailscale 返回了无效的 DNS 准备结果"
        case .noUsableRecords:
            return "当前 Tailnet 没有可用的成员 DNS 记录"
        case .tooManyDomains:
            return "Tailscale DNS 下发的分域范围过多"
        case .tooManyRecords:
            return "Tailscale DNS 下发的成员记录过多"
        }
    }
}

struct TransparentProxyPreparedTailscaleDNS: Equatable {
    let captureDomains: [String]
    let recordCount: Int
}

enum TransparentProxyDNSCapturePlan {
    static let maximumDomainCount = 2_048
    static let maximumRecordCount = 4_096

    private struct RuntimeMetadata: Decodable {
        let captureDomains: [String]
        let recordCount: Int
        let ownedDomainCount: Int?

        enum CodingKeys: String, CodingKey {
            case captureDomains = "capture_domains"
            case recordCount = "record_count"
            case ownedDomainCount = "owned_domain_count"
        }
    }

    static func decodePreparedTailscaleDNS(
        _ metadataJSON: String
    ) throws -> TransparentProxyPreparedTailscaleDNS {
        guard
            let data = metadataJSON.data(using: .utf8),
            let metadata = try? JSONDecoder().decode(
                RuntimeMetadata.self,
                from: data
            ),
            metadata.recordCount >= 0,
            metadata.ownedDomainCount.map({ $0 >= 0 }) ?? true
        else {
            throw TransparentProxyDNSCapturePlanError
                .invalidRuntimeMetadata
        }
        guard metadata.recordCount > 0 else {
            throw TransparentProxyDNSCapturePlanError.noUsableRecords
        }
        guard metadata.recordCount <= maximumRecordCount else {
            throw TransparentProxyDNSCapturePlanError.tooManyRecords
        }
        let domains = try validate(metadata.captureDomains)
        guard
            metadata.ownedDomainCount.map({
                $0 <= domains.count
            }) ?? true
        else {
            throw TransparentProxyDNSCapturePlanError
                .invalidRuntimeMetadata
        }
        return TransparentProxyPreparedTailscaleDNS(
            captureDomains: domains,
            recordCount: metadata.recordCount
        )
    }

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
