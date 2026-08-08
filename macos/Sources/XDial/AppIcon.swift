import AppKit

enum AppIcon {
    static func base(size: CGFloat) -> NSImage {
        dock(size: size, connected: false)
    }

    /// Dock 和应用切换器使用完整的月球背面图标。
    static func dock(size: CGFloat, connected: Bool = false) -> NSImage {
        guard let source = sourceImage(connected: connected) else {
            return NSImage(size: NSSize(width: size, height: size))
        }

        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(
            in: NSRect(x: 0, y: 0, width: size, height: size),
            from: NSRect(origin: .zero, size: source.size),
            operation: .copy,
            fraction: 1
        )
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// 菜单栏使用为 18pt 单独绘制的月背指纹；完整位图缩小时地貌会糊成灰球。
    static func menuBar(connected: Bool) -> NSImage {
        let canvas: CGFloat = 36
        let image = NSImage(size: NSSize(width: canvas, height: canvas))
        image.lockFocus()
        NSGraphicsContext.current?.shouldAntialias = true

        let lunarDisc = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 32, height: 32))
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
        NSBezierPath(ovalIn: NSRect(x: 5, y: 3, width: 24, height: 12)).fill()
        NSColor(
            calibratedWhite: connected ? 0.68 : 0.47,
            alpha: 0.78
        ).setFill()
        NSBezierPath(ovalIn: NSRect(x: 7, y: 4.5, width: 20, height: 8.5)).fill()

        drawMenuBarCrater(
            center: NSPoint(x: 8.5, y: 20),
            radius: 4,
            connected: connected,
            hasCentralPeak: false
        )
        drawMenuBarCrater(
            center: NSPoint(x: 25, y: 10),
            radius: 3,
            connected: connected,
            hasCentralPeak: true
        )
        drawMenuBarCrater(
            center: NSPoint(x: 25.5, y: 25),
            radius: 2.6,
            connected: connected,
            hasCentralPeak: false
        )
        drawMenuBarCrater(
            center: NSPoint(x: 13, y: 28),
            radius: 1.7,
            connected: connected,
            hasCentralPeak: false
        )

        NSGraphicsContext.restoreGraphicsState()

        NSColor(
            calibratedWhite: connected ? 0.96 : 0.72,
            alpha: 0.9
        ).setStroke()
        lunarDisc.lineWidth = 1
        lunarDisc.stroke()

        image.unlockFocus()
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = false
        return image
    }

    @MainActor
    static func applyDockState(connected: Bool) {
        NSApp.applicationIconImage = dock(size: 512, connected: connected)
    }

    private static func sourceImage(connected: Bool) -> NSImage? {
        let name = connected ? "AppIconConnected" : "AppIconDisconnected"
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    private static func drawMenuBarCrater(
        center: NSPoint,
        radius: CGFloat,
        connected: Bool,
        hasCentralPeak: Bool
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

        guard hasCentralPeak else { return }
        let peakRadius = max(0.7, radius * 0.27)
        NSColor(
            calibratedWhite: connected ? 1 : 0.88,
            alpha: 1
        ).setFill()
        NSBezierPath(
            ovalIn: NSRect(
                x: center.x - peakRadius,
                y: center.y - peakRadius,
                width: peakRadius * 2,
                height: peakRadius * 2
            )
        ).fill()
    }
}
