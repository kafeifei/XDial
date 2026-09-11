import AppKit

/// 菜单栏状态图标「电话拨号盘 Rotary」：几何来自 `RotaryDial`（设计稿 16 网格），
/// 绘制时整体缩放到 `canvasSize`；用 drawingHandler 而不是预烘焙位图，使 1x / 2x
/// 菜单栏都按目标分辨率重画。
///
/// 除「有更新」外都是 template image，由系统按菜单栏明暗与按下态着色。
/// 「有更新」需要一枚品牌 Danger 实色圆点，template 会把它一起压成单色，
/// 因此单独按菜单栏当前明暗生成一张非模板图；墨色由调用方从 label 的
/// colorScheme 得到——它跟随真实菜单栏（含壁纸导致的深色），不受 App 外观
/// 覆盖影响。
enum MenuBarStatusIcon {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
    }

    /// 错误优先级高于更新；两者同时存在时只显示错误，避免小尺寸图标过载。
    /// 错误是一张独立字形（空心环 + 叹号），不与连接底图叠加。
    enum Badge: Equatable {
        case none
        case update
        case error

        static func resolve(hasError: Bool, updateAvailable: Bool) -> Badge {
            if hasError { return .error }
            if updateAvailable { return .update }
            return .none
        }
    }

    /// 只影响非模板的「有更新」图：菜单栏为深色时墨色用白、圆点用 Danger 深色档。
    enum MenuBarTone: Equatable {
        case light
        case dark
    }

    /// 设计稿几何在 16 网格上；菜单栏按 20 × 20 pt 绘制（外环直径约 17 pt），
    /// 与相邻圆形状态符号的视觉大小接近。整体缩放只改这里，不改几何常量。
    static let designGrid = RotaryDial.grid
    static let canvasSize: CGFloat = 20

    /// 连接中：六个指孔按拨号顺序脉动，设计稿每孔 0.25 → 1 → 0.25 线性往复、
    /// 周期 0.9s、相邻孔相差 0.15s（1/6 周期）。菜单栏不需要 60fps，一个周期
    /// 切成 12 帧（75ms），每帧恰好推进半个孔位，读得出“逐个点亮”的方向。
    static let animationFramesPerCycle = 12
    static let animationFrameInterval: Duration = .milliseconds(75)
    static let pulseMinimumOpacity: CGFloat = 0.25

    static var fingerHoles: [NSPoint] { RotaryDial.fingerHoles }

    /// 第 `frame` 帧时第 `hole` 个指孔的透明度（0.25…1）。
    static func holeOpacity(hole: Int, frame: Int) -> CGFloat {
        let frames = animationFramesPerCycle
        let step = ((frame % frames) + frames) % frames
        // 每个孔比前一个晚 1/6 周期到达峰值。
        var phase = CGFloat(step) / CGFloat(frames)
            - CGFloat(hole) / CGFloat(RotaryDial.fingerHoles.count)
        phase -= phase.rounded(.down)
        let triangle = 1 - abs(2 * phase - 1)
        return pulseMinimumOpacity + (1 - pulseMinimumOpacity) * triangle
    }

    static func image(
        connection: ConnectionState,
        badge: Badge,
        menuBarTone: MenuBarTone,
        animationFrame: Int = 0
    ) -> NSImage {
        let isTemplate = badge != .update
        let ink: NSColor = isTemplate
            ? .black
            : (menuBarTone == .dark ? .white : .black)
        let dot = XDialBrandPalette.color(
            menuBarTone == .dark
                ? XDialBrandPalette.dangerDarkHex
                : XDialBrandPalette.dangerLightHex
        )

        let image = NSImage(
            size: NSSize(width: canvasSize, height: canvasSize),
            flipped: true
        ) { rect in
            NSGraphicsContext.current?.shouldAntialias = true
            RotaryDial.withGrid(in: rect, flipped: true) {
                draw(
                    connection: connection,
                    badge: badge,
                    ink: ink,
                    dot: dot,
                    frame: animationFrame
                )
            }
            return true
        }
        image.isTemplate = isTemplate
        image.accessibilityDescription = XDialBuildIdentity.productTitle
        return image
    }

    // MARK: - Drawing (16 网格，y 向下)

    /// 有更新：右上圆点。
    private static let updateDotCenter = NSPoint(x: 12.9, y: 3.1)
    private static let updateDotRadius: CGFloat = 2.6

    private static func draw(
        connection: ConnectionState,
        badge: Badge,
        ink: NSColor,
        dot: NSColor,
        frame: Int
    ) {
        if badge == .error {
            drawErrorGlyph(ink: ink)
            return
        }

        switch connection {
        case .disconnected:
            // 整组（外环 + 指孔）作为一层降到 0.45；圆点在层外按全墨绘制。
            RotaryDial.withGroupOpacity(RotaryDial.idleOpacity) {
                RotaryDial.strokeRing(ink: ink)
                RotaryDial.fillHoles(ink: ink)
            }
        case .connecting:
            RotaryDial.strokeRing(ink: ink)
            RotaryDial.fillHoles(ink: ink) { holeOpacity(hole: $0, frame: frame) }
        case .connected:
            RotaryDial.fillDiscWithCutouts(ink: ink)
        }

        if badge == .update {
            dot.setFill()
            RotaryDial.circle(at: updateDotCenter, radius: updateDotRadius).fill()
        }
    }

    /// 错误：空心环 + 叹号，独立字形。
    private static func drawErrorGlyph(ink: NSColor) {
        RotaryDial.strokeRing(ink: ink)
        ink.setStroke()
        ink.setFill()
        let bar = NSBezierPath()
        bar.lineWidth = 1.7
        bar.lineCapStyle = .round
        bar.move(to: NSPoint(x: 8, y: 4.6))
        bar.line(to: NSPoint(x: 8, y: 9.2))
        bar.stroke()
        RotaryDial.circle(at: NSPoint(x: 8, y: 11.3), radius: 1.05).fill()
    }
}
