import AppKit
import SwiftUI

/// XDial 的雾感植物系语义色。视图只能按含义取色，不能依赖具体 hue。
enum XDialPalette {
    // 烟紫：主要操作与进行中。偏红，不含产品自定义蓝色。
    static let accent = adaptive(
        light: 0x756174,
        dark: 0xBEA8BA,
        highContrastLight: 0x594358,
        highContrastDark: 0xD7C2D3
    )
    static let primaryAction = accent
    static let progress = accent
    static let information = accent
    static let focus = accent

    // 普通选中不是成功态，使用中性的暖灰褐。
    static let selection = adaptive(
        light: 0x6F685F,
        dark: 0xB8AFA4,
        highContrastLight: 0x514A43,
        highContrastDark: 0xD6CDC2
    )

    // 鼠尾草、燕麦与陶土分别只承担成功、提醒与失败。
    static let success = adaptive(
        light: 0x60745B,
        dark: 0x94AA8E,
        highContrastLight: 0x465A42,
        highContrastDark: 0xB2C5AC
    )
    static let warning = adaptive(
        light: 0x91663A,
        dark: 0xC69A65,
        highContrastLight: 0x704817,
        highContrastDark: 0xDDB681
    )
    static let danger = adaptive(
        light: 0xA35145,
        dark: 0xD18470,
        highContrastLight: 0x81372E,
        highContrastDark: 0xE7A08D
    )

    // 暖瓷白与炭灰形成三层表面，不使用纯白或纯黑。
    static let canvas = adaptive(
        light: 0xF1EDE5,
        dark: 0x1D1B19,
        highContrastLight: 0xEDE7DD,
        highContrastDark: 0x171513
    )
    static let surface = adaptive(
        light: 0xF8F5EF,
        dark: 0x25221F,
        highContrastLight: 0xFAF7F1,
        highContrastDark: 0x292521
    )
    static let elevated = adaptive(
        light: 0xFEFBF6,
        dark: 0x2F2B27,
        highContrastLight: 0xFFFDF9,
        highContrastDark: 0x37312C
    )
    static let divider = adaptive(
        light: 0xD6CFC4,
        dark: 0x49423B,
        highContrastLight: 0x91877D,
        highContrastDark: 0x756C62
    )
    static let textPrimary = adaptive(
        light: 0x2B2723,
        dark: 0xEEE8DF,
        highContrastLight: 0x171411,
        highContrastDark: 0xFFFDF8
    )
    static let textSecondary = adaptive(
        light: 0x6F685F,
        dark: 0xB8AFA4,
        highContrastLight: 0x514A43,
        highContrastDark: 0xD6CDC2
    )
    static let disabled = adaptive(
        light: 0x9D968D,
        dark: 0x77716A,
        highContrastLight: 0x817970,
        highContrastDark: 0x989087
    )

    private static func adaptive(
        light: UInt32,
        dark: UInt32,
        highContrastLight: UInt32,
        highContrastDark: UInt32
    ) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                switch appearance.bestMatch(
                    from: [
                        .accessibilityHighContrastDarkAqua,
                        .darkAqua,
                        .accessibilityHighContrastAqua,
                        .aqua,
                    ]
                ) {
                case .accessibilityHighContrastDarkAqua:
                    return nsColor(highContrastDark)
                case .darkAqua:
                    return nsColor(dark)
                case .accessibilityHighContrastAqua:
                    return nsColor(highContrastLight)
                default:
                    return nsColor(light)
                }
            }
        )
    }

    private static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
