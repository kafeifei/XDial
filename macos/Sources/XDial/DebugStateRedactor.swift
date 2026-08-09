#if DEBUG || XDIAL_TESTING
import Foundation

enum DebugStateRedactor {
    static let secretKeys: Set<String> = [
        "vpn_password", "trojan_password", "ss_password", "vmess_uuid",
        "anytls_password",
        "tailscale_auth_key", "auth_key",
        "geoip_rule_set_url_template",
    ]

    static func redactSecrets(
        _ value: Any,
        secretKeys: Set<String> = secretKeys
    ) -> Any {
        if var dict = value as? [String: Any] {
            // Subscription 对象（有 lines + url）的 url 是带 token 的机场地址
            let isSubscription = dict["lines"] != nil && dict["url"] != nil
            for (key, child) in dict {
                if secretKeys.contains(key),
                   let string = child as? String,
                   !string.isEmpty {
                    dict[key] = "***"
                } else if key == "url",
                          isSubscription,
                          let string = child as? String,
                          !string.isEmpty {
                    dict[key] = "***"
                } else {
                    dict[key] = redactSecrets(child, secretKeys: secretKeys)
                }
            }
            return dict
        }
        if let array = value as? [Any] {
            return array.map {
                redactSecrets($0, secretKeys: secretKeys)
            }
        }
        return value
    }
}
#endif
