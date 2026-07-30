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

    static var system: Lang {
        let pref = Locale.preferredLanguages.first ?? "en"
        return pref.hasPrefix("zh") ? .zh : .en
    }
}
