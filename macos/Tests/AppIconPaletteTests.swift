import AppKit
import XCTest

final class AppIconPaletteTests: XCTestCase {
    func testConnectedIconUsesSharedSlatePalette() throws {
        let bitmap = try render(AppIcon.primary(size: 128, connected: true))
        var foundSlate = false

        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.alphaComponent > 0.5 else {
                    continue
                }
                foundSlate = foundSlate || (
                    color.blueComponent > color.redComponent + 0.07
                        && color.greenComponent > color.redComponent + 0.04
                )
            }
        }

        XCTAssertTrue(foundSlate, "icon should contain the shared slate accent")
    }

    func testConnectionStatesDoNotUseSuccessGreen() throws {
        for connected in [false, true] {
            let bitmap = try render(AppIcon.primary(
                size: 128,
                connected: connected
            ))
            var foundPine = false

            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                          color.alphaComponent > 0.5 else {
                        continue
                    }
                    foundPine = foundPine || (
                        color.greenComponent > color.redComponent + 0.08
                            && color.greenComponent > color.blueComponent + 0.025
                    )
                }
            }

            XCTAssertFalse(
                foundPine,
                "connection state should use luminance instead of success green"
            )
        }
    }

    func testPrimaryIconIsRoundedSlateTileWithSurfaceDial() throws {
        let bitmap = try render(AppIcon.primary(size: 128, connected: true))
        // macOS 圆角底块：四角透明，底块内是石板蓝灰，盘心是冷灰表面。
        XCTAssertLessThan(bitmap.colorAt(x: 1, y: 1)?.alphaComponent ?? 1, 0.05)
        XCTAssertLessThan(bitmap.colorAt(x: 126, y: 126)?.alphaComponent ?? 1, 0.05)
        let tile = try XCTUnwrap(bitmap.colorAt(x: 20, y: 20)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(tile.alphaComponent, 0.99)
        XCTAssertLessThan(tile.brightnessComponent, 0.45)
        let dial = try XCTUnwrap(bitmap.colorAt(x: 64, y: 64)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(dial.brightnessComponent, 0.9)
    }

    func testDockIconStaysInsideTheRoundedTile() throws {
        // 齿轮徽标与阴影不得超出 824/1024 的圆角底块，否则 macOS 26 会把整张
        // 图标缩进灰色底板。128 px 下底块为 [12.5, 115.5]。
        let bitmap = try render(AppIcon.dock(size: 128, connected: true))
        for (x, y) in [(122, 6), (118, 60), (60, 4), (124, 124), (4, 4)] {
            XCTAssertLessThan(
                bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 1, 0.02,
                "pixel (\(x), \(y)) should be outside the tile"
            )
        }
        // 徽标本身存在：底块内右下角是 Surface 底。
        let badge = try XCTUnwrap(bitmap.colorAt(x: 93, y: 93)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(badge.brightnessComponent, 0.85)
    }

    func testPrimaryIconKeepsConnectedLuminanceContrast() throws {
        let connected = try render(AppIcon.primary(size: 128, connected: true))
        let disconnected = try render(AppIcon.primary(size: 128, connected: false))

        XCTAssertGreaterThan(
            averageLuminance(connected),
            averageLuminance(disconnected) + 0.08
        )
    }

    private func render(_ image: NSImage) throws -> NSBitmapImageRep {
        let pixels = Int(image.size.width)
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

        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(
            in: NSRect(origin: .zero, size: image.size),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    private func averageLuminance(_ bitmap: NSBitmapImageRep) -> CGFloat {
        var total: CGFloat = 0
        var count: CGFloat = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.alphaComponent > 0.5 else { continue }
                total += 0.2126 * color.redComponent
                    + 0.7152 * color.greenComponent
                    + 0.0722 * color.blueComponent
                count += 1
            }
        }
        return count == 0 ? 0 : total / count
    }
}
