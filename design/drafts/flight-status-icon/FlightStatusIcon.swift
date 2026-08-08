import CoreGraphics
import Foundation

enum FlightVisualState: CaseIterable, Equatable {
    case takingOff
    case cruising
    case landing
    case crashed
}

enum FlightStatusIconModel {
    static let canvasSize: CGFloat = 252
    static let cycleDuration: TimeInterval = 1.2

    static let inactiveOpacity: CGFloat = 0.4
    static let transitionOpacity: CGFloat = 0.7
    static let activeOpacity: CGFloat = 1

    static func visualState(
        for engineStatus: String,
        hasError: Bool = false
    ) -> FlightVisualState {
        if hasError {
            return .crashed
        }
        switch engineStatus {
        case "connecting", "reconnecting":
            return .takingOff
        case "connected":
            return .cruising
        default:
            return .landing
        }
    }

    static func pitch(for state: FlightVisualState) -> CGFloat {
        switch state {
        case .takingOff:
            return 28 * .pi / 180
        case .cruising:
            return 0
        case .landing:
            return -18 * .pi / 180
        case .crashed:
            return -58 * .pi / 180
        }
    }

    static func planeOpacity(for state: FlightVisualState) -> CGFloat {
        switch state {
        case .landing:
            return inactiveOpacity
        case .takingOff:
            return transitionOpacity
        case .cruising, .crashed:
            return activeOpacity
        }
    }

    static func trailOpacities(
        for state: FlightVisualState,
        phase: CGFloat
    ) -> [CGFloat] {
        switch state {
        case .takingOff:
            let frame = Int(floor(max(0, min(0.999, phase)) * 3))
            return (0..<3).map { index in
                let distance = (index - frame + 3) % 3
                return [activeOpacity, transitionOpacity, inactiveOpacity][distance]
            }
        case .cruising:
            return [inactiveOpacity, transitionOpacity, activeOpacity]
        case .landing:
            return [inactiveOpacity, inactiveOpacity, transitionOpacity]
        case .crashed:
            return [inactiveOpacity, transitionOpacity]
        }
    }
}

enum FlightIconBackground {
    case none
    case square
    case squircle
}

enum FlightStatusGlyph {
    static let graphite = CGColor(
        red: 31 / 255,
        green: 30 / 255,
        blue: 30 / 255,
        alpha: 1
    )

    static func draw(
        in context: CGContext,
        rect: CGRect,
        state: FlightVisualState,
        phase: CGFloat = 0,
        background: FlightIconBackground,
        template: Bool = false,
        compact: Bool = false
    ) {
        context.saveGState()
        defer { context.restoreGState() }

        let scale = min(rect.width, rect.height) / FlightStatusIconModel.canvasSize
        let origin = CGPoint(
            x: rect.midX - FlightStatusIconModel.canvasSize * scale / 2,
            y: rect.midY - FlightStatusIconModel.canvasSize * scale / 2
        )
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: scale, y: scale)

        switch background {
        case .none:
            break
        case .square:
            context.setFillColor(graphite)
            context.fill(CGRect(
                x: 0,
                y: 0,
                width: FlightStatusIconModel.canvasSize,
                height: FlightStatusIconModel.canvasSize
            ))
        case .squircle:
            context.setFillColor(graphite)
            context.addPath(CGPath(
                roundedRect: CGRect(
                    x: 0,
                    y: 0,
                    width: FlightStatusIconModel.canvasSize,
                    height: FlightStatusIconModel.canvasSize
                ),
                cornerWidth: 63,
                cornerHeight: 63,
                transform: nil
            ))
            context.fillPath()
        }

        let foreground: (CGFloat) -> CGColor = { opacity in
            if template {
                return CGColor(gray: 0, alpha: opacity)
            }
            let graphiteLevel: CGFloat = 31 / 255
            let level = graphiteLevel + (1 - graphiteLevel) * opacity
            return CGColor(gray: level, alpha: 1)
        }

        let pitch = FlightStatusIconModel.pitch(for: state)
        // 菜单栏实际只显示紧视口中央约 198 个设计单位。compact 版本缩小
        // 飞机并右移，给三颗航线点留出完整空间；App 图标同样避免最末点贴边。
        let center = CGPoint(x: compact ? 154 : 140, y: 126)
        let glyphScale: CGFloat = compact ? 0.86 : 0.94

        drawTrail(
            in: context,
            center: center,
            pitch: pitch,
            state: state,
            phase: phase,
            color: foreground,
            scale: glyphScale,
            compact: compact
        )

        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: pitch)
        context.scaleBy(x: glyphScale, y: glyphScale)
        context.setFillColor(foreground(
            FlightStatusIconModel.planeOpacity(for: state)
        ))
        context.addPath(airplanePath)
        context.fillPath()
        context.restoreGState()

        if state == .crashed {
            drawImpact(
                in: context,
                center: center,
                pitch: pitch,
                color: foreground(FlightStatusIconModel.activeOpacity),
                scale: glyphScale,
                compact: compact
            )
        }
    }

    private static let airplanePath: CGPath = {
        // 货运机俯视剪影：宽机身、钝机鼻、厚主翼和宽尾翼。轮廓减少尖角，
        // 让 16pt 下首先读成“重型飞机”，而不是纸飞机或细长民航机。
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 80, y: 0))
        path.addQuadCurve(
            to: CGPoint(x: 57, y: 14),
            control: CGPoint(x: 72, y: 14)
        )
        path.addLine(to: CGPoint(x: 18, y: 17))
        path.addLine(to: CGPoint(x: -9, y: 55))
        path.addQuadCurve(
            to: CGPoint(x: -35, y: 56),
            control: CGPoint(x: -24, y: 59)
        )
        path.addLine(to: CGPoint(x: -22, y: 18))
        path.addLine(to: CGPoint(x: -52, y: 14))
        path.addLine(to: CGPoint(x: -64, y: 34))
        path.addLine(to: CGPoint(x: -83, y: 32))
        path.addLine(to: CGPoint(x: -72, y: 9))
        path.addQuadCurve(
            to: CGPoint(x: -80, y: 0),
            control: CGPoint(x: -79, y: 6)
        )
        path.addQuadCurve(
            to: CGPoint(x: -72, y: -9),
            control: CGPoint(x: -79, y: -6)
        )
        path.addLine(to: CGPoint(x: -83, y: -32))
        path.addLine(to: CGPoint(x: -64, y: -34))
        path.addLine(to: CGPoint(x: -52, y: -14))
        path.addLine(to: CGPoint(x: -22, y: -18))
        path.addLine(to: CGPoint(x: -35, y: -56))
        path.addQuadCurve(
            to: CGPoint(x: -9, y: -55),
            control: CGPoint(x: -24, y: -59)
        )
        path.addLine(to: CGPoint(x: 18, y: -17))
        path.addLine(to: CGPoint(x: 57, y: -14))
        path.addQuadCurve(
            to: CGPoint(x: 80, y: 0),
            control: CGPoint(x: 72, y: -14)
        )
        path.closeSubpath()
        return path
    }()

    private static func drawTrail(
        in context: CGContext,
        center: CGPoint,
        pitch: CGFloat,
        state: FlightVisualState,
        phase: CGFloat,
        color: (CGFloat) -> CGColor,
        scale: CGFloat,
        compact: Bool
    ) {
        let opacities = FlightStatusIconModel.trailOpacities(
            for: state,
            phase: phase
        )
        let localPoints: [CGPoint]
        if state == .crashed {
            localPoints = [CGPoint(x: -102, y: 10), CGPoint(x: -126, y: -8)]
        } else {
            localPoints = [
                CGPoint(x: -101, y: 0),
                CGPoint(x: -123, y: 0),
                CGPoint(x: -145, y: 0),
            ]
        }
        let radius: CGFloat = compact ? 6.5 : 6

        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: pitch)
        context.scaleBy(x: scale, y: scale)
        for (index, point) in localPoints.enumerated() {
            context.setFillColor(color(opacities[index]))
            context.fillEllipse(in: CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }
        context.restoreGState()
    }

    private static func drawImpact(
        in context: CGContext,
        center: CGPoint,
        pitch: CGFloat,
        color: CGColor,
        scale: CGFloat,
        compact: Bool
    ) {
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: pitch)
        context.scaleBy(x: scale, y: scale)
        context.setStrokeColor(color)
        context.setLineWidth(compact ? 8 : 7)
        context.setLineCap(.round)
        let x: CGFloat = 101
        let radius: CGFloat = 10
        context.move(to: CGPoint(x: x - radius, y: -radius))
        context.addLine(to: CGPoint(x: x + radius, y: radius))
        context.move(to: CGPoint(x: x - radius, y: radius))
        context.addLine(to: CGPoint(x: x + radius, y: -radius))
        context.strokePath()
        context.restoreGState()
    }
}
