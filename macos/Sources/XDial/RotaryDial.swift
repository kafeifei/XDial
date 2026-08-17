import AppKit

/// 拨号盘的几何与基础笔画：转盘、六个指孔、指停器。坐标沿用设计稿 SVG 的
/// 16 网格、y 向下。菜单栏状态图标与 App / Dock / iOS / tvOS 图标共用这一份，
/// 避免两套坐标各自漂移；调用方只负责把网格映射到自己的画布。
///
/// 本文件会被图标生成器用 `swiftc` 单独编译，只能依赖 AppKit。
enum RotaryDial {
    static let grid: CGFloat = 16
    static let center = NSPoint(x: 8, y: 8)

    /// 空心盘：外环半径与线宽。
    static let ringRadius: CGFloat = 6.2
    static let ringWidth: CGFloat = 1.5
    /// 实心盘半径略大于外环，视觉重量与空心盘一致。
    static let discRadius: CGFloat = 6.6
    /// 指孔：空心盘上是实心小点，实心盘上是镂空孔。
    static let holeRadiusOnRing: CGFloat = 1
    static let holeRadiusOnDisc: CGFloat = 1.15
    /// 未连接：整组降到 0.45，表示拨盘仍在、只是没有拨通。
    static let idleOpacity: CGFloat = 0.45

    /// 六个指孔按拨号顺序排列（从右上开始逆时针到左下）。
    static let fingerHoles: [NSPoint] = [
        NSPoint(x: 11.9, y: 5.75),
        NSPoint(x: 9.16, y: 3.65),
        NSPoint(x: 5.75, y: 4.1),
        NSPoint(x: 3.65, y: 6.84),
        NSPoint(x: 4.1, y: 10.25),
        NSPoint(x: 6.84, y: 12.35),
    ]

    /// 指停器：实心盘右下的一道镂空短线。
    static let fingerStopStart = NSPoint(x: 9.84, y: 9.84)
    static let fingerStopEnd = NSPoint(x: 12.1, y: 12.1)
    static let fingerStopWidth: CGFloat = 1.4

    /// 把 16 网格映射到 `rect` 后执行 `body`。`flipped` 表示当前上下文已是
    /// y 向下（如 `NSImage(size:flipped:true)` 的 drawingHandler）；否则做一次
    /// 竖直翻转，使设计稿坐标在 y 向上的 lockFocus 上下文里也直接可用。
    static func withGrid(
        in rect: NSRect,
        flipped: Bool,
        _ body: () -> Void
    ) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        let scale = min(rect.width, rect.height) / grid
        if flipped {
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: scale, y: scale)
        } else {
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: scale, y: -scale)
        }
        body()
        context.restoreGState()
    }

    /// 空心外环。
    static func strokeRing(ink: NSColor) {
        ink.setStroke()
        let ring = circle(at: center, radius: ringRadius)
        ring.lineWidth = ringWidth
        ring.stroke()
    }

    /// 空心盘上的六个实心指孔；`opacity` 给连接中动画逐孔取值。
    static func fillHoles(
        ink: NSColor,
        opacity: (Int) -> CGFloat = { _ in 1 }
    ) {
        for (index, hole) in fingerHoles.enumerated() {
            ink.withAlphaComponent(opacity(index)).setFill()
            circle(at: hole, radius: holeRadiusOnRing).fill()
        }
    }

    /// 实心盘 + 镂空指孔 + 镂空指停器：镂空处透出下层。
    static func fillDiscWithCutouts(ink: NSColor) {
        ink.setFill()
        circle(at: center, radius: discRadius).fill()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSColor.black.setFill()
        NSColor.black.setStroke()
        for hole in fingerHoles {
            circle(at: hole, radius: holeRadiusOnDisc).fill()
        }
        let stop = NSBezierPath()
        stop.lineWidth = fingerStopWidth
        stop.lineCapStyle = .round
        stop.move(to: fingerStopStart)
        stop.line(to: fingerStopEnd)
        stop.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 在一个 `alpha` 透明层里执行 `body`，对应设计稿的 `<g opacity>`：
    /// 元素之间的微小重叠不会因逐元素叠加而变深。
    static func withGroupOpacity(_ alpha: CGFloat, _ body: () -> Void) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            body()
            return
        }
        context.saveGState()
        context.setAlpha(alpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        context.endTransparencyLayer()
        context.restoreGState()
    }

    static func circle(at point: NSPoint, radius: CGFloat) -> NSBezierPath {
        NSBezierPath(
            ovalIn: NSRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        )
    }
}
