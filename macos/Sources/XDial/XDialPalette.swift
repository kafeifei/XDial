import AppKit
import SwiftUI

/// XDial 的低彩度矿物系语义色。视图只能按含义取色，不能依赖具体 hue。
enum XDialPalette {
    // 石板蓝灰：主要操作与进行中。保持克制的工具感，避免高饱和品牌蓝。
    static let accent = adaptive(
        light: 0x3F5C69,
        dark: 0xA2B3BC,
        highContrastLight: 0x304A56,
        highContrastDark: 0xC7D4DA
    )
    static let primaryAction = accent
    static let progress = accent
    static let information = accent
    static let focus = accent

    // 普通选中不是成功态，使用中性的钢灰。
    static let selection = adaptive(
        light: 0x46555C,
        dark: 0xA9B0B3,
        highContrastLight: 0x343C40,
        highContrastDark: 0xD6DADC
    )

    // 松针、琥珀与氧化红分别只承担成功、提醒与失败。
    static let success = adaptive(
        light: 0x3D5D46,
        dark: 0x91AD98,
        highContrastLight: 0x2F4C36,
        highContrastDark: 0xB8CCBC
    )
    static let warning = adaptive(
        light: 0x79551F,
        dark: 0xD0A562,
        highContrastLight: 0x64440F,
        highContrastDark: 0xE4C083
    )
    static let danger = adaptive(
        light: 0x884139,
        dark: 0xD98C7D,
        highContrastLight: 0x6F2C25,
        highContrastDark: 0xEFB0A4
    )

    // 冷灰白与石墨灰形成三层表面。白天模式刻意拉开画布、卡片和边框，
    // 避免低对比屏幕把它们压成同一层。
    static let canvas = adaptive(
        light: 0xE2E7EA,
        dark: 0x1B1E20,
        highContrastLight: 0xE8EBED,
        highContrastDark: 0x131618
    )
    static let surface = adaptive(
        light: 0xF8F9F9,
        dark: 0x23272A,
        highContrastLight: 0xF9FAFA,
        highContrastDark: 0x292E31
    )
    static let elevated = adaptive(
        light: 0xFFFFFF,
        dark: 0x2B3033,
        highContrastLight: 0xFFFFFF,
        highContrastDark: 0x343A3E
    )
    static let divider = adaptive(
        light: 0xA4AFB5,
        dark: 0x454C50,
        highContrastLight: 0x858F94,
        highContrastDark: 0x717B80
    )
    static let textPrimary = adaptive(
        light: 0x1C2327,
        dark: 0xEDF0F1,
        highContrastLight: 0x111416,
        highContrastDark: 0xFFFFFF
    )
    static let textSecondary = adaptive(
        light: 0x4D5960,
        dark: 0xADB4B8,
        highContrastLight: 0x3D474C,
        highContrastDark: 0xD6DCDF
    )
    static let disabled = adaptive(
        light: 0x7D888E,
        dark: 0x747C80,
        highContrastLight: 0x778186,
        highContrastDark: 0x98A1A5
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
