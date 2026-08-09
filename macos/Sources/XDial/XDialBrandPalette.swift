import AppKit

/// Fixed brand colors shared by generated assets and the adaptive UI palette.
/// Keep raw values here so the app icon generator cannot drift into a separate
/// color system from the SwiftUI surfaces.
enum XDialBrandPalette {
    static let accentLightHex: UInt32 = 0x3F5C69
    static let accentDarkHex: UInt32 = 0xA2B3BC
    static let accentHighContrastLightHex: UInt32 = 0x304A56
    static let accentHighContrastDarkHex: UInt32 = 0xC7D4DA

    static let selectionLightHex: UInt32 = 0x46555C
    static let selectionDarkHex: UInt32 = 0xA9B0B3
    static let selectionHighContrastLightHex: UInt32 = 0x343C40
    static let selectionHighContrastDarkHex: UInt32 = 0xD6DADC

    static let successLightHex: UInt32 = 0x3D5D46
    static let successDarkHex: UInt32 = 0x91AD98
    static let successHighContrastLightHex: UInt32 = 0x2F4C36
    static let successHighContrastDarkHex: UInt32 = 0xB8CCBC

    static let warningLightHex: UInt32 = 0x79551F
    static let warningDarkHex: UInt32 = 0xD0A562
    static let warningHighContrastLightHex: UInt32 = 0x64440F
    static let warningHighContrastDarkHex: UInt32 = 0xE4C083

    static let dangerLightHex: UInt32 = 0x884139
    static let dangerDarkHex: UInt32 = 0xD98C7D
    static let dangerHighContrastLightHex: UInt32 = 0x6F2C25
    static let dangerHighContrastDarkHex: UInt32 = 0xEFB0A4

    static let canvasLightHex: UInt32 = 0xE2E7EA
    static let canvasDarkHex: UInt32 = 0x1B1E20
    static let canvasHighContrastLightHex: UInt32 = 0xE8EBED
    static let canvasHighContrastDarkHex: UInt32 = 0x131618

    static let surfaceLightHex: UInt32 = 0xF8F9F9
    static let surfaceDarkHex: UInt32 = 0x23272A
    static let surfaceHighContrastLightHex: UInt32 = 0xF9FAFA
    static let surfaceHighContrastDarkHex: UInt32 = 0x292E31

    static let elevatedLightHex: UInt32 = 0xFFFFFF
    static let elevatedDarkHex: UInt32 = 0x2B3033
    static let elevatedHighContrastLightHex: UInt32 = 0xFFFFFF
    static let elevatedHighContrastDarkHex: UInt32 = 0x343A3E

    static let dividerLightHex: UInt32 = 0xA4AFB5
    static let dividerDarkHex: UInt32 = 0x454C50
    static let dividerHighContrastLightHex: UInt32 = 0x858F94
    static let dividerHighContrastDarkHex: UInt32 = 0x717B80

    static let textPrimaryLightHex: UInt32 = 0x1C2327
    static let textPrimaryDarkHex: UInt32 = 0xEDF0F1
    static let textPrimaryHighContrastLightHex: UInt32 = 0x111416
    static let textPrimaryHighContrastDarkHex: UInt32 = 0xFFFFFF

    static let textSecondaryLightHex: UInt32 = 0x4D5960
    static let textSecondaryDarkHex: UInt32 = 0xADB4B8
    static let textSecondaryHighContrastLightHex: UInt32 = 0x3D474C
    static let textSecondaryHighContrastDarkHex: UInt32 = 0xD6DCDF

    static let disabledLightHex: UInt32 = 0x7D888E
    static let disabledDarkHex: UInt32 = 0x747C80
    static let disabledHighContrastLightHex: UInt32 = 0x778186
    static let disabledHighContrastDarkHex: UInt32 = 0x98A1A5

    static let accent = color(accentLightHex)
    static let accentHighlight = color(accentDarkHex)
    static let selection = color(selectionLightHex)
    static let success = color(successLightHex)
    static let canvas = color(canvasLightHex)
    static let surface = color(surfaceLightHex)
    static let divider = color(dividerLightHex)
    static let textPrimary = color(textPrimaryLightHex)
    static let textSecondary = color(textSecondaryLightHex)
    static let disabled = color(disabledLightHex)

    static func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
