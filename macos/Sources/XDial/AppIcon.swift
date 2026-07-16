import AppKit

enum AppIcon {
    /// 基础图标：蓝色渐变背景 + 🌐
    static func base(size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        drawBackground(size: size)
        drawGlobe(size: size)
        img.unlockFocus()
        return img
    }

    /// Dock 图标：基础 + 右下角 ⚙️
    static func dock(size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        drawBackground(size: size)
        drawGlobe(size: size)
        drawGear(size: size)
        img.unlockFocus()
        return img
    }

    /// 菜单栏使用透明背景的轮船 Emoji。
    static func menuBar() -> NSImage {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let ship = "🚢" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15)]
        let shipSize = ship.size(withAttributes: attributes)
        ship.draw(
            at: NSPoint(x: (size - shipSize.width) / 2, y: (size - shipSize.height) / 2),
            withAttributes: attributes
        )
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    // MARK: - 内部绘制

    private static func drawBackground(size: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let colors = [
            CGColor(red: 0.22, green: 0.50, blue: 0.88, alpha: 1),
            CGColor(red: 0.14, green: 0.34, blue: 0.68, alpha: 1)
        ]
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: colors as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: 0, y: size),
                               end: CGPoint(x: 0, y: 0), options: [])
    }

    private static func drawGlobe(size: CGFloat) {
        let globe = "🌐" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size * 0.68)]
        let sz = globe.size(withAttributes: attrs)
        let x = (size - sz.width) / 2
        let y = (size - sz.height) / 2 - size * 0.02
        globe.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
    }

    private static func drawGear(size: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let gear = "⚙️" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size * 0.22)]
        let sz = gear.size(withAttributes: attrs)
        let x = size - sz.width - size * 0.06
        let y = size * 0.06
        // 白色圆底
        let pad = size * 0.03
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
        ctx.fillEllipse(in: CGRect(x: x - pad, y: y - pad,
                                    width: sz.width + pad * 2, height: sz.height + pad * 2))
        gear.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
    }
}
