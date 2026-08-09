import AppKit
import SwiftUI

/// XDial 的低彩度矿物系语义色。视图只能按含义取色，不能依赖具体 hue。
enum XDialPalette {
    // 石板蓝灰：主要操作与进行中。保持克制的工具感，避免高饱和品牌蓝。
    static let accent = adaptive(
        light: XDialBrandPalette.accentLightHex,
        dark: XDialBrandPalette.accentDarkHex,
        highContrastLight: XDialBrandPalette.accentHighContrastLightHex,
        highContrastDark: XDialBrandPalette.accentHighContrastDarkHex
    )
    static let primaryAction = accent
    static let progress = accent
    static let information = accent
    static let focus = accent

    // 普通选中不是成功态，使用中性的钢灰。
    static let selection = adaptive(
        light: XDialBrandPalette.selectionLightHex,
        dark: XDialBrandPalette.selectionDarkHex,
        highContrastLight: XDialBrandPalette.selectionHighContrastLightHex,
        highContrastDark: XDialBrandPalette.selectionHighContrastDarkHex
    )

    // 松针、琥珀与氧化红分别只承担成功、提醒与失败。
    static let success = adaptive(
        light: XDialBrandPalette.successLightHex,
        dark: XDialBrandPalette.successDarkHex,
        highContrastLight: XDialBrandPalette.successHighContrastLightHex,
        highContrastDark: XDialBrandPalette.successHighContrastDarkHex
    )
    static let warning = adaptive(
        light: XDialBrandPalette.warningLightHex,
        dark: XDialBrandPalette.warningDarkHex,
        highContrastLight: XDialBrandPalette.warningHighContrastLightHex,
        highContrastDark: XDialBrandPalette.warningHighContrastDarkHex
    )
    static let danger = adaptive(
        light: XDialBrandPalette.dangerLightHex,
        dark: XDialBrandPalette.dangerDarkHex,
        highContrastLight: XDialBrandPalette.dangerHighContrastLightHex,
        highContrastDark: XDialBrandPalette.dangerHighContrastDarkHex
    )

    // 冷灰白与石墨灰形成三层表面。白天模式刻意拉开画布、卡片和边框，
    // 避免低对比屏幕把它们压成同一层。
    static let canvasNSColor = adaptiveNSColor(
        light: XDialBrandPalette.canvasLightHex,
        dark: XDialBrandPalette.canvasDarkHex,
        highContrastLight: XDialBrandPalette.canvasHighContrastLightHex,
        highContrastDark: XDialBrandPalette.canvasHighContrastDarkHex
    )
    static let canvas = Color(nsColor: canvasNSColor)
    static let surface = adaptive(
        light: XDialBrandPalette.surfaceLightHex,
        dark: XDialBrandPalette.surfaceDarkHex,
        highContrastLight: XDialBrandPalette.surfaceHighContrastLightHex,
        highContrastDark: XDialBrandPalette.surfaceHighContrastDarkHex
    )
    static let elevated = adaptive(
        light: XDialBrandPalette.elevatedLightHex,
        dark: XDialBrandPalette.elevatedDarkHex,
        highContrastLight: XDialBrandPalette.elevatedHighContrastLightHex,
        highContrastDark: XDialBrandPalette.elevatedHighContrastDarkHex
    )
    static let divider = adaptive(
        light: XDialBrandPalette.dividerLightHex,
        dark: XDialBrandPalette.dividerDarkHex,
        highContrastLight: XDialBrandPalette.dividerHighContrastLightHex,
        highContrastDark: XDialBrandPalette.dividerHighContrastDarkHex
    )
    static let textPrimary = adaptive(
        light: XDialBrandPalette.textPrimaryLightHex,
        dark: XDialBrandPalette.textPrimaryDarkHex,
        highContrastLight: XDialBrandPalette.textPrimaryHighContrastLightHex,
        highContrastDark: XDialBrandPalette.textPrimaryHighContrastDarkHex
    )
    static let textSecondary = adaptive(
        light: XDialBrandPalette.textSecondaryLightHex,
        dark: XDialBrandPalette.textSecondaryDarkHex,
        highContrastLight: XDialBrandPalette.textSecondaryHighContrastLightHex,
        highContrastDark: XDialBrandPalette.textSecondaryHighContrastDarkHex
    )
    static let disabled = adaptive(
        light: XDialBrandPalette.disabledLightHex,
        dark: XDialBrandPalette.disabledDarkHex,
        highContrastLight: XDialBrandPalette.disabledHighContrastLightHex,
        highContrastDark: XDialBrandPalette.disabledHighContrastDarkHex
    )

    private static func adaptive(
        light: UInt32,
        dark: UInt32,
        highContrastLight: UInt32,
        highContrastDark: UInt32
    ) -> Color {
        Color(nsColor: adaptiveNSColor(
            light: light,
            dark: dark,
            highContrastLight: highContrastLight,
            highContrastDark: highContrastDark
        ))
    }

    private static func adaptiveNSColor(
        light: UInt32,
        dark: UInt32,
        highContrastLight: UInt32,
        highContrastDark: UInt32
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            switch appearance.bestMatch(
                from: [
                    .accessibilityHighContrastDarkAqua,
                    .darkAqua,
                    .accessibilityHighContrastAqua,
                    .aqua,
                ]
            ) {
            case .accessibilityHighContrastDarkAqua:
                return XDialBrandPalette.color(highContrastDark)
            case .darkAqua:
                return XDialBrandPalette.color(dark)
            case .accessibilityHighContrastAqua:
                return XDialBrandPalette.color(highContrastLight)
            default:
                return XDialBrandPalette.color(light)
            }
        }
    }
}
