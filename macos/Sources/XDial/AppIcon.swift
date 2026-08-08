import AppKit

enum AppIcon {
    static func base(size: CGFloat) -> NSImage {
        primary(size: size, connected: true)
    }

    /// Finder 里 XDial.app 的主图标只是月球，不表达“设置”。
    static func primary(
        size: CGFloat,
        connected: Bool
    ) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSGraphicsContext.current?.shouldAntialias = true
        drawMoon(
            in: NSRect(
                x: size * 0.09,
                y: size * 0.09,
                width: size * 0.82,
                height: size * 0.82
            ),
            connected: connected,
            castsShadow: true
        )
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// 设置/安装窗口打开时 XDial 才临时出现在 Dock，这个
    /// 运行时图标在同一月背指纹右下角叠加齿轮。
    static func dock(size: CGFloat, connected: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSGraphicsContext.current?.shouldAntialias = true

        let moonRect = NSRect(
            x: size * 0.09,
            y: size * 0.14,
            width: size * 0.78,
            height: size * 0.78
        )
        drawMoon(
            in: moonRect,
            connected: connected,
            castsShadow: true
        )
        drawGearBadge(size: size)

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// 菜单栏使用 2x 像素密度单独绘制；最终布局尺寸由
    /// `MenuBarLabel` 控制，这里不引入额外透明边距。
    static func menuBar(connected: Bool) -> NSImage {
        let canvas: CGFloat = 32
        let image = NSImage(size: NSSize(width: canvas, height: canvas))
        image.lockFocus()
        NSGraphicsContext.current?.shouldAntialias = true
        drawMoon(
            in: NSRect(x: 1, y: 1, width: 30, height: 30),
            connected: connected,
            castsShadow: false
        )
        image.unlockFocus()
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = false
        return image
    }

    @MainActor
    static func applyDockState(connected: Bool) {
        NSApp.applicationIconImage = dock(size: 512, connected: connected)
    }

    private static func drawMoon(
        in rect: NSRect,
        connected: Bool,
        castsShadow: Bool
    ) {
        let lunarDisc = NSBezierPath(ovalIn: rect)

        if castsShadow {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
            shadow.shadowBlurRadius = rect.width * 0.035
            shadow.shadowOffset = NSSize(
                width: 0,
                height: -rect.width * 0.022
            )
            shadow.set()
            NSColor.black.withAlphaComponent(0.18).setFill()
            lunarDisc.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        let surfaceLight = NSColor(
            calibratedWhite: connected ? 0.98 : 0.78,
            alpha: 1
        )
        let surfaceShade = NSColor(
            calibratedWhite: connected ? 0.78 : 0.58,
            alpha: 1
        )
        NSGradient(starting: surfaceShade, ending: surfaceLight)?
            .draw(in: lunarDisc, angle: 55)

        NSGraphicsContext.saveGraphicsState()
        lunarDisc.addClip()

        // 南极—艾特肯盆地是月背下方的大范围暗斑，不画成一枚边缘整齐的巨坑。
        NSColor(
            calibratedWhite: connected ? 0.60 : 0.40,
            alpha: 0.9
        ).setFill()
        NSBezierPath(
            ovalIn: normalizedRect(
                x: 0.09,
                y: 0.03,
                width: 0.78,
                height: 0.38,
                in: rect
            )
        ).fill()
        NSColor(
            calibratedWhite: connected ? 0.68 : 0.47,
            alpha: 0.78
        ).setFill()
        NSBezierPath(
            ovalIn: normalizedRect(
                x: 0.16,
                y: 0.08,
                width: 0.65,
                height: 0.27,
                in: rect
            )
        ).fill()

        drawCrater(
            center: normalizedPoint(x: 0.20, y: 0.56, in: rect),
            radius: rect.width * 0.125,
            connected: connected
        )
        drawCrater(
            center: normalizedPoint(x: 0.72, y: 0.25, in: rect),
            radius: rect.width * 0.094,
            connected: connected
        )
        drawCrater(
            center: normalizedPoint(x: 0.74, y: 0.72, in: rect),
            radius: rect.width * 0.081,
            connected: connected
        )
        drawCrater(
            center: normalizedPoint(x: 0.34, y: 0.81, in: rect),
            radius: rect.width * 0.053,
            connected: connected
        )

        NSGraphicsContext.restoreGraphicsState()

        NSColor(
            calibratedWhite: connected ? 0.96 : 0.72,
            alpha: 0.9
        ).setStroke()
        lunarDisc.lineWidth = max(1, rect.width * 0.032)
        lunarDisc.stroke()
    }

    private static func drawGearBadge(size: CGFloat) {
        let badgeRect = NSRect(
            x: size * 0.64,
            y: size * 0.065,
            width: size * 0.30,
            height: size * 0.30
        )
        let badge = NSBezierPath(ovalIn: badgeRect)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.34)
        shadow.shadowBlurRadius = size * 0.022
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
        shadow.set()
        NSColor(calibratedWhite: 0.97, alpha: 0.98).setFill()
        badge.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor(calibratedWhite: 0.62, alpha: 1).setStroke()
        badge.lineWidth = max(1, size * 0.012)
        badge.stroke()

        guard let symbol = NSImage(
            systemSymbolName: "gearshape.fill",
            accessibilityDescription: nil
        ) else {
            return
        }
        let pointConfiguration = NSImage.SymbolConfiguration(
            pointSize: size * 0.17,
            weight: .semibold
        )
        let paletteConfiguration = NSImage.SymbolConfiguration(
            paletteColors: [NSColor(calibratedWhite: 0.27, alpha: 1)]
        )
        guard let configured = symbol.withSymbolConfiguration(
            pointConfiguration.applying(paletteConfiguration)
        ) else {
            return
        }
        let gearSide = size * 0.19
        configured.draw(
            in: NSRect(
                x: badgeRect.midX - gearSide / 2,
                y: badgeRect.midY - gearSide / 2,
                width: gearSide,
                height: gearSide
            ),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    private static func normalizedRect(
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        in rect: NSRect
    ) -> NSRect {
        NSRect(
            x: rect.minX + rect.width * x,
            y: rect.minY + rect.height * y,
            width: rect.width * width,
            height: rect.height * height
        )
    }

    private static func normalizedPoint(
        x: CGFloat,
        y: CGFloat,
        in rect: NSRect
    ) -> NSPoint {
        NSPoint(
            x: rect.minX + rect.width * x,
            y: rect.minY + rect.height * y
        )
    }

    private static func drawCrater(
        center: NSPoint,
        radius: CGFloat,
        connected: Bool
    ) {
        let rect = NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        let crater = NSBezierPath(ovalIn: rect)
        NSColor(
            calibratedWhite: connected ? 0.36 : 0.22,
            alpha: 0.92
        ).setFill()
        crater.fill()
        NSColor(
            calibratedWhite: connected ? 0.88 : 0.66,
            alpha: 0.95
        ).setStroke()
        crater.lineWidth = max(1, radius * 0.35)
        crater.stroke()
    }
}
