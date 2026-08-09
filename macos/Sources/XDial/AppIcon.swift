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
    static func menuBar(
        connected: Bool,
        hasError: Bool = false,
        updateAvailable: Bool = false
    ) -> NSImage {
        let canvas: CGFloat = 44
        let image = NSImage(size: NSSize(width: canvas, height: canvas))
        image.lockFocus()
        NSGraphicsContext.current?.shouldAntialias = true
        drawMoon(
            in: NSRect(x: 1, y: 1, width: 42, height: 42),
            connected: connected,
            castsShadow: false
        )
        if hasError {
            drawErrorBadge(in: NSRect(x: 27, y: 1, width: 16, height: 16))
        } else if updateAvailable {
            drawUpdateBadge(in: NSRect(x: 34, y: 34, width: 9, height: 9))
        }
        image.unlockFocus()
        image.size = NSSize(width: 20, height: 20)
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

        let surfaceLight = connected
            ? XDialBrandPalette.surface
            : XDialBrandPalette.divider
        let surfaceShade = connected
            ? XDialBrandPalette.accentHighlight
            : XDialBrandPalette.disabled
        NSGradient(starting: surfaceShade, ending: surfaceLight)?
            .draw(in: lunarDisc, angle: 55)

        NSGraphicsContext.saveGraphicsState()
        lunarDisc.addClip()

        // 南极—艾特肯盆地是月背下方的大范围暗斑，不画成一枚边缘整齐的巨坑。
        (connected
            ? XDialBrandPalette.accent.withAlphaComponent(0.86)
            : XDialBrandPalette.disabled.withAlphaComponent(0.94)
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
        (connected
            ? XDialBrandPalette.accentHighlight.withAlphaComponent(0.78)
            : XDialBrandPalette.disabled.withAlphaComponent(0.82)
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

        // 外沿只是月球轮廓，不承担连接语义；连接状态只由整个月面的
        // 明暗表达，避免在菜单栏出现一圈突兀的成功绿。
        XDialBrandPalette.selection.withAlphaComponent(0.82).setStroke()
        lunarDisc.lineWidth = max(1, rect.width * 0.028)
        lunarDisc.stroke()
    }

    /// 错误与更新都只是菜单栏的附加状态。错误优先级更高，并通过
    /// “实心徽标 + 叹号”表达，避免只靠红色与更新圆点区分。
    private static func drawErrorBadge(in rect: NSRect) {
        let badge = NSBezierPath(ovalIn: rect)
        XDialBrandPalette.surface.setStroke()
        badge.lineWidth = 2.2
        badge.stroke()
        XDialBrandPalette.danger.setFill()
        badge.fill()

        XDialBrandPalette.surface.setFill()
        NSBezierPath(
            roundedRect: NSRect(
                x: rect.midX - 1.05,
                y: rect.minY + rect.height * 0.39,
                width: 2.1,
                height: rect.height * 0.34
            ),
            xRadius: 1.05,
            yRadius: 1.05
        ).fill()
        NSBezierPath(
            ovalIn: NSRect(
                x: rect.midX - 1.15,
                y: rect.minY + rect.height * 0.19,
                width: 2.3,
                height: 2.3
            )
        ).fill()
    }

    private static func drawUpdateBadge(in rect: NSRect) {
        let badge = NSBezierPath(ovalIn: rect)
        XDialBrandPalette.surface.setStroke()
        badge.lineWidth = 2
        badge.stroke()
        XDialBrandPalette.danger.setFill()
        badge.fill()
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
        XDialBrandPalette.surface.withAlphaComponent(0.98).setFill()
        badge.fill()
        NSGraphicsContext.restoreGraphicsState()

        XDialBrandPalette.divider.setStroke()
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
            paletteColors: [XDialBrandPalette.accent]
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
        (connected
            ? XDialBrandPalette.selection.withAlphaComponent(0.94)
            : XDialBrandPalette.textSecondary.withAlphaComponent(0.94)
        ).setFill()
        crater.fill()
        (connected
            ? XDialBrandPalette.canvas.withAlphaComponent(0.95)
            : XDialBrandPalette.divider.withAlphaComponent(0.95)
        ).setStroke()
        crater.lineWidth = max(1, radius * 0.35)
        crater.stroke()
    }
}
