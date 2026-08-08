import Foundation
import SwiftUI

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

enum AppAppearance: String, Codable, CaseIterable, Hashable {
    case system
    case light
    case dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}
