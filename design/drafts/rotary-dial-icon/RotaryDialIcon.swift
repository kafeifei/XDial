import CoreGraphics
import Foundation

enum RotaryDialVisualState: Equatable {
    case idle
    case dialing
    case connected
}

enum RotaryDialIconModel {
    static let canvasSize: CGFloat = 252
    static let holeCount = 10
    static let cycleDuration: TimeInterval = 1.35
    static let fingerStopAngle = 3 * CGFloat.pi / 4

    static let inactiveOpacity: CGFloat = 0.4
    static let dialingOpacity: CGFloat = 0.7
    static let activeOpacity: CGFloat = 1

    static func visualState(for engineStatus: String) -> RotaryDialVisualState {
        switch engineStatus {
        case "connected":
            return .connected
        case "connecting", "reconnecting":
            return .dialing
        default:
            return .idle
        }
    }

    /// 老式拨盘不是匀速 spinner：先拨到挡针，短暂停顿，再受调速器控制回弹。
    static func dialRotation(for phase: CGFloat) -> CGFloat {
        let value = max(0, min(1, phase))
        let maximum = CGFloat.pi * 0.4

        if value < 0.34 {
            let progress = value / 0.34
            let eased = progress * progress * (3 - 2 * progress)
            return maximum * eased
        }
        if value < 0.44 {
            return maximum
        }

        let progress = (value - 0.44) / 0.56
        let eased = 1 - pow(1 - progress, 3)
        return maximum * (1 - eased)
    }

    static func stopOpacity(for state: RotaryDialVisualState) -> CGFloat {
        switch state {
        case .idle:
            return inactiveOpacity
        case .dialing:
            return dialingOpacity
        case .connected:
            return activeOpacity
        }
    }

    static func holeOpacity(
        index: Int,
        state: RotaryDialVisualState,
        phase: CGFloat
    ) -> CGFloat {
        guard state == .dialing else { return inactiveOpacity }

        let step = 2 * CGFloat.pi / CGFloat(holeCount)
        let rotation = dialRotation(for: phase)
        let distances = (0..<holeCount).map { holeIndex in
            positiveRemainder(
                fingerStopAngle - (CGFloat(holeIndex) * step + rotation),
                modulus: 2 * CGFloat.pi
            )
        }
        let ordered = distances.indices.sorted {
            distances[$0] < distances[$1]
        }

        if index == ordered[0] {
            return activeOpacity
        }
        if index == ordered[1] {
            return dialingOpacity
        }
        return inactiveOpacity
    }

    private static func positiveRemainder(_ value: CGFloat, modulus: CGFloat) -> CGFloat {
        let remainder = value.truncatingRemainder(dividingBy: modulus)
        return remainder >= 0 ? remainder : remainder + modulus
    }
}

enum RotaryDialBackground {
    case none
    case square
    case squircle
}

enum RotaryDialGlyph {
    static let graphite = CGColor(
        red: 31 / 255,
        green: 30 / 255,
        blue: 30 / 255,
        alpha: 1
    )

    static func draw(
        in context: CGContext,
        rect: CGRect,
        state: RotaryDialVisualState,
        phase: CGFloat = 0,
        background: RotaryDialBackground,
        template: Bool = false,
        compact: Bool = false
    ) {
        context.saveGState()
        defer { context.restoreGState() }

        let scale = min(rect.width, rect.height) / RotaryDialIconModel.canvasSize
        let origin = CGPoint(
            x: rect.midX - RotaryDialIconModel.canvasSize * scale / 2,
            y: rect.midY - RotaryDialIconModel.canvasSize * scale / 2
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
                width: RotaryDialIconModel.canvasSize,
                height: RotaryDialIconModel.canvasSize
            ))
        case .squircle:
            context.setFillColor(graphite)
            context.addPath(CGPath(
                roundedRect: CGRect(
                    x: 0,
                    y: 0,
                    width: RotaryDialIconModel.canvasSize,
                    height: RotaryDialIconModel.canvasSize
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

        let center = CGPoint(x: 126, y: 126)
        let wheelOuterRadius: CGFloat = compact ? 91 : 93
        let wheelInnerRadius: CGFloat = compact ? 38 : 39
        let holeRingRadius: CGFloat = compact ? 66 : 67
        let holeRadius: CGFloat = compact ? 15 : 14
        let rotation = state == .dialing
            ? RotaryDialIconModel.dialRotation(for: phase)
            : 0
        let step = 2 * CGFloat.pi / CGFloat(RotaryDialIconModel.holeCount)
        var holeRects: [CGRect] = []

        let wheel = CGMutablePath()
        wheel.addEllipse(in: CGRect(
            x: center.x - wheelOuterRadius,
            y: center.y - wheelOuterRadius,
            width: wheelOuterRadius * 2,
            height: wheelOuterRadius * 2
        ))
        wheel.addEllipse(in: CGRect(
            x: center.x - wheelInnerRadius,
            y: center.y - wheelInnerRadius,
            width: wheelInnerRadius * 2,
            height: wheelInnerRadius * 2
        ))

        for index in 0..<RotaryDialIconModel.holeCount {
            let angle = CGFloat(index) * step + rotation
            let point = CGPoint(
                x: center.x + holeRingRadius * sin(angle),
                y: center.y + holeRingRadius * cos(angle)
            )
            let holeRect = CGRect(
                x: point.x - holeRadius,
                y: point.y - holeRadius,
                width: holeRadius * 2,
                height: holeRadius * 2
            )
            holeRects.append(holeRect)
            wheel.addEllipse(in: holeRect)
        }

        context.setFillColor(foreground(RotaryDialIconModel.inactiveOpacity))
        context.addPath(wheel)
        context.drawPath(using: .eoFill)

        if state == .dialing {
            context.setLineWidth(compact ? 4.5 : 4)
            for (index, holeRect) in holeRects.enumerated() {
                let opacity = RotaryDialIconModel.holeOpacity(
                    index: index,
                    state: state,
                    phase: phase
                )
                guard opacity > RotaryDialIconModel.inactiveOpacity else {
                    continue
                }
                context.setStrokeColor(foreground(opacity))
                context.strokeEllipse(in: holeRect)
            }
        }

        let hubRadius: CGFloat = compact ? 30 : 31
        context.setFillColor(foreground(RotaryDialIconModel.inactiveOpacity))
        context.fillEllipse(in: CGRect(
            x: center.x - hubRadius,
            y: center.y - hubRadius,
            width: hubRadius * 2,
            height: hubRadius * 2
        ))

        drawFingerStop(
            in: context,
            center: center,
            color: foreground(RotaryDialIconModel.stopOpacity(for: state)),
            compact: compact,
            replaceExistingTemplatePixels: template
        )
    }

    private static func drawFingerStop(
        in context: CGContext,
        center: CGPoint,
        color: CGColor,
        compact: Bool,
        replaceExistingTemplatePixels: Bool
    ) {
        let stopAngle = RotaryDialIconModel.fingerStopAngle
        let radial = CGVector(dx: sin(stopAngle), dy: cos(stopAngle))
        let tangent = CGVector(dx: -radial.dy, dy: radial.dx)

        func point(radius: CGFloat, tangentOffset: CGFloat) -> CGPoint {
            CGPoint(
                x: center.x + radial.dx * radius + tangent.dx * tangentOffset,
                y: center.y + radial.dy * radius + tangent.dy * tangentOffset
            )
        }

        // 手指沿顺时针方向（负 tangent）运动，因此挡片的前缘沿半径放置；
        // 支架位于前缘的顺时针一侧，并从右下外壳向盘心弯入。
        let contactInner = point(
            radius: compact ? 72 : 73,
            tangentOffset: 4
        )
        let contactOuter = point(
            radius: compact ? 92 : 93,
            tangentOffset: 4
        )
        let mountLeading = point(radius: 109, tangentOffset: -3)
        let mountBack = point(radius: 109, tangentOffset: -20)
        let innerBack = point(radius: compact ? 72 : 73, tangentOffset: -12)
        let roundedInner = point(radius: compact ? 65 : 66, tangentOffset: -4)

        let path = CGMutablePath()
        path.move(to: contactInner)
        path.addLine(to: contactOuter)
        path.addQuadCurve(
            to: mountLeading,
            control: point(radius: 102, tangentOffset: 3)
        )
        path.addLine(to: mountBack)
        path.addQuadCurve(
            to: innerBack,
            control: point(radius: 94, tangentOffset: -19)
        )
        path.addQuadCurve(to: contactInner, control: roundedInner)
        path.closeSubpath()

        context.saveGState()
        defer { context.restoreGState() }
        if replaceExistingTemplatePixels {
            context.setBlendMode(.copy)
        }
        context.setFillColor(color)
        context.addPath(path)
        context.fillPath()
    }
}
