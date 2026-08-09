import AppKit
import XCTest

final class AppIconPaletteTests: XCTestCase {
    func testMenuBarIconFillsItsTwentyPointCanvas() throws {
        let image = AppIcon.menuBar(connected: true)
        XCTAssertEqual(image.size, NSSize(width: 20, height: 20))

        let bitmap = try render(image)
        var occupiedX = Set<Int>()
        var occupiedY = Set<Int>()
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y),
                      color.alphaComponent > 0.05 else { continue }
                occupiedX.insert(x)
                occupiedY.insert(y)
            }
        }

        XCTAssertGreaterThanOrEqual(occupiedX.count, 18)
        XCTAssertGreaterThanOrEqual(occupiedY.count, 18)
    }

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

    func testConnectedMenuBarIconIsMateriallyBrighterThanDisconnected() throws {
        let connected = try render(AppIcon.menuBar(connected: true))
        let disconnected = try render(AppIcon.menuBar(connected: false))

        XCTAssertGreaterThan(
            averageLuminance(connected),
            averageLuminance(disconnected) + 0.08
        )
    }

    func testDisconnectedMenuBarIconUsesMidGraySurface() throws {
        let disconnected = try render(AppIcon.menuBar(connected: false))
        let luminance = averageLuminance(disconnected)

        XCTAssertGreaterThan(luminance, 0.48)
        XCTAssertLessThan(luminance, 0.62)
    }

    func testErrorBadgeTakesPriorityOverUpdateDot() throws {
        let error = try render(AppIcon.menuBar(
            connected: false,
            hasError: true,
            updateAvailable: true
        ))
        let update = try render(AppIcon.menuBar(
            connected: false,
            updateAvailable: true
        ))

        XCTAssertGreaterThan(dangerPixelCount(error), dangerPixelCount(update))
        XCTAssertGreaterThan(dangerPixelCount(update), 4)
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

    private func dangerPixelCount(_ bitmap: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.alphaComponent > 0.5 else { continue }
                if color.redComponent > color.greenComponent + 0.18,
                   color.redComponent > color.blueComponent + 0.18 {
                    count += 1
                }
            }
        }
        return count
    }
}
