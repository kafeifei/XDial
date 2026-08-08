import Foundation

/// 配置只保存 `id`；`symbol` 是当前 macOS 的绘制实现，可以独立演进。
struct ScenarioIconPreset: Identifiable, Hashable {
    let id: String
    let symbol: String
    let zhName: String
    let enName: String
    fileprivate let nameKeywords: [String]
    fileprivate let ssidKeywords: [String]
}

enum ScenarioIconCatalog {
    static let presets: [ScenarioIconPreset] = [
        preset(
            "home", "house", "家庭", "Home",
            names: ["家庭", "家里", "家用", "住宅", "home", "house", "residential"],
            ssids: ["home", "house", "family"]
        ),
        preset(
            "family", "person.2", "家人", "Family",
            names: ["家人", "亲子", "儿童", "family", "kids", "child", "parents"]
        ),
        preset(
            "office", "building.2", "公司", "Office",
            names: ["公司", "办公", "企业", "office", "corp", "company", "enterprise"],
            ssids: ["office", "corp", "company", "enterprise"]
        ),
        preset(
            "work", "briefcase", "工作", "Work",
            names: ["工作", "商务", "远程办公", "work", "business", "remote work"]
        ),
        preset(
            "hotel", "bed.double", "酒店", "Hotel",
            names: ["酒店", "旅馆", "住宿", "宾馆", "全季", "华住", "hotel", "motel", "inn", "lodge"],
            ssids: ["hotel", "motel", "inn", "lodge", "全季", "华住", "汉庭", "亚朵", "hilton", "marriott", "hyatt", "airbnb"]
        ),
        preset(
            "travel", "airplane", "旅行", "Travel",
            names: ["旅行", "出差", "机场", "飞行", "travel", "trip", "airport", "flight"],
            ssids: ["airport", "airline", "flight"]
        ),
        preset(
            "commute", "car", "通勤", "Commute",
            names: ["通勤", "车载", "汽车", "commute", "car", "drive"],
            ssids: ["car", "auto"]
        ),
        preset(
            "cafe", "cup.and.saucer", "咖啡馆", "Café",
            names: ["咖啡", "咖啡馆", "coffee", "cafe", "café"],
            ssids: ["coffee", "cafe", "café", "starbucks"]
        ),
        preset(
            "public_wifi", "wifi", "公共 Wi-Fi", "Public Wi-Fi",
            names: ["公共", "免费", "访客", "public", "free", "guest", "wifi"],
            ssids: ["public", "free", "guest", "wifi"]
        ),
        preset(
            "hotspot", "personalhotspot", "热点", "Hotspot",
            names: ["热点", "随身", "共享", "hotspot", "tether", "mobile"],
            ssids: ["hotspot", "iphone", "android", "mobile"]
        ),
        preset(
            "campus", "graduationcap", "校园", "Campus",
            names: ["学校", "校园", "大学", "school", "campus", "university", "college"],
            ssids: ["campus", "university", "college", "eduroam"]
        ),
        preset(
            "gaming", "gamecontroller", "游戏", "Gaming",
            names: ["游戏", "电竞", "game", "gaming", "steam", "console"]
        ),
        preset(
            "video", "play.rectangle", "影音", "Video",
            names: ["影音", "视频", "电视", "电影", "media", "video", "tv", "movie", "streaming"]
        ),
        preset(
            "music", "music.note", "音乐", "Music",
            names: ["音乐", "音频", "music", "audio", "radio"]
        ),
        preset(
            "development", "terminal", "开发", "Development",
            names: ["开发", "编程", "测试", "dev", "development", "code", "coding", "test"]
        ),
        preset(
            "server", "externaldrive", "服务器", "Server",
            names: ["服务器", "机房", "实验室", "server", "homelab", "nas", "lab"]
        ),
        preset(
            "cloud", "cloud", "云端", "Cloud",
            names: ["云端", "cloud", "aws", "gcp", "azure"]
        ),
        preset(
            "privacy", "hand.raised", "隐私", "Privacy",
            names: ["隐私", "匿名", "privacy", "private", "anonymous"]
        ),
        preset(
            "regional", "globe.asia.australia", "国内区域", "Local Region",
            names: ["国内", "本地", "中国", "local", "region", "china", "cn", "domestic"]
        ),
        preset(
            "global", "globe", "全局", "Global",
            names: ["全局", "全代理", "海外", "国际", "global", "worldwide", "overseas", "international"]
        ),
        preset(
            "direct", "arrow.left.arrow.right", "直连", "Direct",
            names: ["直连", "不代理", "direct", "bypass", "no proxy"]
        ),
        preset(
            "secure", "lock.shield", "安全 VPN", "Secure VPN",
            names: ["安全", "代理", "secure", "vpn", "proxy", "tunnel"]
        ),
        preset(
            "general", "square.grid.2x2", "通用", "General",
            names: []
        ),
    ]

    static let fallback = presets.last!

    static func preset(forKey key: String?) -> ScenarioIconPreset? {
        guard let key, !key.isEmpty else { return nil }
        return presets.first { $0.id == key }
    }

    /// 未知的手动 Key 必须稳定回退，不能悄悄重新进入自动模式。
    static func resolvedPreset(for scenario: Scenario) -> ScenarioIconPreset {
        if let override = scenario.iconOverride {
            return preset(forKey: override) ?? fallback
        }
        return automaticPreset(name: scenario.name, ssids: scenario.matchSSIDs)
    }

    static func automaticPreset(
        name: String,
        ssids: [String]
    ) -> ScenarioIconPreset {
        if let match = bestMatch(in: [name], keywords: \.nameKeywords) {
            return match
        }
        if let match = bestMatch(in: ssids, keywords: \.ssidKeywords) {
            return match
        }
        return fallback
    }

    private static func bestMatch(
        in values: [String],
        keywords: KeyPath<ScenarioIconPreset, [String]>
    ) -> ScenarioIconPreset? {
        var best: (preset: ScenarioIconPreset, score: Int)?
        for (valueIndex, value) in values.enumerated() {
            let normalizedValue = normalize(value)
            guard !normalizedValue.isEmpty else { continue }
            for preset in presets {
                for keyword in preset[keyPath: keywords] {
                    guard let score = matchScore(
                        keyword: keyword,
                        in: normalizedValue
                    ) else { continue }
                    // 更长、更精确的关键词优先；多个 SSID 同分时保留保存顺序。
                    let orderedScore = score
                        + semanticPriority(for: preset.id)
                        - valueIndex
                    if best == nil || orderedScore > best!.score {
                        best = (preset, orderedScore)
                    }
                }
            }
        }
        return best?.preset
    }

    /// 位置和用途的明确词优先于 “Guest/Wi-Fi/VPN” 这类泛词。
    private static func semanticPriority(for presetID: String) -> Int {
        switch presetID {
        case "public_wifi":
            return 0
        case "secure":
            return 100
        case "general":
            return -1_000
        default:
            return 300
        }
    }

    private static func matchScore(
        keyword: String,
        in normalizedValue: String
    ) -> Int? {
        let normalizedKeyword = normalize(keyword)
        guard !normalizedKeyword.isEmpty else { return nil }
        let length = normalizedKeyword.count
        if normalizedValue == normalizedKeyword {
            return 5_000 + length
        }

        let words = normalizedValue.split(separator: " ").map(String.init)
        if words.contains(normalizedKeyword) {
            return 4_000 + length
        }

        let containsNonASCII = normalizedKeyword.unicodeScalars.contains {
            !$0.isASCII
        }
        let allowsEmbeddedMatch = containsNonASCII
            || length >= 5
            || normalizedKeyword == "vpn"
        guard allowsEmbeddedMatch,
              normalizedValue.contains(normalizedKeyword) else { return nil }
        return 2_000 + length
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }

    private static func preset(
        _ id: String,
        _ symbol: String,
        _ zhName: String,
        _ enName: String,
        names: [String],
        ssids: [String] = []
    ) -> ScenarioIconPreset {
        ScenarioIconPreset(
            id: id,
            symbol: symbol,
            zhName: zhName,
            enName: enName,
            nameKeywords: names,
            ssidKeywords: ssids
        )
    }
}
