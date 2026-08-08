import AppKit
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

enum AppAppearance: String, Codable, CaseIterable, Hashable {
    case system
    case light
    case dark

    /// `nil` means the window owns no override and continues following the
    /// system after subsequent appearance changes.
    var windowAppearance: NSAppearance? {
        switch self {
        case .system:
            return nil
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
    }

    static func persisted(in defaults: UserDefaults) -> AppAppearance {
        defaults.string(forKey: "xdial.appearance")
            .flatMap(AppAppearance.init(rawValue:))
            ?? .system
    }
}

@MainActor
enum XDialWindowAppearanceController {
    static func apply(_ appearance: AppAppearance, to window: NSWindow) {
        window.appearance = appearance.windowAppearance
    }

    static func applyToApplication(_ appearance: AppAppearance) {
        NSApp.appearance = appearance.windowAppearance
        for window in NSApp.windows {
            apply(appearance, to: window)
        }
    }

}
