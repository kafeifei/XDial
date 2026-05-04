import Foundation

enum Lang: String, Codable, CaseIterable {
    case zh = "zh-CN"
    case en = "en"

    var displayName: String {
        switch self {
        case .zh: return "简体中文"
        case .en: return "English"
        }
    }

    /// ip-api.com 支持的语言代码
    var ipAPILang: String {
        switch self {
        case .zh: return "zh-CN"
        case .en: return "en"
        }
    }

    static var system: Lang {
        let pref = Locale.preferredLanguages.first ?? "en"
        return pref.hasPrefix("zh") ? .zh : .en
    }
}
