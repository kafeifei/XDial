import AppKit
import XCTest

final class MenuBarStatusIconTests: XCTestCase {
    private let pixels = 128
    /// 采样坐标沿用设计稿 16 网格；画布整体放大不改变网格坐标。
    private var unit: CGFloat { CGFloat(pixels) / MenuBarStatusIcon.designGrid }

    private let holes: [(CGFloat, CGFloat)] = [
        (11.9, 5.75), (9.16, 3.65), (5.75, 4.1),
        (3.65, 6.84), (4.1, 10.25), (6.84, 12.35),
    ]

    func testCanvasIsTwentyPointsOnSixteenGrid() {
        let image = MenuBarStatusIcon.image(
            connection: .connected, badge: .none, menuBarTone: .light
        )
        XCTAssertEqual(image.size, NSSize(width: 20, height: 20))
        XCTAssertEqual(MenuBarStatusIcon.designGrid, 16)
    }

    func testFingerHolesMatchDesignOrderAndPositions() {
        XCTAssertEqual(MenuBarStatusIcon.fingerHoles.count, holes.count)
        for (index, hole) in holes.enumerated() {
            XCTAssertEqual(MenuBarStatusIcon.fingerHoles[index].x, hole.0, accuracy: 0.001)
            XCTAssertEqual(MenuBarStatusIcon.fingerHoles[index].y, hole.1, accuracy: 0.001)
        }
    }

    func testOnlyUpdateVariantLeavesTemplateRendering() {
        for connection in [MenuBarStatusIcon.ConnectionState.disconnected, .connecting, .connected] {
            for tone in [MenuBarStatusIcon.MenuBarTone.light, .dark] {
                XCTAssertTrue(
                    MenuBarStatusIcon.image(connection: connection, badge: .none, menuBarTone: tone).isTemplate
                )
                XCTAssertTrue(
                    MenuBarStatusIcon.image(connection: connection, badge: .error, menuBarTone: tone).isTemplate
                )
                XCTAssertFalse(
                    MenuBarStatusIcon.image(connection: connection, badge: .update, menuBarTone: tone).isTemplate,
                    "the Danger dot would be flattened by template tinting"
                )
            }
        }
    }

    func testErrorTakesPriorityOverUpdate() {
        XCTAssertEqual(
            MenuBarStatusIcon.Badge.resolve(hasError: true, updateAvailable: true), .error
        )
        XCTAssertEqual(
            MenuBarStatusIcon.Badge.resolve(hasError: false, updateAvailable: true), .update
        )
        XCTAssertEqual(
            MenuBarStatusIcon.Badge.resolve(hasError: false, updateAvailable: false), .none
        )
    }

    // MARK: - Disconnected：空心环 + 实心指孔，整组 0.45

    func testDisconnectedIsHollowRingWithSolidHolesAtIdleOpacity() throws {
        let disconnected = try render(.disconnected, badge: .none)

        // 外环 r 6.2、线宽 1.5：环上有墨，环内外无墨。
        XCTAssertEqual(alpha(disconnected, x: 8, y: 1.8), 0.45, accuracy: 0.05)
        XCTAssertEqual(alpha(disconnected, x: 14.2, y: 8), 0.45, accuracy: 0.05)
        XCTAssertLessThan(alpha(disconnected, x: 8, y: 8), 0.05)
        XCTAssertLessThan(alpha(disconnected, x: 8, y: 0.6), 0.05)
        // 六个指孔 r 1：孔心处 0.45，孔外无墨。
        for (x, y) in holes {
            XCTAssertEqual(alpha(disconnected, x: x, y: y), 0.45, accuracy: 0.05, "hole \((x, y))")
        }
        // 指孔与外环之间的间隙（半径 ~4.4 处）没有墨。
        XCTAssertLessThan(alpha(disconnected, x: 12.2, y: 7.7), 0.05)
    }

    // MARK: - Connected：实心盘 + 镂空指孔 + 镂空指停器

    func testConnectedIsSolidDiscWithPunchedHolesAndFingerStop() throws {
        let connected = try render(.connected, badge: .none)

        // 实心盘 r 6.6：盘心与盘缘内侧有墨，盘外无墨。
        XCTAssertGreaterThan(alpha(connected, x: 8, y: 8), 0.9)
        XCTAssertGreaterThan(alpha(connected, x: 8, y: 1.7), 0.9)
        XCTAssertLessThan(alpha(connected, x: 8, y: 1.0), 0.1)
        // 六个指孔 r 1.15 镂空：孔心透明，孔外 1.45 处仍是盘。
        for (x, y) in holes {
            XCTAssertLessThan(alpha(connected, x: x, y: y), 0.1, "hole \((x, y))")
        }
        XCTAssertGreaterThan(alpha(connected, x: 8, y: 5.4), 0.9)
        // 指停器 (9.84,9.84)→(12.1,12.1) 宽 1.4 镂空：中点透明，旁边 1 格外仍是盘。
        XCTAssertLessThan(alpha(connected, x: 10.97, y: 10.97), 0.1)
        XCTAssertGreaterThan(alpha(connected, x: 10.0, y: 11.6), 0.9)
    }

    // MARK: - Connecting：空心环 + 逐个点亮的指孔

    func testHoleOpacityPulsesInDialingOrder() {
        let frames = MenuBarStatusIcon.animationFramesPerCycle
        let minimum = MenuBarStatusIcon.pulseMinimumOpacity

        // 每帧都在 [0.25, 1] 内；第 0 帧第 0 孔最暗、半周期后最亮。
        for frame in 0..<frames {
            for hole in 0..<holes.count {
                let value = MenuBarStatusIcon.holeOpacity(hole: hole, frame: frame)
                XCTAssertGreaterThanOrEqual(value, minimum - 0.0001)
                XCTAssertLessThanOrEqual(value, 1.0001)
            }
        }
        XCTAssertEqual(MenuBarStatusIcon.holeOpacity(hole: 0, frame: 0), minimum, accuracy: 0.0001)
        XCTAssertEqual(MenuBarStatusIcon.holeOpacity(hole: 0, frame: frames / 2), 1, accuracy: 0.0001)
        // 相邻孔相差 1/6 周期：第 k 孔的峰值比第 k-1 孔晚 frames/6 帧。
        let lag = frames / holes.count
        for hole in 1..<holes.count {
            XCTAssertEqual(
                MenuBarStatusIcon.holeOpacity(hole: hole, frame: frames / 2 + hole * lag),
                1,
                accuracy: 0.0001,
                "hole \(hole) should peak \(hole * lag) frames after hole 0"
            )
        }
        // 周期封闭；负帧号落回同一周期。
        XCTAssertEqual(
            MenuBarStatusIcon.holeOpacity(hole: 2, frame: frames + 3),
            MenuBarStatusIcon.holeOpacity(hole: 2, frame: 3),
            accuracy: 0.0001
        )
        XCTAssertEqual(
            MenuBarStatusIcon.holeOpacity(hole: 2, frame: -1),
            MenuBarStatusIcon.holeOpacity(hole: 2, frame: frames - 1),
            accuracy: 0.0001
        )
    }

    func testConnectingRendersRingAtFullInkAndHolesByFrame() throws {
        let frames = MenuBarStatusIcon.animationFramesPerCycle
        let first = try render(.connecting, badge: .none, animationFrame: 0)
        let half = try render(.connecting, badge: .none, animationFrame: frames / 2)

        // 外环不参与脉动，始终全墨。
        XCTAssertGreaterThan(alpha(first, x: 8, y: 1.8), 0.9)
        XCTAssertGreaterThan(alpha(half, x: 8, y: 1.8), 0.9)
        // 第 0 孔：第 0 帧 0.25，半周期后 1。
        XCTAssertEqual(alpha(first, x: 11.9, y: 5.75), 0.25, accuracy: 0.05)
        XCTAssertEqual(alpha(half, x: 11.9, y: 5.75), 1, accuracy: 0.05)
        // 第 3 孔正好相反。
        XCTAssertEqual(alpha(first, x: 3.65, y: 6.84), 1, accuracy: 0.05)
        XCTAssertEqual(alpha(half, x: 3.65, y: 6.84), 0.25, accuracy: 0.05)
        // 中心保持空心。
        XCTAssertLessThan(alpha(first, x: 8, y: 8), 0.05)
        // 非连接中状态忽略帧号。
        let connectedA = try render(.connected, badge: .none, animationFrame: 0)
        let connectedB = try render(.connected, badge: .none, animationFrame: 5)
        XCTAssertEqual(connectedA.tiffRepresentation, connectedB.tiffRepresentation)
    }

    // MARK: - Update：右上 Danger 圆点

    func testUpdateDotUsesBrandDangerAndFollowsMenuBarTone() throws {
        let light = try render(.connected, badge: .update, tone: .light)
        let dark = try render(.connected, badge: .update, tone: .dark)

        let lightDot = try XCTUnwrap(color(light, x: 12.9, y: 3.1))
        let darkDot = try XCTUnwrap(color(dark, x: 12.9, y: 3.1))
        assertClose(lightDot, hex: XDialBrandPalette.dangerLightHex)
        assertClose(darkDot, hex: XDialBrandPalette.dangerDarkHex)

        // 非模板图的墨色跟随菜单栏明暗；采样盘心。
        let lightInk = try XCTUnwrap(color(light, x: 8, y: 8))
        let darkInk = try XCTUnwrap(color(dark, x: 8, y: 8))
        XCTAssertLessThan(lightInk.brightnessComponent, 0.1)
        XCTAssertGreaterThan(darkInk.brightnessComponent, 0.9)

        // 圆点在未连接底图上仍是全墨 Danger，底图保持 0.45。
        let idle = try render(.disconnected, badge: .update, tone: .light)
        assertClose(try XCTUnwrap(color(idle, x: 12.9, y: 3.1)), hex: XDialBrandPalette.dangerLightHex)
        XCTAssertEqual(alpha(idle, x: 12.9, y: 3.1), 1, accuracy: 0.02)
        XCTAssertEqual(alpha(idle, x: 3.65, y: 6.84), 0.45, accuracy: 0.05)
    }

    // MARK: - Error：空心环 + 叹号，独立字形

    func testErrorIsHollowRingWithExclamationRegardlessOfConnection() throws {
        var previous: Data?
        for connection in [MenuBarStatusIcon.ConnectionState.disconnected, .connecting, .connected] {
            let error = try render(connection, badge: .error, animationFrame: 4)
            XCTAssertGreaterThan(alpha(error, x: 8, y: 1.8), 0.9)
            // 叹号竖线 (8,4.6)→(8,9.2) 宽 1.7 与圆点 (8,11.3) r 1.05。
            XCTAssertGreaterThan(alpha(error, x: 8, y: 6.9), 0.9)
            XCTAssertGreaterThan(alpha(error, x: 8, y: 11.3), 0.9)
            // 竖线圆帽 (10.05) 与圆点顶 (10.25) 之间只有 0.2 格空隙，只要求明显变淡。
            XCTAssertLessThan(alpha(error, x: 8, y: 10.15), 0.7)
            // 指孔位置无墨：错误不是连接底图的叠加。
            XCTAssertLessThan(alpha(error, x: 11.9, y: 5.75), 0.05)
            // 三种连接状态渲染完全一致。
            let data = try XCTUnwrap(error.tiffRepresentation)
            if let previous { XCTAssertEqual(previous, data) }
            previous = data
        }
    }

    // MARK: - Helpers

    private func render(
        _ connection: MenuBarStatusIcon.ConnectionState,
        badge: MenuBarStatusIcon.Badge,
        tone: MenuBarStatusIcon.MenuBarTone = .light,
        animationFrame: Int = 0
    ) throws -> NSBitmapImageRep {
        let image = MenuBarStatusIcon.image(
            connection: connection,
            badge: badge,
            menuBarTone: tone,
            animationFrame: animationFrame
        )
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw CocoaError(.coderInvalidValue)
        }
        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(
            in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    /// 以设计稿的 16 格 y 向下坐标采样。
    private func color(_ bitmap: NSBitmapImageRep, x: CGFloat, y: CGFloat) -> NSColor? {
        bitmap.colorAt(x: Int(x * unit), y: Int(y * unit))?.usingColorSpace(.sRGB)
    }

    private func alpha(_ bitmap: NSBitmapImageRep, x: CGFloat, y: CGFloat) -> CGFloat {
        color(bitmap, x: x, y: y)?.alphaComponent ?? 0
    }

    private func assertClose(_ color: NSColor, hex: UInt32, file: StaticString = #filePath, line: UInt = #line) {
        let expected = XDialBrandPalette.color(hex).usingColorSpace(.sRGB)!
        XCTAssertEqual(color.redComponent, expected.redComponent, accuracy: 0.03, file: file, line: line)
        XCTAssertEqual(color.greenComponent, expected.greenComponent, accuracy: 0.03, file: file, line: line)
        XCTAssertEqual(color.blueComponent, expected.blueComponent, accuracy: 0.03, file: file, line: line)
    }
}
